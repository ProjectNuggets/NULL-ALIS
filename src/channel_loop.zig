//! Channel Loop — extracted polling loops for daemon-supervised channels.
//!
//! Contains `ChannelRuntime` (shared dependencies for message processing)
//! and `runTelegramLoop` (the polling thread function spawned by the
//! daemon supervisor).

const std = @import("std");
const Config = @import("config.zig").Config;
const config_types = @import("config_types.zig");
const telegram = @import("channels/telegram.zig");
const session_mod = @import("session.zig");
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const providers = @import("providers/root.zig");
const memory_mod = @import("memory/root.zig");
const observability = @import("observability.zig");
const tools_mod = @import("tools/root.zig");
const mcp = @import("mcp.zig");
const voice = @import("voice.zig");
const health = @import("health.zig");
const daemon = @import("daemon.zig");
const security = @import("security/policy.zig");
const subagent_mod = @import("subagent.zig");
const agent_routing = @import("agent_routing.zig");
const model_capabilities = @import("agent/model_capabilities.zig");
const zaki_session = @import("session/root.zig");
const provider_runtime = @import("providers/runtime_bundle.zig");
const bus_mod = @import("bus.zig");
const appendJsonEscaped = @import("util.zig").appendJsonEscaped;

const signal = @import("channels/signal.zig");
const matrix = @import("channels/matrix.zig");
const email = @import("channels/email.zig");
const channels_mod = @import("channels/root.zig");

const log = std.log.scoped(.channel_loop);
const TELEGRAM_OFFSET_STORE_VERSION: i64 = 1;

pub const LocalOutboundDispatchFn = *const fn (
    ctx: ?*anyopaque,
    outbound: *const bus_mod.OutboundMessage,
) anyerror!void;

const SubagentCompletionRouter = struct {
    session_mgr: *session_mod.SessionManager,
    event_bus: ?*bus_mod.Bus,
    local_outbound_dispatch: ?LocalOutboundDispatchFn = null,
    local_outbound_dispatch_ctx: ?*anyopaque = null,
};

fn shouldEmitCompletionOutbound(channel: ?[]const u8, chat_id: ?[]const u8) bool {
    const resolved_channel = channel orelse return false;
    _ = chat_id orelse return false;
    return !std.mem.eql(u8, resolved_channel, "agent") and
        !std.mem.eql(u8, resolved_channel, "system") and
        !std.mem.eql(u8, resolved_channel, "zaki_app");
}

fn appendSubagentCompletionToSession(
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

    if (!shouldEmitCompletionOutbound(origin.channel, origin.chat_id)) return;

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
        event_bus.publishOutbound(outbound) catch {
            return;
        };
        outbound_transferred = true;
        return;
    }

    if (router.local_outbound_dispatch) |dispatch| {
        try dispatch(router.local_outbound_dispatch_ctx, &outbound);
        if (completion_event_id) |event_id| {
            try router.session_mgr.deleteCompletionEvent(event_id);
        }
    }
}

fn extractTelegramBotId(bot_token: []const u8) ?[]const u8 {
    const colon_pos = std.mem.indexOfScalar(u8, bot_token, ':') orelse return null;
    if (colon_pos == 0) return null;
    const raw = std.mem.trim(u8, bot_token[0..colon_pos], " \t\r\n");
    if (raw.len == 0) return null;
    for (raw) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return raw;
}

fn normalizeTelegramAccountId(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, account_id, " \t\r\n");
    const source = if (trimmed.len == 0) "default" else trimmed;
    var normalized = try allocator.alloc(u8, source.len);
    for (source, 0..) |c, i| {
        normalized[i] = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') c else '_';
    }
    return normalized;
}

fn telegramUpdateOffsetPath(allocator: std.mem.Allocator, config: *const Config, account_id: []const u8) ![]u8 {
    const config_dir = std.fs.path.dirname(config.config_path) orelse ".";
    const normalized_account_id = try normalizeTelegramAccountId(allocator, account_id);
    defer allocator.free(normalized_account_id);

    const file_name = try std.fmt.allocPrint(allocator, "update-offset-{s}.json", .{normalized_account_id});
    defer allocator.free(file_name);

    return std.fs.path.join(allocator, &.{ config_dir, "state", "telegram", file_name });
}

pub fn loadTelegramUpdateOffset(
    allocator: std.mem.Allocator,
    config: *const Config,
    account_id: []const u8,
    bot_token: []const u8,
) ?i64 {
    const path = telegramUpdateOffsetPath(allocator, config, account_id) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 16 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    if (obj.get("version")) |version_val| {
        if (version_val != .integer or version_val.integer != TELEGRAM_OFFSET_STORE_VERSION) return null;
    }

    const last_update_id_val = obj.get("last_update_id") orelse return null;
    if (last_update_id_val != .integer) return null;

    const expected_bot_id = extractTelegramBotId(bot_token);
    if (expected_bot_id) |expected| {
        const stored_bot_id_val = obj.get("bot_id") orelse return null;
        if (stored_bot_id_val != .string) return null;
        if (!std.mem.eql(u8, stored_bot_id_val.string, expected)) return null;
    } else if (obj.get("bot_id")) |stored_bot_id_val| {
        if (stored_bot_id_val != .null and stored_bot_id_val != .string) return null;
    }

    return last_update_id_val.integer;
}

pub fn saveTelegramUpdateOffset(
    allocator: std.mem.Allocator,
    config: *const Config,
    account_id: []const u8,
    bot_token: []const u8,
    update_id: i64,
) !void {
    const path = try telegramUpdateOffsetPath(allocator, config, account_id);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => try std.fs.cwd().makePath(dir),
        };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try std.fmt.format(buf.writer(allocator), "  \"version\": {d},\n", .{TELEGRAM_OFFSET_STORE_VERSION});
    try std.fmt.format(buf.writer(allocator), "  \"last_update_id\": {d},\n", .{update_id});
    if (extractTelegramBotId(bot_token)) |bot_id| {
        try std.fmt.format(buf.writer(allocator), "  \"bot_id\": \"{s}\"\n", .{bot_id});
    } else {
        try buf.appendSlice(allocator, "  \"bot_id\": null\n");
    }
    try buf.appendSlice(allocator, "}\n");

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        var tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer tmp_file.close();
        try tmp_file.writeAll(buf.items);
    }

    std.fs.renameAbsolute(tmp_path, path) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(buf.items);
    };
}

pub fn persistTelegramUpdateOffsetIfAdvanced(
    allocator: std.mem.Allocator,
    config: *const Config,
    account_id: []const u8,
    bot_token: []const u8,
    persisted_update_id: *i64,
    candidate_update_id: i64,
) void {
    if (candidate_update_id <= persisted_update_id.*) return;
    saveTelegramUpdateOffset(allocator, config, account_id, bot_token, candidate_update_id) catch |err| {
        log.warn("failed to persist telegram update offset: {}", .{err});
        return;
    };
    persisted_update_id.* = candidate_update_id;
}

fn signalGroupPeerId(reply_target: ?[]const u8) []const u8 {
    const target = reply_target orelse "unknown";
    if (std.mem.startsWith(u8, target, signal.GROUP_TARGET_PREFIX)) {
        const raw = target[signal.GROUP_TARGET_PREFIX.len..];
        if (raw.len > 0) return raw;
    }
    return target;
}

fn matrixRoomPeerId(reply_target: ?[]const u8) []const u8 {
    return reply_target orelse "unknown";
}

// ════════════════════════════════════════════════════════════════════════════
// TelegramLoopState — shared state between supervisor and polling thread
// ════════════════════════════════════════════════════════════════════════════

pub const TelegramLoopState = struct {
    /// Updated after each pollUpdates() — epoch seconds.
    last_activity: std.atomic.Value(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: std.atomic.Value(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,

    pub fn init() TelegramLoopState {
        return .{
            .last_activity = std.atomic.Value(i64).init(std.time.timestamp()),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }
};

// Re-export centralized ProviderHolder from providers module.
pub const ProviderHolder = providers.ProviderHolder;

// ════════════════════════════════════════════════════════════════════════════
// ChannelRuntime — container for polling-thread dependencies
// ════════════════════════════════════════════════════════════════════════════

pub const ChannelRuntime = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    session_mgr: session_mod.SessionManager,
    provider_bundle: provider_runtime.RuntimeProviderBundle,
    tools: []const tools_mod.Tool,
    mem_rt: ?memory_mod.MemoryRuntime,
    noop_obs: *observability.NoopObserver,
    subagent_manager: ?*subagent_mod.SubagentManager,
    completion_router: ?*SubagentCompletionRouter,
    policy_tracker: *security.RateTracker,
    security_policy: *security.SecurityPolicy,
    event_bus: ?*bus_mod.Bus,

    /// Initialize the runtime from config — mirrors main.zig:702-786 setup.
    pub fn init(allocator: std.mem.Allocator, config: *const Config, event_bus: ?*bus_mod.Bus) !*ChannelRuntime {
        return initWithProfile(allocator, config, event_bus, .main);
    }

    pub fn attachCompletionOutboundDispatch(
        self: *ChannelRuntime,
        ctx: ?*anyopaque,
        dispatch: LocalOutboundDispatchFn,
    ) void {
        if (self.completion_router) |router| {
            router.local_outbound_dispatch_ctx = ctx;
            router.local_outbound_dispatch = dispatch;
        }
    }

    pub fn initWithProfile(
        allocator: std.mem.Allocator,
        config: *const Config,
        event_bus: ?*bus_mod.Bus,
        tool_profile: tools_mod.ToolProfile,
    ) !*ChannelRuntime {
        var runtime_provider = try provider_runtime.RuntimeProviderBundle.init(allocator, config);
        errdefer runtime_provider.deinit();

        const provider_i = runtime_provider.provider();
        const resolved_key = runtime_provider.primaryApiKey();

        // MCP tools
        const mcp_tools: ?[]const tools_mod.Tool = if (config.mcp_servers.len > 0)
            mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
                log.warn("MCP init failed: {}", .{err});
                break :blk null;
            }
        else
            null;
        defer if (mcp_tools) |mt| allocator.free(mt);

        const subagent_manager = allocator.create(subagent_mod.SubagentManager) catch null;
        errdefer if (subagent_manager) |mgr| allocator.destroy(mgr);
        if (subagent_manager) |mgr| {
            mgr.* = subagent_mod.SubagentManager.init(allocator, config, event_bus, .{});
            errdefer {
                mgr.deinit();
            }
        }
        const completion_router = if (subagent_manager != null) allocator.create(SubagentCompletionRouter) catch null else null;
        errdefer if (completion_router) |router| allocator.destroy(router);

        const policy_tracker = try allocator.create(security.RateTracker);
        errdefer allocator.destroy(policy_tracker);
        policy_tracker.* = security.RateTracker.init(allocator, config.autonomy.max_actions_per_hour);
        errdefer policy_tracker.deinit();

        const security_policy = try allocator.create(security.SecurityPolicy);
        errdefer allocator.destroy(security_policy);
        security_policy.* = .{
            .autonomy = config.autonomy.level,
            .workspace_dir = config.workspace_dir,
            .workspace_only = config.autonomy.workspace_only,
            .allowed_commands = if (config.autonomy.allowed_commands.len > 0) config.autonomy.allowed_commands else &security.default_allowed_commands,
            .max_actions_per_hour = config.autonomy.max_actions_per_hour,
            .require_approval_for_medium_risk = config.autonomy.require_approval_for_medium_risk,
            .block_high_risk_commands = config.autonomy.block_high_risk_commands,
            .tracker = policy_tracker,
        };

        // agent_browser backend — construct a long-lived OrchestratorClient
        // when the backend is active. Same allocator as the tool slice, which
        // the channel runtime owns for its lifetime.
        const ab_client_mod = @import("browser_backend/client.zig");
        const ABClient = ab_client_mod.OrchestratorClient;
        const agent_browser_client: ?*ABClient =
            if (config.browser.enabled and std.mem.eql(u8, config.browser.backend, "agent_browser")) blk: {
                const c = allocator.create(ABClient) catch break :blk null;
                c.* = .{ .base_url = config.browser.agent_browser.orchestrator_url, .timeout_ms = config.browser.agent_browser.timeout_ms, .auth_token = ab_client_mod.resolveAuthToken(config.browser.agent_browser.auth_token) };
                break :blk c;
            } else null;

        // Tools
        const tools = tools_mod.allTools(allocator, config.workspace_dir, .{
            .tool_profile = tool_profile,
            .config = config,
            .http_enabled = config.http_request.enabled,
            .screenshot_enabled = true,
            .composio_api_key = if (config.composio.enabled) config.composio.api_key else null,
            .agent_browser_client = agent_browser_client,
            .mcp_tools = mcp_tools,
            .agents = config.agents,
            .fallback_api_key = resolved_key,
            .event_bus = event_bus,
            .tools_config = config.tools,
            .allowed_paths = config.autonomy.allowed_paths,
            .policy = security_policy,
            .subagent_manager = subagent_manager,
        }) catch &.{};
        errdefer if (tools.len > 0) tools_mod.deinitTools(allocator, tools);
        // agent_browser backend — channel runtime is per-account; bind a
        // stable "local" user so browser_new_session passes its bound guard.
        tools_mod.bindBrowserSessionTools(tools, "local");

        // Optional memory backend
        var mem_rt = memory_mod.initRuntimeWithOptions(allocator, &config.memory, config.workspace_dir, .{
            .providers = config.providers,
            .search_api_key_override = resolved_key,
        });
        errdefer if (mem_rt) |*rt| rt.deinit();
        const mem_opt: ?memory_mod.Memory = if (mem_rt) |rt| rt.memory else null;

        // Noop observer (heap for vtable stability)
        const noop_obs = try allocator.create(observability.NoopObserver);
        errdefer allocator.destroy(noop_obs);
        noop_obs.* = .{};
        const obs = noop_obs.observer();

        // Session manager
        var session_mgr = session_mod.SessionManager.init(allocator, config, provider_i, tools, mem_opt, obs, if (mem_rt) |rt| rt.session_store else null, if (mem_rt) |*rt| rt.response_cache else null);
        session_mgr.policy = security_policy;

        // Self — heap-allocated so pointers remain stable
        const self = try allocator.create(ChannelRuntime);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .session_mgr = session_mgr,
            .provider_bundle = runtime_provider,
            .tools = tools,
            .mem_rt = mem_rt,
            .noop_obs = noop_obs,
            .subagent_manager = subagent_manager,
            .completion_router = completion_router,
            .policy_tracker = policy_tracker,
            .security_policy = security_policy,
            .event_bus = event_bus,
        };
        // Wire MemoryRuntime pointer into SessionManager for /doctor diagnostics
        // and into memory tools for retrieval pipeline + vector sync.
        // self is heap-allocated so the pointer is stable.
        if (self.mem_rt) |*rt| {
            self.session_mgr.mem_rt = rt;
            tools_mod.bindMemoryRuntime(tools, rt);
            // iter27: transcript_read SessionStore binding
            tools_mod.bindSessionStore(tools, rt.session_store);
            // Wire audit trail into shell tool
            tools_mod.bindAuditMemory(tools, rt.memory, null);
        }
        // N1: image_generate Together key (channel runtime)
        tools_mod.bindImageGenerate(tools, tools_mod.lookupProviderApiKey(self.config.providers, "together"), self.config.image_model);
        if (self.subagent_manager) |mgr| {
            if (self.completion_router) |router| {
                router.* = .{
                    .session_mgr = &self.session_mgr,
                    .event_bus = event_bus,
                };
                mgr.attachCompletionDelivery(@ptrCast(router), appendSubagentCompletionToSession);
            }
        }
        if (self.subagent_manager) |mgr| {
            if (self.completion_router) |router| {
                router.* = .{
                    .session_mgr = &self.session_mgr,
                    .event_bus = event_bus,
                };
                mgr.attachCompletionDelivery(@ptrCast(router), appendSubagentCompletionToSession);
            }
        }
        return self;
    }

    pub fn deinit(self: *ChannelRuntime) void {
        const alloc = self.allocator;
        self.session_mgr.deinit();
        if (self.tools.len > 0) tools_mod.deinitTools(alloc, self.tools);
        if (self.subagent_manager) |mgr| {
            mgr.deinit();
            alloc.destroy(mgr);
        }
        if (self.completion_router) |router| alloc.destroy(router);
        if (self.mem_rt) |*rt| rt.deinit();
        self.provider_bundle.deinit();
        self.policy_tracker.deinit();
        alloc.destroy(self.security_policy);
        alloc.destroy(self.policy_tracker);
        alloc.destroy(self.noop_obs);
        alloc.destroy(self);
    }
};

fn buildTelegramInboundMetadata(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    msg: channels_mod.ChannelMessage,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"account_id\":\"");
    try appendJsonEscaped(&buf, allocator, account_id);
    try buf.appendSlice(allocator, "\",\"peer_kind\":\"");
    try buf.appendSlice(allocator, if (msg.is_group) "group" else "direct");
    try buf.appendSlice(allocator, "\",\"peer_id\":\"");
    try appendJsonEscaped(&buf, allocator, msg.sender);
    try buf.appendSlice(allocator, "\",\"is_group\":");
    try buf.appendSlice(allocator, if (msg.is_group) "true" else "false");
    try buf.appendSlice(allocator, ",\"is_dm\":");
    try buf.appendSlice(allocator, if (msg.is_group) "false" else "true");
    if (msg.message_id) |message_id| {
        try buf.appendSlice(allocator, ",\"message_id\":\"");
        try std.fmt.format(buf.writer(allocator), "{d}", .{message_id});
        try buf.appendSlice(allocator, "\"");
    }
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

fn buildSignalInboundMetadata(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    peer_id: []const u8,
    is_group: bool,
    sender_number: ?[]const u8,
    sender_uuid: ?[]const u8,
    group_id: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"account_id\":\"");
    try appendJsonEscaped(&buf, allocator, account_id);
    try buf.appendSlice(allocator, "\",\"peer_kind\":\"");
    try buf.appendSlice(allocator, if (is_group) "group" else "direct");
    try buf.appendSlice(allocator, "\",\"peer_id\":\"");
    try appendJsonEscaped(&buf, allocator, peer_id);
    try buf.appendSlice(allocator, "\",\"is_group\":");
    try buf.appendSlice(allocator, if (is_group) "true" else "false");
    try buf.appendSlice(allocator, ",\"is_dm\":");
    try buf.appendSlice(allocator, if (is_group) "false" else "true");
    if (sender_number) |value| {
        try buf.appendSlice(allocator, ",\"sender_number\":\"");
        try appendJsonEscaped(&buf, allocator, value);
        try buf.appendSlice(allocator, "\"");
    }
    if (sender_uuid) |value| {
        try buf.appendSlice(allocator, ",\"sender_uuid\":\"");
        try appendJsonEscaped(&buf, allocator, value);
        try buf.appendSlice(allocator, "\"");
    }
    if (group_id) |value| {
        try buf.appendSlice(allocator, ",\"group_id\":\"");
        try appendJsonEscaped(&buf, allocator, value);
        try buf.appendSlice(allocator, "\"");
    }
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

fn buildMatrixInboundMetadata(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    peer_id: []const u8,
    is_group: bool,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"account_id\":\"");
    try appendJsonEscaped(&buf, allocator, account_id);
    try buf.appendSlice(allocator, "\",\"peer_kind\":\"");
    try buf.appendSlice(allocator, if (is_group) "group" else "direct");
    try buf.appendSlice(allocator, "\",\"peer_id\":\"");
    try appendJsonEscaped(&buf, allocator, peer_id);
    try buf.appendSlice(allocator, "\",\"is_group\":");
    try buf.appendSlice(allocator, if (is_group) "true" else "false");
    try buf.appendSlice(allocator, ",\"is_dm\":");
    try buf.appendSlice(allocator, if (is_group) "false" else "true");
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

fn publishInboundFromPolling(
    allocator: std.mem.Allocator,
    event_bus: *bus_mod.Bus,
    channel: []const u8,
    sender_id: []const u8,
    chat_id: []const u8,
    content: []const u8,
    session_key: []const u8,
    metadata_json: ?[]const u8,
) bool {
    const inbound = bus_mod.makeInboundFull(
        allocator,
        channel,
        sender_id,
        chat_id,
        content,
        session_key,
        &.{},
        metadata_json,
    ) catch |err| {
        log.warn("{s} inbound build failed: {}", .{ channel, err });
        return false;
    };

    event_bus.publishInbound(inbound) catch |err| {
        log.warn("{s} inbound publish failed: {}", .{ channel, err });
        inbound.deinit(allocator);
        return false;
    };
    return true;
}

fn processTelegramMessages(
    allocator: std.mem.Allocator,
    config: *const Config,
    session_mgr: *session_mod.SessionManager,
    event_bus_opt: ?*bus_mod.Bus,
    tg_ptr: *telegram.TelegramChannel,
    messages: []const channels_mod.ChannelMessage,
) void {
    const model = config.default_model orelse return;

    for (messages) |msg| {
        handle_one: {
            const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "/start")) {
                var greeting_buf: [512]u8 = undefined;
                const name = msg.first_name orelse msg.id;
                const greeting = std.fmt.bufPrint(&greeting_buf, "Hello, {s}! I'm nullALIS.\n\nModel: {s}\nType /help for available commands.", .{ name, model }) catch "Hello! I'm nullALIS. Type /help for commands.";
                tg_ptr.sendMessageWithReply(msg.sender, greeting, msg.message_id) catch |err| log.err("failed to send /start reply: {}", .{err});
                break :handle_one;
            }

            const use_reply_to = msg.is_group or tg_ptr.reply_in_private;
            const reply_to_id: ?i64 = if (use_reply_to) msg.message_id else null;

            var key_buf: [128]u8 = undefined;
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);
            const tenant_user_id = telegramTenantUserId(config, tg_ptr.account_id);
            const session_key = blk: {
                if (telegramTenantMainSessionKey(config, tg_ptr.account_id, &key_buf)) |tenant_session_key| {
                    break :blk tenant_session_key;
                }
                const route = agent_routing.resolveRouteWithSession(allocator, .{
                    .channel = "telegram",
                    .account_id = tg_ptr.account_id,
                    .peer = .{ .kind = if (msg.is_group) .group else .direct, .id = msg.sender },
                }, config.agent_bindings, config.agents, config.session) catch break :blk std.fmt.bufPrint(&key_buf, "telegram:{s}:{s}", .{ tg_ptr.account_id, msg.sender }) catch msg.sender;
                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            if (event_bus_opt) |event_bus| {
                const metadata_json = buildTelegramInboundMetadata(allocator, tg_ptr.account_id, msg) catch |err| {
                    log.warn("telegram metadata build failed: {}", .{err});
                    break :handle_one;
                };
                defer allocator.free(metadata_json);

                _ = publishInboundFromPolling(
                    allocator,
                    event_bus,
                    "telegram",
                    msg.id,
                    msg.sender,
                    msg.content,
                    session_key,
                    metadata_json,
                );
                break :handle_one;
            }

            const typing_target = msg.sender;
            tg_ptr.startTyping(typing_target) catch {};
            defer tg_ptr.stopTyping(typing_target) catch {};
            _ = tenant_user_id;
            setTenantContextForSessionKey(config, session_key);
            defer tools_mod.clearTenantContext();

            const reply = session_mgr.processMessageWithToolContext(session_key, msg.content, null, .{
                .channel = "telegram",
                .account_id = tg_ptr.account_id,
                .chat_id = msg.sender,
                .is_group = msg.is_group,
                .is_dm = !msg.is_group,
            }) catch |err| {
                log.err("Agent error: {}", .{err});
                const err_msg: []const u8 = switch (err) {
                    error.Timeout => "The model request timed out. Please try again.",
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.",
                    error.NoResponseContent => "Model returned an empty response. Please retry or /new for a fresh session.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again or /new for a fresh session.",
                };
                tg_ptr.sendMessageWithReply(msg.sender, err_msg, reply_to_id) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
                break :handle_one;
            };
            defer allocator.free(reply);

            tg_ptr.sendMessageWithReply(msg.sender, reply, reply_to_id) catch |err| {
                log.warn("Send error: {}", .{err});
            };
        }
    }
}

fn telegramTenantUserId(config: *const Config, account_id: []const u8) ?[]const u8 {
    for (config.channels.telegram) |tg_cfg| {
        if (!std.mem.eql(u8, tg_cfg.account_id, account_id)) continue;
        return tg_cfg.tenant_user_id;
    }
    return null;
}

fn telegramTenantMainSessionKey(config: *const Config, account_id: []const u8, buf: []u8) ?[]const u8 {
    if (telegramTenantUserId(config, account_id)) |user_id| {
        return zaki_session.userMainSessionKey(buf, user_id);
    }
    return null;
}

fn setTenantContextForSessionKey(config: *const Config, session_key: []const u8) void {
    const tenant_user_id = zaki_session.parseUserIdFromSessionKey(session_key);
    const numeric_tenant_user_id = if (tenant_user_id) |user_id|
        std.fmt.parseInt(i64, user_id, 10) catch null
    else
        null;
    const expect_postgres_state = config.tenant.enabled and std.mem.eql(u8, config.state.backend, "postgres");
    tools_mod.setTenantContext(.{
        .user_id = tenant_user_id,
        .numeric_user_id = numeric_tenant_user_id,
        .session_key = session_key,
        .expect_postgres_state = expect_postgres_state and tenant_user_id != null,
    });
}

// ════════════════════════════════════════════════════════════════════════════
// runTelegramLoop — polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Thread-entry function for the Telegram polling loop.
/// Mirrors main.zig:793-866 but checks `loop_state.stop_requested` and
/// `daemon.isShutdownRequested()` for graceful shutdown.
///
/// `tg_ptr` is the channel instance owned by the supervisor (ChannelManager).
/// The polling loop uses it directly instead of creating a second
/// TelegramChannel, so health checks and polling operate on the same object.
pub fn runTelegramLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *TelegramLoopState,
    tg_ptr: *telegram.TelegramChannel,
) void {
    // Set up transcription — key comes from providers.{audio_media.provider}.
    // Audio routing is capability-driven: a model with native audio skips the
    // Whisper sidecar. Every current model is text-only for audio, so the
    // route is always `.transcription_sidecar` and the sidecar is attached.
    const trans = config.audio_media;
    const audio_native = model_capabilities.audioInputRoute(config.default_model orelse "") == .native;
    if (trans.enabled and !audio_native) {
        if (config.getProviderKey(trans.provider)) |key| {
            const wt = allocator.create(voice.WhisperTranscriber) catch {
                log.warn("Failed to allocate WhisperTranscriber", .{});
                return;
            };
            wt.* = .{
                .endpoint = voice.resolveTranscriptionEndpoint(trans.provider, trans.base_url),
                .api_key = key,
                .model = trans.model,
                .language = trans.language,
            };
            tg_ptr.transcriber = wt.transcriber();
            voice.markTelegramTranscriberConfigured();
        }
    }

    if (loadTelegramUpdateOffset(allocator, config, tg_ptr.account_id, tg_ptr.bot_token)) |saved_update_id| {
        tg_ptr.last_update_id = saved_update_id;
    }

    tg_ptr.deleteWebhookKeepPending();

    // Register bot commands
    tg_ptr.setMyCommands();
    var persisted_update_id: i64 = tg_ptr.last_update_id;

    var evict_counter: u32 = 0;

    if (config.default_model == null) {
        log.err("No default model configured. Set agents.defaults.model.primary in ~/.nullalis/config.json or run `nullalis onboard`.", .{});
        return;
    }

    // Update activity timestamp at start
    loop_state.last_activity.store(std.time.timestamp(), .release);

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = tg_ptr.pollUpdates(allocator) catch |err| {
            log.warn("Telegram poll error: {}", .{err});
            loop_state.last_activity.store(std.time.timestamp(), .release);
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        // Update activity after each poll (even if no messages)
        loop_state.last_activity.store(std.time.timestamp(), .release);

        processTelegramMessages(allocator, config, &runtime.session_mgr, runtime.event_bus, tg_ptr, messages);

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        if (tg_ptr.persistableUpdateOffset()) |persistable_update_id| {
            persistTelegramUpdateOffsetIfAdvanced(
                allocator,
                config,
                tg_ptr.account_id,
                tg_ptr.bot_token,
                &persisted_update_id,
                persistable_update_id,
            );
        }

        // Periodic session eviction
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }

        health.markComponentOk("telegram");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// SignalLoopState — shared state between supervisor and polling thread
// ════════════════════════════════════════════════════════════════════════════

pub const SignalLoopState = struct {
    /// Updated after each pollMessages() — epoch seconds.
    last_activity: std.atomic.Value(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: std.atomic.Value(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,

    pub fn init() SignalLoopState {
        return .{
            .last_activity = std.atomic.Value(i64).init(std.time.timestamp()),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// runSignalLoop — polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Thread-entry function for the Signal SSE polling loop.
/// Mirrors runTelegramLoop but uses signal-cli's SSE/JSON-RPC API.
/// Checks `loop_state.stop_requested` and `daemon.isShutdownRequested()`
/// for graceful shutdown.
pub fn runSignalLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *SignalLoopState,
    sg_ptr: *signal.SignalChannel,
) void {
    // Update activity timestamp at start
    loop_state.last_activity.store(std.time.timestamp(), .release);

    var evict_counter: u32 = 0;

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = sg_ptr.pollMessages(allocator) catch |err| {
            log.warn("Signal poll error: {}", .{err});
            loop_state.last_activity.store(std.time.timestamp(), .release);
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        // Update activity after each poll (even if no messages)
        loop_state.last_activity.store(std.time.timestamp(), .release);

        for (messages) |msg| {
            // Session key — always resolve through agent routing (falls back on errors)
            var key_buf: [128]u8 = undefined;
            const group_peer_id = signalGroupPeerId(msg.reply_target);
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);
            const session_key = blk: {
                const route = agent_routing.resolveRouteWithSession(allocator, .{
                    .channel = "signal",
                    .account_id = sg_ptr.account_id,
                    .peer = .{
                        .kind = if (msg.is_group) .group else .direct,
                        .id = if (msg.is_group) group_peer_id else msg.sender,
                    },
                }, config.agent_bindings, config.agents, config.session) catch break :blk if (msg.is_group)
                    std.fmt.bufPrint(&key_buf, "signal:{s}:group:{s}:{s}", .{
                        sg_ptr.account_id,
                        group_peer_id,
                        msg.sender,
                    }) catch msg.sender
                else
                    std.fmt.bufPrint(&key_buf, "signal:{s}:{s}", .{ sg_ptr.account_id, msg.sender }) catch msg.sender;
                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            const signal_target = msg.reply_target orelse msg.sender;
            if (runtime.event_bus) |event_bus| {
                const peer_id = if (msg.is_group) group_peer_id else msg.sender;
                const sender_number: ?[]const u8 = if (msg.sender.len > 0 and msg.sender[0] == '+') msg.sender else null;
                const metadata_json = buildSignalInboundMetadata(
                    allocator,
                    sg_ptr.account_id,
                    peer_id,
                    msg.is_group,
                    sender_number,
                    msg.sender_uuid,
                    msg.group_id,
                ) catch |err| {
                    log.warn("signal metadata build failed: {}", .{err});
                    continue;
                };
                defer allocator.free(metadata_json);

                _ = publishInboundFromPolling(
                    allocator,
                    event_bus,
                    "signal",
                    msg.sender,
                    signal_target,
                    msg.content,
                    session_key,
                    metadata_json,
                );
                continue;
            }

            const typing_target = msg.reply_target;
            if (typing_target) |target| sg_ptr.startTyping(target) catch {};
            defer if (typing_target) |target| sg_ptr.stopTyping(target) catch {};
            setTenantContextForSessionKey(config, session_key);
            defer tools_mod.clearTenantContext();

            // Build conversation context for Signal
            const conversation_context: ?ConversationContext = .{
                .channel = "signal",
                .sender_number = if (msg.sender.len > 0 and msg.sender[0] == '+') msg.sender else null,
                .sender_uuid = msg.sender_uuid,
                .group_id = msg.group_id,
                .is_group = msg.is_group,
            };

            const reply = runtime.session_mgr.processMessageWithToolContext(session_key, msg.content, conversation_context, .{
                .channel = "signal",
                .account_id = sg_ptr.account_id,
                .chat_id = signal_target,
                .is_group = msg.is_group,
                .is_dm = !msg.is_group,
            }) catch |err| {
                log.err("Signal agent error: {}", .{err});
                const err_msg: []const u8 = switch (err) {
                    error.Timeout => "The model request timed out. Please try again.",
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
                    error.NoResponseContent => "Model returned an empty response. Please try again.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again.",
                };
                if (msg.reply_target) |target| {
                    sg_ptr.sendMessage(target, err_msg, &.{}) catch |send_err| log.err("failed to send signal error reply: {}", .{send_err});
                }
                continue;
            };
            defer allocator.free(reply);

            // Reply on Signal
            if (msg.reply_target) |target| {
                sg_ptr.sendMessage(target, reply, &.{}) catch |err| {
                    log.warn("Signal send error: {}", .{err});
                };
            }
        }

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        // Periodic session eviction
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }

        health.markComponentOk("signal");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MatrixLoopState — shared state between supervisor and polling thread
// ════════════════════════════════════════════════════════════════════════════

pub const MatrixLoopState = struct {
    /// Updated after each pollMessages() — epoch seconds.
    last_activity: std.atomic.Value(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: std.atomic.Value(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,

    pub fn init() MatrixLoopState {
        return .{
            .last_activity = std.atomic.Value(i64).init(std.time.timestamp()),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// EmailLoopState — shared state between supervisor and IMAP polling thread
// ════════════════════════════════════════════════════════════════════════════

pub const EmailLoopState = struct {
    /// Updated after each pollMessages() — epoch seconds.
    last_activity: std.atomic.Value(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: std.atomic.Value(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,

    pub fn init() EmailLoopState {
        return .{
            .last_activity = std.atomic.Value(i64).init(std.time.timestamp()),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }
};

pub const PollingState = union(enum) {
    telegram: *TelegramLoopState,
    signal: *SignalLoopState,
    matrix: *MatrixLoopState,
    email: *EmailLoopState,
};

pub const PollingSpawnResult = struct {
    thread: std.Thread,
    state: PollingState,
};

pub fn spawnTelegramPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const tg_ls = try allocator.create(TelegramLoopState);
    errdefer allocator.destroy(tg_ls);
    tg_ls.* = TelegramLoopState.init();

    const tg_ptr: *telegram.TelegramChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        runTelegramLoop,
        .{ allocator, config, runtime, tg_ls, tg_ptr },
    );
    tg_ls.thread = thread;

    return .{
        .thread = thread,
        .state = .{ .telegram = tg_ls },
    };
}

pub fn spawnSignalPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const sg_ls = try allocator.create(SignalLoopState);
    errdefer allocator.destroy(sg_ls);
    sg_ls.* = SignalLoopState.init();

    const sg_ptr: *signal.SignalChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        runSignalLoop,
        .{ allocator, config, runtime, sg_ls, sg_ptr },
    );
    sg_ls.thread = thread;

    return .{
        .thread = thread,
        .state = .{ .signal = sg_ls },
    };
}

pub fn spawnMatrixPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const mx_ls = try allocator.create(MatrixLoopState);
    errdefer allocator.destroy(mx_ls);
    mx_ls.* = MatrixLoopState.init();

    const mx_ptr: *matrix.MatrixChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        runMatrixLoop,
        .{ allocator, config, runtime, mx_ls, mx_ptr },
    );
    mx_ls.thread = thread;

    return .{
        .thread = thread,
        .state = .{ .matrix = mx_ls },
    };
}

pub fn spawnEmailPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const em_ls = try allocator.create(EmailLoopState);
    errdefer allocator.destroy(em_ls);
    em_ls.* = EmailLoopState.init();

    const em_ptr: *email.EmailChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        runEmailLoop,
        .{ allocator, config, runtime, em_ls, em_ptr },
    );
    em_ls.thread = thread;

    return .{
        .thread = thread,
        .state = .{ .email = em_ls },
    };
}

// ════════════════════════════════════════════════════════════════════════════
// runMatrixLoop — polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Thread-entry function for Matrix /sync polling.
/// Uses account-aware route resolution and per-room reply targets.
pub fn runMatrixLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *MatrixLoopState,
    mx_ptr: *matrix.MatrixChannel,
) void {
    loop_state.last_activity.store(std.time.timestamp(), .release);

    var evict_counter: u32 = 0;

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = mx_ptr.pollMessages(allocator) catch |err| {
            log.warn("Matrix poll error: {}", .{err});
            loop_state.last_activity.store(std.time.timestamp(), .release);
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        loop_state.last_activity.store(std.time.timestamp(), .release);

        for (messages) |msg| {
            var key_buf: [192]u8 = undefined;
            const room_peer_id = matrixRoomPeerId(msg.reply_target);
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);

            const session_key = blk: {
                const route = agent_routing.resolveRouteWithSession(allocator, .{
                    .channel = "matrix",
                    .account_id = mx_ptr.account_id,
                    .peer = .{
                        .kind = if (msg.is_group) .group else .direct,
                        .id = if (msg.is_group) room_peer_id else msg.sender,
                    },
                }, config.agent_bindings, config.agents, config.session) catch break :blk if (msg.is_group)
                    std.fmt.bufPrint(&key_buf, "matrix:{s}:room:{s}", .{ mx_ptr.account_id, room_peer_id }) catch msg.sender
                else
                    std.fmt.bufPrint(&key_buf, "matrix:{s}:{s}", .{ mx_ptr.account_id, msg.sender }) catch msg.sender;

                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            const matrix_target = msg.reply_target orelse msg.sender;
            if (runtime.event_bus) |event_bus| {
                const peer_id = if (msg.is_group) room_peer_id else msg.sender;
                const metadata_json = buildMatrixInboundMetadata(
                    allocator,
                    mx_ptr.account_id,
                    peer_id,
                    msg.is_group,
                ) catch |err| {
                    log.warn("matrix metadata build failed: {}", .{err});
                    continue;
                };
                defer allocator.free(metadata_json);

                _ = publishInboundFromPolling(
                    allocator,
                    event_bus,
                    "matrix",
                    msg.sender,
                    matrix_target,
                    msg.content,
                    session_key,
                    metadata_json,
                );
                continue;
            }

            const typing_target = matrix_target;
            mx_ptr.startTyping(typing_target) catch {};
            defer mx_ptr.stopTyping(typing_target) catch {};
            setTenantContextForSessionKey(config, session_key);
            defer tools_mod.clearTenantContext();

            const reply = runtime.session_mgr.processMessageWithToolContext(session_key, msg.content, null, .{
                .channel = "matrix",
                .account_id = mx_ptr.account_id,
                .chat_id = matrix_target,
                .is_group = msg.is_group,
                .is_dm = !msg.is_group,
            }) catch |err| {
                log.err("Matrix agent error: {}", .{err});
                const err_msg: []const u8 = switch (err) {
                    error.Timeout => "The model request timed out. Please try again.",
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
                    error.NoResponseContent => "Model returned an empty response. Please try again.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again.",
                };
                mx_ptr.sendMessage(typing_target, err_msg) catch |send_err| log.err("failed to send matrix error reply: {}", .{send_err});
                continue;
            };
            defer allocator.free(reply);

            mx_ptr.sendMessage(typing_target, reply) catch |err| {
                log.warn("Matrix send error: {}", .{err});
            };
        }

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }

        health.markComponentOk("matrix");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// runEmailLoop — IMAP polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Build the inbound metadata JSON for an email message.
/// Email peers are always direct (1:1) — there is no group concept.
fn buildEmailInboundMetadata(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    peer_id: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"account_id\":\"");
    try appendJsonEscaped(&buf, allocator, account_id);
    try buf.appendSlice(allocator, "\",\"peer_kind\":\"direct\",\"peer_id\":\"");
    try appendJsonEscaped(&buf, allocator, peer_id);
    try buf.appendSlice(allocator, "\",\"is_group\":false,\"is_dm\":true}");
    return buf.toOwnedSlice(allocator);
}

/// Thread-entry function for the Email IMAP polling loop.
/// Mirrors runMatrixLoop but uses IMAP-over-TLS (channels/email.zig). Unlike
/// long-poll channels, IMAP has no server-held wait, so the loop sleeps for
/// `poll_interval_secs` between cycles. Checks `loop_state.stop_requested`
/// and `daemon.isShutdownRequested()` for graceful shutdown.
pub fn runEmailLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *EmailLoopState,
    em_ptr: *email.EmailChannel,
) void {
    loop_state.last_activity.store(std.time.timestamp(), .release);

    const account_id = em_ptr.config.account_id;
    // Clamp the poll interval to a sane minimum so a misconfigured 0 does
    // not spin the IMAP server.
    const poll_interval: u64 = @max(@as(u64, 5), em_ptr.config.poll_interval_secs);

    var evict_counter: u32 = 0;

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = em_ptr.pollMessages(allocator) catch |err| {
            log.warn("Email poll error: {}", .{err});
            loop_state.last_activity.store(std.time.timestamp(), .release);
            sleepInterruptible(loop_state, poll_interval);
            continue;
        };

        loop_state.last_activity.store(std.time.timestamp(), .release);

        for (messages) |msg| {
            // Email peers are always direct; the session key is per-sender.
            var key_buf: [192]u8 = undefined;
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);

            const session_key = blk: {
                const route = agent_routing.resolveRouteWithSession(allocator, .{
                    .channel = "email",
                    .account_id = account_id,
                    .peer = .{ .kind = .direct, .id = msg.sender },
                }, config.agent_bindings, config.agents, config.session) catch
                    break :blk std.fmt.bufPrint(&key_buf, "email:{s}:{s}", .{ account_id, msg.sender }) catch msg.sender;

                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            const email_target = msg.reply_target orelse msg.sender;

            if (runtime.event_bus) |event_bus| {
                const metadata_json = buildEmailInboundMetadata(
                    allocator,
                    account_id,
                    msg.sender,
                ) catch |err| {
                    log.warn("email metadata build failed: {}", .{err});
                    continue;
                };
                defer allocator.free(metadata_json);

                _ = publishInboundFromPolling(
                    allocator,
                    event_bus,
                    "email",
                    msg.sender,
                    email_target,
                    msg.content,
                    session_key,
                    metadata_json,
                );
                continue;
            }

            setTenantContextForSessionKey(config, session_key);
            defer tools_mod.clearTenantContext();

            const reply = runtime.session_mgr.processMessageWithToolContext(session_key, msg.content, null, .{
                .channel = "email",
                .account_id = account_id,
                .chat_id = email_target,
                .is_group = false,
                .is_dm = true,
            }) catch |err| {
                log.err("Email agent error: {}", .{err});
                const err_msg: []const u8 = switch (err) {
                    error.Timeout => "The model request timed out. Please try again.",
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
                    error.NoResponseContent => "Model returned an empty response. Please try again.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again.",
                };
                em_ptr.sendMessage(email_target, err_msg) catch |send_err| log.err("failed to send email error reply: {}", .{send_err});
                continue;
            };
            defer allocator.free(reply);

            em_ptr.sendMessage(email_target, reply) catch |err| {
                log.warn("Email send error: {}", .{err});
            };
        }

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }

        health.markComponentOk("email");
        sleepInterruptible(loop_state, poll_interval);
    }
}

/// Sleep for `secs` seconds in 1-second slices, returning early if a stop
/// or shutdown is requested. IMAP has no server-held long-poll, so the loop
/// paces itself between cycles without blocking shutdown for the full delay.
fn sleepInterruptible(loop_state: *EmailLoopState, secs: u64) void {
    var remaining = secs;
    while (remaining > 0) : (remaining -= 1) {
        if (loop_state.stop_requested.load(.acquire) or daemon.isShutdownRequested()) return;
        std.Thread.sleep(std.time.ns_per_s);
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "TelegramLoopState init defaults" {
    const state = TelegramLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "TelegramLoopState stop_requested toggle" {
    var state = TelegramLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "TelegramLoopState last_activity update" {
    var state = TelegramLoopState.init();
    const before = state.last_activity.load(.acquire);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.last_activity.store(std.time.timestamp(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

const MockTelegramProvider = struct {
    response: []const u8,

    const vtable = providers.Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
    };

    fn provider(self: *MockTelegramProvider) providers.Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockTelegramProvider = @ptrCast(@alignCast(ptr));
        return try allocator.dupe(u8, self.response);
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockTelegramProvider = @ptrCast(@alignCast(ptr));
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn mockDeinit(_: *anyopaque) void {}
};

const TelegramRequestRecorder = struct {
    allocator: std.mem.Allocator,
    methods: std.ArrayListUnmanaged([]const u8) = .empty,
    bodies: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *TelegramRequestRecorder) void {
        for (self.methods.items) |method| self.allocator.free(method);
        for (self.bodies.items) |body| self.allocator.free(body);
        self.methods.deinit(self.allocator);
        self.bodies.deinit(self.allocator);
    }

    fn handle(
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        _: u64,
    ) anyerror![]u8 {
        const self: *TelegramRequestRecorder = @ptrCast(@alignCast(ctx orelse return error.MissingContext));
        try self.methods.append(self.allocator, try self.allocator.dupe(u8, method));
        try self.bodies.append(self.allocator, try self.allocator.dupe(u8, body));
        return try allocator.dupe(u8, "{\"ok\":true}");
    }
};

fn testTelegramConfig() Config {
    return .{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .agents = &.{.{
            .name = "zaki-bot",
            .provider = "mock",
            .model = "test/mock-model",
        }},
        .session = .{ .dm_scope = .main },
        .allocator = std.testing.allocator,
    };
}

fn testTelegramSessionManager(
    allocator: std.mem.Allocator,
    mock: *MockTelegramProvider,
    cfg: *const Config,
) session_mod.SessionManager {
    var noop = observability.NoopObserver{};
    return session_mod.SessionManager.init(
        allocator,
        cfg,
        mock.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
}

test "ChannelRuntime wires event bus into subagent manager" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);
    const config_path = try std.fs.path.join(allocator, &.{ workspace, "config.json" });
    defer allocator.free(config_path);

    var cfg = testTelegramConfig();
    cfg.workspace_dir = workspace;
    cfg.config_path = config_path;

    var eb = bus_mod.Bus.init();
    defer eb.close();

    const runtime = try ChannelRuntime.init(allocator, &cfg, &eb);
    defer runtime.deinit();

    const mgr = runtime.subagent_manager orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?*bus_mod.Bus, &eb), mgr.bus);
}

test "ChannelRuntime wires local subagent completion delivery" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);
    const config_path = try std.fs.path.join(allocator, &.{ workspace, "config.json" });
    defer allocator.free(config_path);

    var cfg = testTelegramConfig();
    cfg.workspace_dir = workspace;
    cfg.config_path = config_path;

    const runtime = try ChannelRuntime.init(allocator, &cfg, null);
    defer runtime.deinit();

    const mgr = runtime.subagent_manager orelse return error.TestUnexpectedResult;
    try std.testing.expect(mgr.completion_delivery != null);
}

test "subagent completion appends parent session and emits outbound message" {
    const allocator = std.testing.allocator;
    var mock = MockTelegramProvider{ .response = "ok" };
    const cfg = testTelegramConfig();
    var session_mgr = testTelegramSessionManager(allocator, &mock, &cfg);
    defer session_mgr.deinit();

    const session = try session_mgr.getOrCreate("agent:zaki-bot:user:1:main");
    session.origin_channel = try allocator.dupe(u8, "telegram");
    session.origin_account_id = try allocator.dupe(u8, "main");
    session.origin_chat_id = try allocator.dupe(u8, "12345");

    var event_bus = bus_mod.Bus.init();
    defer event_bus.close();

    var router = SubagentCompletionRouter{
        .session_mgr = &session_mgr,
        .event_bus = &event_bus,
    };

    try appendSubagentCompletionToSession(@ptrCast(&router), "agent:zaki-bot:user:1:main", "[Subagent 'research'] completed\nanswer");

    try std.testing.expectEqual(@as(usize, 1), session.agent.historyLen());
    try std.testing.expectEqualStrings("[Subagent 'research'] completed\nanswer", session.agent.history.items[0].content);
    try std.testing.expectEqual(@as(usize, 1), event_bus.outboundDepth());

    var outbound = event_bus.consumeOutbound() orelse return error.TestUnexpectedResult;
    defer outbound.deinit(allocator);
    try std.testing.expectEqualStrings("telegram", outbound.channel);
    try std.testing.expectEqualStrings("main", outbound.account_id.?);
    try std.testing.expectEqualStrings("12345", outbound.chat_id);
    try std.testing.expectEqualStrings("[Subagent 'research'] completed\nanswer", outbound.content);
}

test "subagent completion keeps zaki_app results pending instead of emitting outbound" {
    const allocator = std.testing.allocator;
    var mock = MockTelegramProvider{ .response = "ok" };
    const cfg = testTelegramConfig();
    var session_mgr = testTelegramSessionManager(allocator, &mock, &cfg);
    defer session_mgr.deinit();

    const session_key = "agent:zaki-bot:user:1:main";
    const session = try session_mgr.getOrCreate(session_key);
    session.origin_channel = try allocator.dupe(u8, "zaki_app");
    session.origin_chat_id = try allocator.dupe(u8, session_key);

    var event_bus = bus_mod.Bus.init();
    defer event_bus.close();

    var router = SubagentCompletionRouter{
        .session_mgr = &session_mgr,
        .event_bus = &event_bus,
    };

    try appendSubagentCompletionToSession(@ptrCast(&router), session_key, "[Subagent 'research'] completed\nanswer");
    try std.testing.expectEqual(@as(usize, 1), session.agent.historyLen());
    try std.testing.expectEqualStrings("[Subagent 'research'] completed\nanswer", session.agent.history.items[0].content);
    try std.testing.expectEqual(@as(usize, 0), event_bus.outboundDepth());
}

test "subagent completion uses local outbound dispatch when runtime has no bus" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);
    const config_path = try std.fs.path.join(allocator, &.{ workspace, "config.json" });
    defer allocator.free(config_path);

    var cfg = testTelegramConfig();
    cfg.workspace_dir = workspace;
    cfg.config_path = config_path;

    const runtime = try ChannelRuntime.init(allocator, &cfg, null);
    defer runtime.deinit();

    const DispatchRecorder = struct {
        const Self = @This();
        called: bool = false,

        fn dispatch(ctx: ?*anyopaque, outbound: *const bus_mod.OutboundMessage) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.called = true;
            try std.testing.expectEqualStrings("telegram", outbound.channel);
            try std.testing.expectEqualStrings("12345", outbound.chat_id);
            try std.testing.expectEqualStrings("[Subagent 'research'] completed\nanswer", outbound.content);
        }
    };

    var recorder = DispatchRecorder{};
    runtime.attachCompletionOutboundDispatch(@ptrCast(&recorder), DispatchRecorder.dispatch);

    const session = try runtime.session_mgr.getOrCreate("agent:zaki-bot:user:1:main");
    session.origin_channel = try allocator.dupe(u8, "telegram");
    session.origin_chat_id = try allocator.dupe(u8, "12345");

    const mgr = runtime.subagent_manager orelse return error.TestUnexpectedResult;
    const delivery = mgr.completion_delivery orelse return error.TestUnexpectedResult;
    try delivery(mgr.completion_delivery_ctx, "agent:zaki-bot:user:1:main", "[Subagent 'research'] completed\nanswer");

    try std.testing.expect(recorder.called);
}

test "processTelegramMessages replies through direct telegram send path" {
    const allocator = std.testing.allocator;
    var mock = MockTelegramProvider{ .response = "pong" };
    const cfg = testTelegramConfig();
    var session_mgr = testTelegramSessionManager(allocator, &mock, &cfg);
    defer session_mgr.deinit();

    var recorder = TelegramRequestRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var tg = telegram.TelegramChannel.init(allocator, "123:ABC", &.{"*"}, &.{}, "open");
    defer tg.channel().stop();
    tg.request_json_override = TelegramRequestRecorder.handle;
    tg.request_json_ctx = @ptrCast(&recorder);

    const msg = channels_mod.ChannelMessage{
        .id = try allocator.dupe(u8, "alice"),
        .sender = try allocator.dupe(u8, "12345"),
        .content = try allocator.dupe(u8, "ping"),
        .channel = "telegram",
        .timestamp = 1,
        .message_id = 7,
        .first_name = try allocator.dupe(u8, "Alice"),
        .is_group = false,
    };
    defer msg.deinit(allocator);

    processTelegramMessages(allocator, &cfg, &session_mgr, null, &tg, &.{msg});

    try std.testing.expectEqual(@as(usize, 1), recorder.methods.items.len);
    try std.testing.expectEqualStrings("sendMessage", recorder.methods.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, recorder.bodies.items[0], "\"chat_id\":12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.bodies.items[0], "\"text\":\"pong\"") != null);

    const session = try session_mgr.getOrCreate("agent:zaki-bot:main");
    try std.testing.expectEqual(@as(u64, 1), session.turn_count);
}

test "processTelegramMessages publishes inbound on bus when event bus is present" {
    const allocator = std.testing.allocator;
    var mock = MockTelegramProvider{ .response = "pong" };
    const cfg = testTelegramConfig();
    var session_mgr = testTelegramSessionManager(allocator, &mock, &cfg);
    defer session_mgr.deinit();

    var recorder = TelegramRequestRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var eb = bus_mod.Bus.init();
    defer eb.close();

    var tg = telegram.TelegramChannel.init(allocator, "123:ABC", &.{"*"}, &.{}, "open");
    defer tg.channel().stop();
    tg.request_json_override = TelegramRequestRecorder.handle;
    tg.request_json_ctx = @ptrCast(&recorder);

    const msg = channels_mod.ChannelMessage{
        .id = try allocator.dupe(u8, "alice"),
        .sender = try allocator.dupe(u8, "12345"),
        .content = try allocator.dupe(u8, "ping"),
        .channel = "telegram",
        .timestamp = 1,
        .message_id = 7,
        .first_name = try allocator.dupe(u8, "Alice"),
        .is_group = false,
    };
    defer msg.deinit(allocator);

    processTelegramMessages(allocator, &cfg, &session_mgr, &eb, &tg, &.{msg});

    // No immediate direct send on polling thread path when bus is configured.
    try std.testing.expectEqual(@as(usize, 0), recorder.methods.items.len);

    const inbound = eb.consumeInbound() orelse return error.TestUnexpectedResult;
    defer inbound.deinit(allocator);
    try std.testing.expectEqualStrings("telegram", inbound.channel);
    try std.testing.expectEqualStrings("alice", inbound.sender_id);
    try std.testing.expectEqualStrings("12345", inbound.chat_id);
    try std.testing.expectEqualStrings("ping", inbound.content);
    try std.testing.expect(inbound.metadata_json != null);
    try std.testing.expect(std.mem.indexOf(u8, inbound.metadata_json.?, "\"account_id\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inbound.metadata_json.?, "\"peer_kind\":\"direct\"") != null);
}

test "processTelegramMessages handles start command without creating a session" {
    const allocator = std.testing.allocator;
    var mock = MockTelegramProvider{ .response = "ignored" };
    const cfg = testTelegramConfig();
    var session_mgr = testTelegramSessionManager(allocator, &mock, &cfg);
    defer session_mgr.deinit();

    var recorder = TelegramRequestRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var tg = telegram.TelegramChannel.init(allocator, "123:ABC", &.{"*"}, &.{}, "open");
    defer tg.channel().stop();
    tg.request_json_override = TelegramRequestRecorder.handle;
    tg.request_json_ctx = @ptrCast(&recorder);

    const msg = channels_mod.ChannelMessage{
        .id = try allocator.dupe(u8, "alice"),
        .sender = try allocator.dupe(u8, "12345"),
        .content = try allocator.dupe(u8, "/start"),
        .channel = "telegram",
        .timestamp = 1,
        .message_id = 99,
        .first_name = try allocator.dupe(u8, "Alice"),
        .is_group = false,
    };
    defer msg.deinit(allocator);

    processTelegramMessages(allocator, &cfg, &session_mgr, null, &tg, &.{msg});

    try std.testing.expectEqual(@as(usize, 1), recorder.methods.items.len);
    try std.testing.expectEqualStrings("sendMessage", recorder.methods.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, recorder.bodies.items[0], "\"message_id\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.bodies.items[0], "Hello, Alice!") != null);
    try std.testing.expectEqual(@as(usize, 0), session_mgr.sessionCount());
}

test "processTelegramMessages uses canonical tenant main session when telegram account is bound" {
    const allocator = std.testing.allocator;
    var mock = MockTelegramProvider{ .response = "pong" };
    const tg_accounts = [_]config_types.TelegramConfig{
        .{
            .account_id = "main",
            .bot_token = "123:ABC",
            .tenant_user_id = "42",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .agents = &.{.{
            .name = "zaki-bot",
            .provider = "mock",
            .model = "test/mock-model",
        }},
        .channels = .{ .telegram = &tg_accounts },
        .allocator = allocator,
    };
    var session_mgr = testTelegramSessionManager(allocator, &mock, &cfg);
    defer session_mgr.deinit();

    var recorder = TelegramRequestRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var tg = telegram.TelegramChannel.init(allocator, "123:ABC", &.{"*"}, &.{}, "open");
    tg.account_id = "main";
    defer tg.channel().stop();
    tg.request_json_override = TelegramRequestRecorder.handle;
    tg.request_json_ctx = @ptrCast(&recorder);

    const msg = channels_mod.ChannelMessage{
        .id = try allocator.dupe(u8, "alice"),
        .sender = try allocator.dupe(u8, "12345"),
        .content = try allocator.dupe(u8, "ping"),
        .channel = "telegram",
        .timestamp = 1,
        .message_id = 7,
        .first_name = try allocator.dupe(u8, "Alice"),
        .is_group = false,
    };
    defer msg.deinit(allocator);

    processTelegramMessages(allocator, &cfg, &session_mgr, null, &tg, &.{msg});

    const session = try session_mgr.getOrCreate("agent:zaki-bot:user:42:main");
    try std.testing.expectEqual(@as(u64, 1), session.turn_count);
}

test "telegramTenantUserId resolves tenant binding by account id" {
    const tg_accounts = [_]config_types.TelegramConfig{
        .{
            .account_id = "main",
            .bot_token = "123:ABC",
            .tenant_user_id = "42",
        },
        .{
            .account_id = "backup",
            .bot_token = "456:DEF",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .channels = .{ .telegram = &tg_accounts },
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("42", telegramTenantUserId(&cfg, "main").?);
    try std.testing.expect(telegramTenantUserId(&cfg, "backup") == null);
    try std.testing.expect(telegramTenantUserId(&cfg, "missing") == null);
}

test "ProviderHolder tagged union fields" {
    // Compile-time check that ProviderHolder has expected variants
    try std.testing.expect(@hasField(ProviderHolder, "openrouter"));
    try std.testing.expect(@hasField(ProviderHolder, "anthropic"));
    try std.testing.expect(@hasField(ProviderHolder, "openai"));
    try std.testing.expect(@hasField(ProviderHolder, "gemini"));
    try std.testing.expect(@hasField(ProviderHolder, "ollama"));
    try std.testing.expect(@hasField(ProviderHolder, "compatible"));
    try std.testing.expect(@hasField(ProviderHolder, "openai_codex"));
}

test "SignalLoopState init defaults" {
    const state = SignalLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "SignalLoopState stop_requested toggle" {
    var state = SignalLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "SignalLoopState last_activity update" {
    var state = SignalLoopState.init();
    const before = state.last_activity.load(.acquire);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.last_activity.store(std.time.timestamp(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

test "MatrixLoopState init defaults" {
    const state = MatrixLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "MatrixLoopState stop_requested toggle" {
    var state = MatrixLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "MatrixLoopState last_activity update" {
    var state = MatrixLoopState.init();
    const before = state.last_activity.load(.acquire);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.last_activity.store(std.time.timestamp(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

test "signalGroupPeerId extracts group id from reply target" {
    const peer_id = signalGroupPeerId("group:1203630@g.us");
    try std.testing.expectEqualStrings("1203630@g.us", peer_id);
}

test "signalGroupPeerId falls back when reply target is missing or malformed" {
    try std.testing.expectEqualStrings("unknown", signalGroupPeerId(null));
    try std.testing.expectEqualStrings("group:", signalGroupPeerId("group:"));
    try std.testing.expectEqualStrings("direct:+15550001111", signalGroupPeerId("direct:+15550001111"));
}

test "matrixRoomPeerId falls back when reply target is missing" {
    try std.testing.expectEqualStrings("unknown", matrixRoomPeerId(null));
    try std.testing.expectEqualStrings("!room:example", matrixRoomPeerId("!room:example"));
}
