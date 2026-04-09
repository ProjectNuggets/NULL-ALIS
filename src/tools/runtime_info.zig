const std = @import("std");
const channel_catalog = @import("../channel_catalog.zig");
const config_mod = @import("../config.zig");
const runtime_truth = @import("../diagnostics/runtime_truth.zig");
const inbound_canonicalizer = @import("../inbound_canonicalizer.zig");
const json_util = @import("../json_util.zig");
const multimodal = @import("../multimodal.zig");
const ops_guard = @import("../ops_guard.zig");
const tool_dispatcher = @import("../tool_dispatcher.zig");
const process_util = @import("process_util.zig");
const voice = @import("../voice.zig");
const lane_metrics = @import("../lane_metrics.zig");
const zaki_session = @import("../zaki_session.zig");
const root = @import("root.zig");

const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const COMPOSIO_API_BASE_V1 = "https://backend.composio.dev/api/v1";
const COMPOSIO_API_BASE_V3 = "https://backend.composio.dev/api/v3";

const ComposioEntityResolution = struct {
    entity_id: []const u8,
    source: []const u8,
};

const ComposioReadiness = struct {
    connected_accounts_state: []const u8 = "unknown",
    api_reachable: ?bool = null,
    gmail_toolkit_available: ?bool = null,
    google_drive_toolkit_available: ?bool = null,
    google_calendar_toolkit_available: ?bool = null,
    gmail_connected: ?bool = null,
    google_drive_connected: ?bool = null,
    google_calendar_connected: ?bool = null,
};

const ConnectedAccountsStatus = struct {
    gmail_connected: bool = false,
    google_drive_connected: bool = false,
    google_calendar_connected: bool = false,
};

fn sessionLaneLabel(session_key: ?[]const u8) []const u8 {
    const key = session_key orelse return "none";
    if (std.mem.indexOf(u8, key, ":task:") != null or std.mem.startsWith(u8, key, "task:")) return "task";
    if (std.mem.indexOf(u8, key, ":cron:") != null or std.mem.startsWith(u8, key, "cron:")) return "cron";
    if (std.mem.indexOf(u8, key, ":thread:") != null or std.mem.startsWith(u8, key, "thread:")) return "thread";
    if (std.mem.endsWith(u8, key, ":main") or std.mem.eql(u8, key, "main")) return "main";
    return "custom";
}

pub const RuntimeInfoTool = struct {
    config: *const config_mod.Config,
    runtime_tools: ?[]const Tool = null,

    pub const tool_name = "runtime_info";
    pub const tool_description = "Inspect runtime, session, integrations, scheduler, heartbeat, execution truth, and ops state as structured JSON. Use it to verify status before claiming it.";
    pub const tool_params =
        \\{"type":"object","properties":{"section":{"type":"string","enum":["summary","session","integrations","scheduler","heartbeat","execution_truth","ops"],"description":"Runtime section to inspect"},"user_id":{"type":"string","description":"Optional tenant user id override for reporting"},"verbose":{"type":"boolean","description":"Include larger summaries where available"}}}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *RuntimeInfoTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *RuntimeInfoTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const section = root.getString(args, "section") orelse "summary";
        const verbose = root.getBool(args, "verbose") orelse false;
        const user_id_override = root.getString(args, "user_id");

        const output = if (std.mem.eql(u8, section, "summary"))
            try self.buildSummaryJson(allocator, user_id_override, verbose)
        else if (std.mem.eql(u8, section, "session"))
            try self.buildSessionJson(allocator)
        else if (std.mem.eql(u8, section, "integrations"))
            try self.buildIntegrationsJson(allocator, user_id_override)
        else if (std.mem.eql(u8, section, "scheduler"))
            try self.buildSchedulerJson(allocator, user_id_override)
        else if (std.mem.eql(u8, section, "heartbeat"))
            try self.buildHeartbeatJson(allocator, user_id_override)
        else if (std.mem.eql(u8, section, "execution_truth"))
            try self.buildExecutionTruthJson(allocator, user_id_override)
        else if (std.mem.eql(u8, section, "ops"))
            try self.buildOpsJson(allocator)
        else
            return ToolResult.fail("Unknown section. Use summary, session, integrations, scheduler, heartbeat, execution_truth, or ops.");

        return ToolResult{ .success = true, .output = output };
    }

    fn buildSummaryJson(self: *RuntimeInfoTool, allocator: std.mem.Allocator, user_id_override: ?[]const u8, verbose: bool) ![]u8 {
        const tenant_ctx = root.getTenantContext();
        const turn_ctx = root.getTurnContext();
        const effective_backend = root.effectiveStateBackend(self.config, tenant_ctx);
        const scheduler_truth = resolveSchedulerTruth(self.config, tenant_ctx, user_id_override);
        const scheduler_backend = scheduler_truth.toSlice();
        const degraded_reason = root.degradedReason(self.config, tenant_ctx);
        const degraded = degraded_reason.len > 0;
        const context_incomplete = scheduler_truth == .context_missing;
        const data_source = runtimeDataSourceLabel(self.config, tenant_ctx, user_id_override);
        const heartbeat_cfg = try readEffectiveHeartbeatConfig(allocator, self.config, tenant_ctx, user_id_override);
        const chat_provider_effective = normalizeProviderAlias(self.config.default_provider);
        const embedding_provider_effective = normalizeProviderAlias(self.config.memory.search.provider);
        const chat_fallback_chain = try allocNormalizedFallbackChain(allocator, self.config.reliability.fallback_providers);
        defer allocator.free(chat_fallback_chain);
        const user_id = user_id_override orelse tenant_ctx.user_id;
        const entity_resolution = resolveComposioEntity(self.config, tenant_ctx, user_id_override);
        var telegram_state = try readTelegramState(allocator, self.config, tenant_ctx, user_id_override);
        defer telegram_state.deinit(allocator);
        var ownership_lease = try readOwnershipLeaseState(allocator, tenant_ctx, user_id_override);
        defer ownership_lease.deinit(allocator);
        var lane_snapshot = try lane_metrics.snapshotBackgroundMainReroutes(allocator);
        defer lane_snapshot.deinit(allocator);

        var configured_channels: std.ArrayListUnmanaged([]const u8) = .empty;
        defer configured_channels.deinit(allocator);
        for (channel_catalog.known_channels) |meta| {
            if (channel_catalog.isBuildEnabled(meta.id) and channel_catalog.configuredCount(self.config, meta.id) > 0) {
                try configured_channels.append(allocator, meta.key);
            }
        }
        if (isTelegramConfigured(self.config, telegram_state.state) and !containsString(configured_channels.items, "telegram")) {
            try configured_channels.append(allocator, "telegram");
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKeyValue(&buf, allocator, "provider", turn_ctx.provider orelse self.config.default_provider);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "model", turn_ctx.model orelse (self.config.default_model orelse ""));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "turn_origin", turn_ctx.origin.toSlice());
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "session_key");
        if (turn_ctx.session_key) |session_key| {
            try json_util.appendJsonString(&buf, allocator, session_key);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "user_id");
        if (user_id) |resolved| {
            try json_util.appendJsonString(&buf, allocator, resolved);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "state_backend_configured", self.config.state.backend);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "state_backend_effective", effective_backend);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "scheduler_backend", scheduler_backend);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "data_source", data_source);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "chat_provider_effective", chat_provider_effective);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "chat_fallback_chain", chat_fallback_chain);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "embedding_provider_effective", embedding_provider_effective);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "provider_data_source", "config");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "tool_dispatcher_configured", self.config.agent.tool_dispatcher);
        try buf.appendSlice(allocator, ",");
        const dispatch_parsed = tool_dispatcher.parseMode(self.config.agent.tool_dispatcher);
        try json_util.appendJsonKeyValue(&buf, allocator, "tool_dispatcher_effective", tool_dispatcher.effectiveMode(self.config.agent.parallel_tools, dispatch_parsed.mode).toSlice());
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "tool_dispatcher_supported");
        try buf.appendSlice(allocator, if (dispatch_parsed.supported) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "parallel_tools");
        try buf.appendSlice(allocator, if (self.config.agent.parallel_tools) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "parallel_tools_rollout_percent", self.config.agent.parallel_tools_rollout_percent);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "context_incomplete");
        try buf.appendSlice(allocator, if (context_incomplete) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "degraded");
        try buf.appendSlice(allocator, if (degraded) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "degraded_reason", degraded_reason);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "heartbeat_enabled");
        try buf.appendSlice(allocator, if (heartbeat_cfg.enabled) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "heartbeat_interval_minutes", heartbeat_cfg.interval_minutes);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "background_main_reroutes_total", @intCast(lane_snapshot.total));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "background_main_reroutes_last_job_id");
        if (lane_snapshot.last_job_id) |job_id| {
            try json_util.appendJsonString(&buf, allocator, job_id);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "tenant_enabled");
        try buf.appendSlice(allocator, if (self.config.tenant.enabled) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "telegram_dm_same_user_main");
        try buf.appendSlice(allocator, "true");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "telegram_group_session_policy", "thread");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "session_idle_evict_on_request_path");
        try buf.appendSlice(allocator, "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "configured_channels");
        try appendStringArray(&buf, allocator, configured_channels.items);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "enabled_tools");
        try appendToolNames(&buf, allocator, self.runtime_tools);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "deferred_controls");
        try appendDeferredControls(&buf, allocator, self.config);
        try buf.appendSlice(allocator, ",");
        try appendIdentityMapping(&buf, allocator, self.config);
        try buf.appendSlice(allocator, ",");
        try appendSttMetrics(&buf, allocator);
        try buf.appendSlice(allocator, ",");
        try appendMultimodalMetrics(&buf, allocator);
        try buf.appendSlice(allocator, ",");
        try appendOwnershipLease(&buf, allocator, ownership_lease);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "composio");
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKey(&buf, allocator, "enabled");
        try buf.appendSlice(allocator, if (self.config.composio.enabled) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "configured");
        try buf.appendSlice(allocator, if (self.config.composio.api_key != null and self.config.composio.enabled) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "entity_id");
        try json_util.appendJsonString(&buf, allocator, entity_resolution.entity_id);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "entity_scope_source", entity_resolution.source);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "auth_flow_requires_user_turn");
        try buf.appendSlice(allocator, "true");
        try buf.appendSlice(allocator, "}");
        if (verbose) {
            try buf.appendSlice(allocator, ",");
            try json_util.appendJsonKeyValue(&buf, allocator, "workspace_dir", self.config.workspace_dir);
        }
        try buf.appendSlice(allocator, "}");
        return try buf.toOwnedSlice(allocator);
    }

    fn buildSessionJson(self: *RuntimeInfoTool, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        const tenant_ctx = root.getTenantContext();
        const turn_ctx = root.getTurnContext();
        const session_key = turn_ctx.session_key;
        const canonical_user_id = if (session_key) |value| zaki_session.parseUserIdFromSessionKey(value) else null;
        const lane = sessionLaneLabel(session_key);
        const same_user_truth = if (tenant_ctx.user_id) |tenant_user_id|
            if (canonical_user_id) |resolved_user_id|
                std.mem.eql(u8, tenant_user_id, resolved_user_id)
            else
                false
        else
            canonical_user_id != null;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKeyValue(&buf, allocator, "turn_origin", turn_ctx.origin.toSlice());
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "session_key");
        if (session_key) |resolved_session_key| {
            try json_util.appendJsonString(&buf, allocator, resolved_session_key);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "session_lane", lane);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "canonical_user_id");
        if (canonical_user_id) |resolved_user_id| {
            try json_util.appendJsonString(&buf, allocator, resolved_user_id);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "tenant_user_id");
        if (tenant_ctx.user_id) |user_id| {
            try json_util.appendJsonString(&buf, allocator, user_id);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try appendOptionalInt(&buf, allocator, "tenant_numeric_user_id", tenant_ctx.numeric_user_id);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "same_user_truth");
        try buf.appendSlice(allocator, if (same_user_truth) "true" else "false");
        try buf.appendSlice(allocator, "}");
        return try buf.toOwnedSlice(allocator);
    }

    fn buildIntegrationsJson(self: *RuntimeInfoTool, allocator: std.mem.Allocator, user_id_override: ?[]const u8) ![]u8 {
        const tenant_ctx = root.getTenantContext();
        const scheduler_truth = resolveSchedulerTruth(self.config, tenant_ctx, user_id_override);
        const context_incomplete = scheduler_truth == .context_missing;
        const data_source = runtimeDataSourceLabel(self.config, tenant_ctx, user_id_override);
        const chat_provider_effective = normalizeProviderAlias(self.config.default_provider);
        const embedding_provider_effective = normalizeProviderAlias(self.config.memory.search.provider);
        const chat_fallback_chain = try allocNormalizedFallbackChain(allocator, self.config.reliability.fallback_providers);
        defer allocator.free(chat_fallback_chain);
        const entity_resolution = resolveComposioEntity(self.config, tenant_ctx, user_id_override);
        var telegram_state = try readTelegramState(allocator, self.config, tenant_ctx, user_id_override);
        defer telegram_state.deinit(allocator);
        var ownership_lease = try readOwnershipLeaseState(allocator, tenant_ctx, user_id_override);
        defer ownership_lease.deinit(allocator);
        const telegram_configured = isTelegramConfigured(self.config, telegram_state.state);
        const composio_readiness = self.resolveComposioReadiness(allocator, entity_resolution.entity_id);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKeyValue(&buf, allocator, "data_source", data_source);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "chat_provider_effective", chat_provider_effective);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "chat_fallback_chain", chat_fallback_chain);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "embedding_provider_effective", embedding_provider_effective);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "provider_data_source", "config");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "context_incomplete");
        try buf.appendSlice(allocator, if (context_incomplete) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try appendIdentityMapping(&buf, allocator, self.config);
        try buf.appendSlice(allocator, ",");
        try appendSttMetrics(&buf, allocator);
        try buf.appendSlice(allocator, ",");
        try appendMultimodalMetrics(&buf, allocator);
        try buf.appendSlice(allocator, ",");
        try appendOwnershipLease(&buf, allocator, ownership_lease);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "telegram");
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKey(&buf, allocator, "configured");
        try buf.appendSlice(allocator, if (telegram_configured) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "connected");
        if (telegram_state.state.connected) |connected| {
            try buf.appendSlice(allocator, if (connected) "true" else "false");
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "data_source", telegram_state.data_source);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "context_incomplete");
        try buf.appendSlice(allocator, if (telegram_state.context_incomplete) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "account_id");
        if (telegram_state.state.account_id) |account_id| {
            try json_util.appendJsonString(&buf, allocator, account_id);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try appendOptionalInt(&buf, allocator, "chat_id", telegram_state.state.chat_id);
        try buf.appendSlice(allocator, "},");
        try json_util.appendJsonKey(&buf, allocator, "composio");
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKey(&buf, allocator, "enabled");
        try buf.appendSlice(allocator, if (self.config.composio.enabled) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "configured");
        try buf.appendSlice(allocator, if (self.config.composio.enabled and self.config.composio.api_key != null) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "entity_id");
        try json_util.appendJsonString(&buf, allocator, entity_resolution.entity_id);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "entity_scope_source", entity_resolution.source);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "per_user_scope");
        try buf.appendSlice(allocator, if (tenant_ctx.user_id != null) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "connected_accounts_state", composio_readiness.connected_accounts_state);
        try buf.appendSlice(allocator, ",");
        try appendOptionalBool(&buf, allocator, "api_reachable", composio_readiness.api_reachable);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "gmail_toolkit", "gmail");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "google_drive_toolkit", "googledrive");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "google_calendar_toolkit", "googlecalendar");
        try buf.appendSlice(allocator, ",");
        try appendOptionalBool(&buf, allocator, "gmail_toolkit_available", composio_readiness.gmail_toolkit_available);
        try buf.appendSlice(allocator, ",");
        try appendOptionalBool(&buf, allocator, "google_drive_toolkit_available", composio_readiness.google_drive_toolkit_available);
        try buf.appendSlice(allocator, ",");
        try appendOptionalBool(&buf, allocator, "google_calendar_toolkit_available", composio_readiness.google_calendar_toolkit_available);
        try buf.appendSlice(allocator, ",");
        try appendOptionalBool(&buf, allocator, "gmail_connected", composio_readiness.gmail_connected);
        try buf.appendSlice(allocator, ",");
        try appendOptionalBool(&buf, allocator, "google_drive_connected", composio_readiness.google_drive_connected);
        try buf.appendSlice(allocator, ",");
        try appendOptionalBool(&buf, allocator, "google_calendar_connected", composio_readiness.google_calendar_connected);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "auth_flow_requires_user_turn");
        try buf.appendSlice(allocator, "true");
        try buf.appendSlice(allocator, "}");
        try buf.appendSlice(allocator, "}");
        return try buf.toOwnedSlice(allocator);
    }

    fn buildSchedulerJson(self: *RuntimeInfoTool, allocator: std.mem.Allocator, user_id_override: ?[]const u8) ![]u8 {
        const tenant_ctx = root.getTenantContext();
        const effective_backend = root.effectiveStateBackend(self.config, tenant_ctx);
        const scheduler_truth = resolveSchedulerTruth(self.config, tenant_ctx, user_id_override);
        const scheduler_backend = scheduler_truth.toSlice();
        const scoped_user_id = resolveScopedUserId(tenant_ctx, user_id_override);
        const context_incomplete = scheduler_truth == .context_missing;
        var lane_snapshot = try lane_metrics.snapshotBackgroundMainReroutes(allocator);
        defer lane_snapshot.deinit(allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKey(&buf, allocator, "enabled");
        try buf.appendSlice(allocator, if (self.config.scheduler.enabled) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "backend", scheduler_backend);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "tenant_context_attached");
        try buf.appendSlice(allocator, if (!context_incomplete and scoped_user_id != null) "true" else if (tenant_ctx.state_mgr != null and tenant_ctx.numeric_user_id != null) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "scheduler_truth", scheduler_backend);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "scoped_user_id");
        if (scoped_user_id) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "context_incomplete");
        try buf.appendSlice(allocator, if (context_incomplete) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "state_backend_effective", effective_backend);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "max_tasks", self.config.scheduler.max_tasks);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "background_main_reroutes_total", @intCast(lane_snapshot.total));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "background_main_reroutes_last_job_id");
        if (lane_snapshot.last_job_id) |job_id| {
            try json_util.appendJsonString(&buf, allocator, job_id);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, "}");
        return try buf.toOwnedSlice(allocator);
    }

    fn buildHeartbeatJson(self: *RuntimeInfoTool, allocator: std.mem.Allocator, user_id_override: ?[]const u8) ![]u8 {
        const turn_ctx = root.getTurnContext();
        const tenant_ctx = root.getTenantContext();
        const heartbeat_cfg = try readEffectiveHeartbeatConfig(allocator, self.config, tenant_ctx, user_id_override);
        const scheduler_truth = resolveSchedulerTruth(self.config, tenant_ctx, user_id_override).toSlice();

        var runtime_available = false;
        var runtime_last_run_s: ?i64 = null;
        var runtime_last_status: ?[]u8 = null;
        defer if (runtime_last_status) |value| allocator.free(value);
        var runtime_last_reason: ?[]u8 = null;
        defer if (runtime_last_reason) |value| allocator.free(value);

        const user_root = try resolveScopedUserRoot(allocator, self.config, tenant_ctx, user_id_override);
        defer if (user_root) |value| allocator.free(value);
        if (user_root) |root_path| {
            const path = std.fmt.allocPrint(allocator, "{s}/heartbeat_runtime.json", .{root_path}) catch null;
            if (path) |runtime_path| {
                defer allocator.free(runtime_path);
                const file = std.fs.openFileAbsolute(runtime_path, .{}) catch null;
                if (file) |f| {
                    defer f.close();
                    const raw = f.readToEndAlloc(allocator, 64 * 1024) catch null;
                    if (raw) |body| {
                        defer allocator.free(body);
                        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
                        if (parsed) |p| {
                            defer p.deinit();
                            if (p.value == .object) {
                                runtime_available = true;
                                if (p.value.object.get("last_run_s")) |v| {
                                    if (v == .integer) runtime_last_run_s = v.integer;
                                }
                                if (p.value.object.get("last_status")) |v| {
                                    if (v == .string) runtime_last_status = allocator.dupe(u8, v.string) catch null;
                                }
                                if (p.value.object.get("last_reason")) |v| {
                                    if (v == .string) runtime_last_reason = allocator.dupe(u8, v.string) catch null;
                                }
                            }
                        }
                    }
                }
            }
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKey(&buf, allocator, "enabled");
        try buf.appendSlice(allocator, if (heartbeat_cfg.enabled) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "interval_minutes", heartbeat_cfg.interval_minutes);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "data_source", heartbeat_cfg.data_source);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "scheduler_truth", scheduler_truth);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "context_incomplete");
        try buf.appendSlice(allocator, if (heartbeat_cfg.context_incomplete) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "current_turn_origin", turn_ctx.origin.toSlice());
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "runtime_available");
        try buf.appendSlice(allocator, if (runtime_available) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "runtime_last_run_s");
        if (runtime_last_run_s) |value| {
            var int_buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch "0";
            try buf.appendSlice(allocator, text);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "runtime_last_status");
        if (runtime_last_status) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "runtime_last_reason");
        if (runtime_last_reason) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, "}");
        return try buf.toOwnedSlice(allocator);
    }

    fn buildExecutionTruthJson(self: *RuntimeInfoTool, allocator: std.mem.Allocator, user_id_override: ?[]const u8) ![]u8 {
        const tenant_ctx = root.getTenantContext();
        const turn_ctx = root.getTurnContext();
        const scoped_user_id = resolveScopedUserId(tenant_ctx, user_id_override);
        var snapshot = try runtime_truth.collectRuntimeSnapshot(allocator, self.config, scoped_user_id);
        defer snapshot.deinit(allocator);
        var task_focus = try runtime_truth.collectExecutionTaskFocus(
            allocator,
            self.config,
            tenant_ctx.state_mgr,
            resolveScopedNumericUserId(tenant_ctx, user_id_override),
            scoped_user_id,
            turn_ctx.session_key,
        );
        defer task_focus.deinit(allocator);
        const surfaced_session_key = task_focus.task_session_key orelse turn_ctx.session_key;
        const task_snapshot_ptr: ?*const @import("../zaki_state.zig").TaskSnapshot = if (task_focus.task_snapshot) |*value| value else null;
        var truth = try runtime_truth.deriveExecutionTruth(
            allocator,
            &snapshot,
            task_snapshot_ptr,
            surfaced_session_key,
            scoped_user_id,
        );
        defer truth.deinit(allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKeyValue(&buf, allocator, "task", truth.task);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "task_key");
        if (truth.task_key) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "current_session_key");
        if (turn_ctx.session_key) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "selection_rule", task_focus.selection_rule);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "owner", truth.owner);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "owner_source", truth.owner_source);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "status", truth.status);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "result", truth.result);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "failure", truth.failure);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "degraded");
        try buf.appendSlice(allocator, if (truth.degraded) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "degraded_reason", truth.degraded_reason);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "fallback_active");
        try buf.appendSlice(allocator, if (truth.fallback_active) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "fallback_reason", truth.fallback_reason);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "fallback_chain", truth.fallback_chain);
        try buf.appendSlice(allocator, "}");
        return try buf.toOwnedSlice(allocator);
    }

    fn buildOpsJson(self: *RuntimeInfoTool, allocator: std.mem.Allocator) ![]u8 {
        const tenant_ctx = root.getTenantContext();
        const turn_ctx = root.getTurnContext();
        const degraded_reason = root.degradedReason(self.config, tenant_ctx);
        const ops_json = try ops_guard.diagnosticsJson(allocator);
        defer allocator.free(ops_json);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKeyValue(&buf, allocator, "turn_origin", turn_ctx.origin.toSlice());
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "workspace_dir", self.config.workspace_dir);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "state_backend_effective", root.effectiveStateBackend(self.config, tenant_ctx));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "degraded");
        try buf.appendSlice(allocator, if (degraded_reason.len > 0) "true" else "false");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "degraded_reason", degraded_reason);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "proactive_guard");
        try buf.appendSlice(allocator, ops_json);
        try buf.appendSlice(allocator, "}");
        return try buf.toOwnedSlice(allocator);
    }

    fn resolveComposioReadiness(self: *RuntimeInfoTool, allocator: std.mem.Allocator, entity_id: []const u8) ComposioReadiness {
        var readiness = ComposioReadiness{};

        if (!self.config.composio.enabled) {
            readiness.connected_accounts_state = "disabled";
            return readiness;
        }

        const api_key = self.config.composio.api_key orelse {
            readiness.connected_accounts_state = "not_configured";
            return readiness;
        };

        readiness.gmail_toolkit_available = queryToolkitAvailability(allocator, api_key, "gmail");
        readiness.google_drive_toolkit_available = queryToolkitAvailability(allocator, api_key, "googledrive");
        readiness.google_calendar_toolkit_available = queryToolkitAvailability(allocator, api_key, "googlecalendar");

        const any_toolkit_probe = readiness.gmail_toolkit_available != null or
            readiness.google_drive_toolkit_available != null or
            readiness.google_calendar_toolkit_available != null;

        if (queryConnectedAccounts(allocator, api_key, entity_id)) |connected| {
            readiness.gmail_connected = connected.gmail_connected;
            readiness.google_drive_connected = connected.google_drive_connected;
            readiness.google_calendar_connected = connected.google_calendar_connected;

            readiness.api_reachable = true;
            const any_connected = connected.gmail_connected or connected.google_drive_connected or connected.google_calendar_connected;
            readiness.connected_accounts_state = if (any_connected) "connected" else "not_connected";
            return readiness;
        }

        if (any_toolkit_probe) {
            readiness.api_reachable = true;
            readiness.connected_accounts_state = "unverified";
        } else {
            readiness.api_reachable = false;
            readiness.connected_accounts_state = "api_unreachable";
        }

        return readiness;
    }
};

const TelegramState = struct {
    connected: ?bool = null,
    account_id: ?[]u8 = null,
    chat_id: ?i64 = null,

    fn deinit(self: *TelegramState, allocator: std.mem.Allocator) void {
        if (self.account_id) |account_id| allocator.free(account_id);
    }
};

const TelegramStateSnapshot = struct {
    state: TelegramState = .{},
    data_source: []const u8 = "unknown",
    context_incomplete: bool = false,

    fn deinit(self: *TelegramStateSnapshot, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
    }
};

const OwnershipLeaseSnapshot = struct {
    data_source: []const u8 = "unavailable",
    context_incomplete: bool = false,
    owner_id: ?[]u8 = null,
    lease_until_s: ?i64 = null,
    updated_at_s: ?i64 = null,

    fn deinit(self: *OwnershipLeaseSnapshot, allocator: std.mem.Allocator) void {
        if (self.owner_id) |owner_id| allocator.free(owner_id);
    }
};

const SchedulerTruth = enum {
    postgres,
    context_missing,
    file,

    fn toSlice(self: @This()) []const u8 {
        return switch (self) {
            .postgres => "postgres",
            .context_missing => "context_missing",
            .file => "file",
        };
    }
};

fn resolveSchedulerTruth(
    config: *const config_mod.Config,
    tenant_ctx: root.ToolTenantContext,
    user_id_override: ?[]const u8,
) SchedulerTruth {
    const scoped_numeric_user_id = resolveScopedNumericUserId(tenant_ctx, user_id_override);
    if (tenant_ctx.state_mgr != null and scoped_numeric_user_id != null) return .postgres;

    const tenant_scope_requested = config.tenant.enabled and std.mem.eql(u8, config.state.backend, "postgres") and
        (tenant_ctx.expect_postgres_state or resolveScopedUserId(tenant_ctx, user_id_override) != null);
    if (tenant_scope_requested) return .context_missing;
    return .file;
}

fn runtimeDataSourceLabel(
    config: *const config_mod.Config,
    tenant_ctx: root.ToolTenantContext,
    user_id_override: ?[]const u8,
) []const u8 {
    return resolveSchedulerTruth(config, tenant_ctx, user_id_override).toSlice();
}

fn normalizeProviderAlias(provider_name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, provider_name, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "together-ai")) return "together";
    if (std.mem.eql(u8, trimmed, "google-gemini")) return "gemini";
    return trimmed;
}

fn allocNormalizedFallbackChain(allocator: std.mem.Allocator, providers: []const []const u8) ![]u8 {
    if (providers.len == 0) return allocator.dupe(u8, "none");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var wrote_any = false;
    for (providers) |provider_name| {
        const normalized = normalizeProviderAlias(provider_name);
        if (normalized.len == 0) continue;
        if (wrote_any) try out.append(allocator, ',');
        try out.appendSlice(allocator, normalized);
        wrote_any = true;
    }
    if (!wrote_any) return allocator.dupe(u8, "none");
    return out.toOwnedSlice(allocator);
}

fn resolveScopedNumericUserId(tenant_ctx: root.ToolTenantContext, user_id_override: ?[]const u8) ?i64 {
    if (user_id_override) |user_id| {
        const trimmed = std.mem.trim(u8, user_id, " \t\r\n");
        if (trimmed.len == 0) return null;
        return std.fmt.parseInt(i64, trimmed, 10) catch null;
    }
    return tenant_ctx.numeric_user_id;
}

fn readOwnershipLeaseState(
    allocator: std.mem.Allocator,
    tenant_ctx: root.ToolTenantContext,
    user_id_override: ?[]const u8,
) !OwnershipLeaseSnapshot {
    const scoped_numeric_user_id = resolveScopedNumericUserId(tenant_ctx, user_id_override);
    if (tenant_ctx.state_mgr) |state_mgr| {
        if (scoped_numeric_user_id) |numeric_user_id| {
            var snapshot = OwnershipLeaseSnapshot{ .data_source = "postgres_lease" };
            if (try state_mgr.getUserOwnershipLeaseSnapshot(allocator, numeric_user_id)) |lease_snapshot| {
                snapshot.owner_id = lease_snapshot.owner_id;
                snapshot.lease_until_s = lease_snapshot.lease_until_s;
                snapshot.updated_at_s = lease_snapshot.updated_at_s;
            }
            return snapshot;
        }
    }
    if (tenant_ctx.expect_postgres_state) {
        return .{
            .data_source = "context_missing",
            .context_incomplete = true,
        };
    }
    return .{
        .data_source = "unavailable",
    };
}

fn resolveComposioEntity(config: *const config_mod.Config, tenant_ctx: root.ToolTenantContext, user_id_override: ?[]const u8) ComposioEntityResolution {
    if (user_id_override) |user_id| {
        const trimmed = std.mem.trim(u8, user_id, " \t\r\n");
        if (trimmed.len > 0) return .{ .entity_id = trimmed, .source = "user_id_override" };
    }
    if (tenant_ctx.user_id) |user_id| {
        const trimmed = std.mem.trim(u8, user_id, " \t\r\n");
        if (trimmed.len > 0) return .{ .entity_id = trimmed, .source = "tenant_context" };
    }
    return .{ .entity_id = config.composio.entity_id, .source = "config_default" };
}

fn normalizeComposioToolkitSlug(name: []const u8) []const u8 {
    return std.mem.trim(u8, name, " \t\r\n");
}

fn queryEscapeComponent(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |ch| {
        const is_unreserved = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (is_unreserved) {
            try out.append(allocator, ch);
            continue;
        }
        var encoded: [3]u8 = undefined;
        _ = std.fmt.bufPrint(&encoded, "%{X:0>2}", .{@as(u8, ch)}) catch unreachable;
        try out.appendSlice(allocator, &encoded);
    }

    return try out.toOwnedSlice(allocator);
}

fn readArrayField(value: std.json.Value, field: []const u8) ?[]const std.json.Value {
    if (value != .object) return null;
    if (value.object.get(field)) |field_value| {
        if (field_value == .array) return field_value.array.items;
    }
    return null;
}

fn firstStringField(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (obj.get(key)) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return null;
}

fn boolFromField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |value| {
        return switch (value) {
            .bool => value.bool,
            .string => |s| blk: {
                if (std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "connected") or std.ascii.eqlIgnoreCase(s, "active")) break :blk true;
                if (std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "disconnected") or std.ascii.eqlIgnoreCase(s, "inactive")) break :blk false;
                break :blk null;
            },
            else => null,
        };
    }
    return null;
}

fn stringImpliesConnected(status: []const u8) ?bool {
    if (status.len == 0) return null;
    if (std.mem.indexOf(u8, status, "connected") != null) return true;
    if (std.mem.indexOf(u8, status, "active") != null) return true;
    if (std.mem.indexOf(u8, status, "authorized") != null) return true;
    if (std.mem.indexOf(u8, status, "linked") != null) return true;
    if (std.mem.indexOf(u8, status, "enabled") != null) return true;
    if (std.mem.indexOf(u8, status, "disconnected") != null) return false;
    if (std.mem.indexOf(u8, status, "revoked") != null) return false;
    if (std.mem.indexOf(u8, status, "expired") != null) return false;
    if (std.mem.indexOf(u8, status, "error") != null) return false;
    return null;
}

fn detectAppFamily(value: []const u8) enum { gmail, drive, calendar, other } {
    var lower_buf: [128]u8 = undefined;
    const n = @min(value.len, lower_buf.len);
    _ = std.ascii.lowerString(lower_buf[0..n], value[0..n]);
    const lower = lower_buf[0..n];
    if (std.mem.indexOf(u8, lower, "gmail") != null) return .gmail;
    if (std.mem.indexOf(u8, lower, "drive") != null) return .drive;
    if (std.mem.indexOf(u8, lower, "calendar") != null) return .calendar;
    return .other;
}

fn composioCurlGet(allocator: std.mem.Allocator, api_key: []const u8, url: []const u8) ?[]u8 {
    const auth_header = std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key}) catch return null;
    defer allocator.free(auth_header);

    const argv = [_][]const u8{
        "curl",
        "-sL",
        "-m",
        "6",
        "-H",
        auth_header,
        "-H",
        "Accept: application/json",
        url,
    };

    const result = process_util.run(allocator, &argv, .{ .max_output_bytes = 256 * 1024 }) catch return null;
    defer allocator.free(result.stderr);
    if (!result.success) {
        allocator.free(result.stdout);
        return null;
    }
    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn parseToolkitAvailability(raw: []const u8, allocator: std.mem.Allocator) ?bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    const root_value = parsed.value;

    if (root_value == .array) return root_value.array.items.len > 0;
    if (root_value != .object) return null;

    if (readArrayField(root_value, "items")) |items| return items.len > 0;
    if (readArrayField(root_value, "data")) |items| return items.len > 0;
    if (readArrayField(root_value, "results")) |items| return items.len > 0;
    if (readArrayField(root_value, "tools")) |items| return items.len > 0;

    if (root_value.object.get("total")) |total| {
        return switch (total) {
            .integer => total.integer > 0,
            .float => total.float > 0.0,
            .string => (std.fmt.parseInt(i64, total.string, 10) catch 0) > 0,
            else => null,
        };
    }

    return null;
}

fn queryToolkitAvailability(allocator: std.mem.Allocator, api_key: []const u8, toolkit_slug: []const u8) ?bool {
    const slug = normalizeComposioToolkitSlug(toolkit_slug);
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V3 ++ "/tools?toolkit_slug={s}&page=1&page_size=1", .{slug}) catch return null;
    const raw = composioCurlGet(allocator, api_key, url) orelse return null;
    defer allocator.free(raw);
    return parseToolkitAvailability(raw, allocator);
}

fn parseConnectedAccounts(raw: []const u8, allocator: std.mem.Allocator) ?ConnectedAccountsStatus {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();

    const root_value = parsed.value;
    const accounts: []const std.json.Value = blk: {
        if (root_value == .array) break :blk root_value.array.items;
        if (root_value != .object) return null;
        if (readArrayField(root_value, "items")) |items| break :blk items;
        if (readArrayField(root_value, "data")) |items| break :blk items;
        if (readArrayField(root_value, "results")) |items| break :blk items;
        if (readArrayField(root_value, "connectedAccounts")) |items| break :blk items;
        if (readArrayField(root_value, "connected_accounts")) |items| break :blk items;
        if (readArrayField(root_value, "accounts")) |items| break :blk items;
        return null;
    };

    var status = ConnectedAccountsStatus{};
    for (accounts) |item| {
        if (item != .object) continue;
        const app_name = firstStringField(item.object, &.{
            "toolkit_slug",
            "toolkitSlug",
            "appName",
            "app_name",
            "app",
            "integration",
            "name",
        }) orelse continue;

        const connected = blk: {
            if (boolFromField(item.object, "connected")) |v| break :blk v;
            if (boolFromField(item.object, "is_connected")) |v| break :blk v;
            const status_str = firstStringField(item.object, &.{ "status", "connection_status", "connectionStatus" });
            if (status_str) |s| {
                var lower_buf: [64]u8 = undefined;
                const n = @min(s.len, lower_buf.len);
                _ = std.ascii.lowerString(lower_buf[0..n], s[0..n]);
                if (stringImpliesConnected(lower_buf[0..n])) |v| break :blk v;
            }
            break :blk true;
        };

        switch (detectAppFamily(app_name)) {
            .gmail => status.gmail_connected = status.gmail_connected or connected,
            .drive => status.google_drive_connected = status.google_drive_connected or connected,
            .calendar => status.google_calendar_connected = status.google_calendar_connected or connected,
            .other => {},
        }
    }

    return status;
}

fn queryConnectedAccounts(allocator: std.mem.Allocator, api_key: []const u8, entity_id: []const u8) ?ConnectedAccountsStatus {
    const escaped = queryEscapeComponent(allocator, entity_id) catch return null;
    defer allocator.free(escaped);

    var url_buf: [768]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V1 ++ "/connectedAccounts?entity_id={s}", .{escaped}) catch return null;
    const raw = composioCurlGet(allocator, api_key, url) orelse return null;
    defer allocator.free(raw);
    return parseConnectedAccounts(raw, allocator);
}

fn appendStringArray(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, values: []const []const u8) !void {
    try buf.appendSlice(allocator, "[");
    for (values, 0..) |value, i| {
        if (i != 0) try buf.appendSlice(allocator, ",");
        try json_util.appendJsonString(buf, allocator, value);
    }
    try buf.appendSlice(allocator, "]");
}

fn appendToolNames(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, tools: ?[]const Tool) !void {
    try buf.appendSlice(allocator, "[");
    if (tools) |runtime_tools| {
        for (runtime_tools, 0..) |tool, i| {
            if (i != 0) try buf.appendSlice(allocator, ",");
            try json_util.appendJsonString(buf, allocator, tool.name());
        }
    }
    try buf.appendSlice(allocator, "]");
}

fn appendDeferredControls(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, config: *const config_mod.Config) !void {
    try buf.appendSlice(allocator, "[");
    const parsed = tool_dispatcher.parseMode(config.agent.tool_dispatcher);
    if (!parsed.supported) {
        const label = try std.fmt.allocPrint(allocator, "agent.tool_dispatcher={s}(unsupported_fallback:auto)", .{
            config.agent.tool_dispatcher,
        });
        defer allocator.free(label);
        try json_util.appendJsonString(buf, allocator, label);
    }
    try buf.appendSlice(allocator, "]");
}

fn appendIdentityMapping(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
) !void {
    const metrics = inbound_canonicalizer.metricsSnapshot();
    try json_util.appendJsonKey(buf, allocator, "identity_mapping");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(buf, allocator, "mapped", @intCast(metrics.mapped));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "unmapped", @intCast(metrics.unmapped));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "strict_rejected", @intCast(metrics.strict_rejected));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "degraded_compat", @intCast(metrics.degraded_compat));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "cache_hit", @intCast(metrics.cache_hit));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "cache_miss", @intCast(metrics.cache_miss));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "cache_stale", @intCast(metrics.cache_stale));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "db_lookup_count", @intCast(metrics.db_lookup_count));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "db_lookup_ms_total", @intCast(metrics.db_lookup_ms_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(buf, allocator, "enforcement", config.tenant.identity_mapping_enforcement);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "strict_channels");
    try appendStringArray(buf, allocator, config.tenant.identity_mapping_strict_channels);
    try buf.appendSlice(allocator, "}");
}

fn appendSttMetrics(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    const stt = voice.telegramSttMetricsSnapshot();
    try json_util.appendJsonKey(buf, allocator, "stt");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(buf, allocator, "transcriber_configured", @intCast(stt.transcriber_configured));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "transcription_attempted", @intCast(stt.transcription_attempted));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "transcription_succeeded", @intCast(stt.transcription_succeeded));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "transcription_failed", @intCast(stt.transcription_failed));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "transcription_skipped_no_transcriber", @intCast(stt.transcription_skipped_no_transcriber));
    try buf.appendSlice(allocator, "}");
}

fn appendMultimodalMetrics(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    const image_metrics = multimodal.imageFlowMetricsSnapshot();
    try json_util.appendJsonKey(buf, allocator, "multimodal");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(buf, allocator, "image_markers_detected", @intCast(image_metrics.image_markers_detected));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "messages_with_image_markers", @intCast(image_metrics.messages_with_image_markers));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "image_parts_prepared", @intCast(image_metrics.image_parts_prepared));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "image_parts_failed", @intCast(image_metrics.image_parts_failed));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "image_markers_ignored", @intCast(image_metrics.image_markers_ignored));
    try buf.appendSlice(allocator, "}");
}

fn appendOwnershipLease(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    snapshot: OwnershipLeaseSnapshot,
) !void {
    try json_util.appendJsonKey(buf, allocator, "ownership_lease");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKeyValue(buf, allocator, "data_source", snapshot.data_source);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "context_incomplete");
    try buf.appendSlice(allocator, if (snapshot.context_incomplete) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "owner_id");
    if (snapshot.owner_id) |owner_id| {
        try json_util.appendJsonString(buf, allocator, owner_id);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try appendOptionalInt(buf, allocator, "lease_until_s", snapshot.lease_until_s);
    try buf.appendSlice(allocator, ",");
    try appendOptionalInt(buf, allocator, "updated_at_s", snapshot.updated_at_s);
    try buf.appendSlice(allocator, "}");
}

fn appendOptionalInt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: ?i64) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    if (value) |resolved| {
        var number_buf: [24]u8 = undefined;
        const rendered = std.fmt.bufPrint(&number_buf, "{d}", .{resolved}) catch unreachable;
        try buf.appendSlice(allocator, rendered);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendOptionalBool(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: ?bool) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    if (value) |resolved| {
        try buf.appendSlice(allocator, if (resolved) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn deriveUserRoot(workspace_dir: []const u8) []const u8 {
    return std.fs.path.dirname(workspace_dir) orelse workspace_dir;
}

const EffectiveHeartbeatConfig = struct {
    enabled: bool,
    interval_minutes: u32,
    data_source: []const u8,
    context_incomplete: bool = false,
};

fn parseHeartbeatSecondsToMinutes(value: i64) ?u32 {
    if (value <= 0) return null;
    const mins_i64 = @max(@as(i64, 1), @divFloor(value + 59, 60));
    const clamped = @min(mins_i64, @as(i64, std.math.maxInt(u32)));
    return @intCast(clamped);
}

fn applyHeartbeatConfigObject(enabled: *bool, interval_minutes: *u32, object: std.json.ObjectMap) void {
    if (object.get("enabled")) |value| {
        if (value == .bool) enabled.* = value.bool;
    }
    if (object.get("interval_minutes")) |value| {
        if (value == .integer and value.integer > 0) {
            const clamped = @min(value.integer, @as(i64, std.math.maxInt(u32)));
            interval_minutes.* = @intCast(clamped);
        }
    }
    inline for ([_][]const u8{ "intervalSec", "interval_seconds", "interval_sec" }) |field| {
        if (object.get(field)) |value| {
            if (value == .integer) {
                if (parseHeartbeatSecondsToMinutes(value.integer)) |mins| interval_minutes.* = mins;
            }
        }
    }
}

fn parseHeartbeatConfigJson(raw: []const u8, default_enabled: bool, default_interval_minutes: u32) !EffectiveHeartbeatConfig {
    var result = EffectiveHeartbeatConfig{
        .enabled = default_enabled,
        .interval_minutes = @max(@as(u32, 1), default_interval_minutes),
        .data_source = "config",
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}")) return result;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return result;

    applyHeartbeatConfigObject(&result.enabled, &result.interval_minutes, parsed.value.object);
    if (parsed.value.object.get("heartbeat")) |nested| {
        if (nested == .object) {
            applyHeartbeatConfigObject(&result.enabled, &result.interval_minutes, nested.object);
        }
    }
    return result;
}

fn resolveScopedUserId(tenant_ctx: root.ToolTenantContext, user_id_override: ?[]const u8) ?[]const u8 {
    if (user_id_override) |user_id| {
        const trimmed = std.mem.trim(u8, user_id, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return tenant_ctx.user_id;
}

fn resolveScopedUserRoot(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    tenant_ctx: root.ToolTenantContext,
    user_id_override: ?[]const u8,
) !?[]u8 {
    const scoped_user_id = resolveScopedUserId(tenant_ctx, user_id_override) orelse return null;
    if (config.tenant.data_root.len > 0) {
        const user_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tenant.data_root, scoped_user_id });
        return user_root;
    }
    const user_root = try allocator.dupe(u8, deriveUserRoot(config.workspace_dir));
    return user_root;
}

fn readEffectiveHeartbeatConfig(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    tenant_ctx: root.ToolTenantContext,
    user_id_override: ?[]const u8,
) !EffectiveHeartbeatConfig {
    const defaults = EffectiveHeartbeatConfig{
        .enabled = config.heartbeat.enabled,
        .interval_minutes = @max(@as(u32, 1), config.heartbeat.interval_minutes),
        .data_source = "config",
    };
    if (tenant_ctx.state_mgr) |state_mgr| {
        if (resolveScopedNumericUserId(tenant_ctx, user_id_override)) |numeric_user_id| {
            const raw = state_mgr.getHeartbeatJson(allocator, numeric_user_id) catch return EffectiveHeartbeatConfig{
                .enabled = defaults.enabled,
                .interval_minutes = defaults.interval_minutes,
                .data_source = "postgres",
            };
            defer allocator.free(raw);
            var parsed = try parseHeartbeatConfigJson(raw, defaults.enabled, defaults.interval_minutes);
            parsed.data_source = "postgres";
            return parsed;
        }
    }
    if (resolveSchedulerTruth(config, tenant_ctx, user_id_override) == .context_missing) {
        return .{
            .enabled = defaults.enabled,
            .interval_minutes = defaults.interval_minutes,
            .data_source = "context_missing",
            .context_incomplete = true,
        };
    }

    const user_root = try resolveScopedUserRoot(allocator, config, tenant_ctx, user_id_override);
    defer if (user_root) |value| allocator.free(value);
    if (user_root) |root_path| {
        const path = try std.fmt.allocPrint(allocator, "{s}/heartbeat.json", .{root_path});
        defer allocator.free(path);
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            return .{
                .enabled = defaults.enabled,
                .interval_minutes = defaults.interval_minutes,
                .data_source = "config",
            };
        };
        defer file.close();
        const raw = file.readToEndAlloc(allocator, 128 * 1024) catch {
            return .{
                .enabled = defaults.enabled,
                .interval_minutes = defaults.interval_minutes,
                .data_source = "config",
            };
        };
        defer allocator.free(raw);
        var parsed = try parseHeartbeatConfigJson(raw, defaults.enabled, defaults.interval_minutes);
        parsed.data_source = "file";
        return parsed;
    }

    return defaults;
}

fn readTelegramState(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    tenant_ctx: root.ToolTenantContext,
    user_id_override: ?[]const u8,
) !TelegramStateSnapshot {
    const scoped_numeric_user_id = resolveScopedNumericUserId(tenant_ctx, user_id_override);
    if (tenant_ctx.state_mgr) |state_mgr| {
        if (scoped_numeric_user_id) |numeric_user_id| {
            const raw = state_mgr.getTelegramStateJson(allocator, numeric_user_id) catch return .{ .data_source = "postgres" };
            defer allocator.free(raw);
            return .{
                .state = try parseTelegramStateJson(allocator, raw),
                .data_source = "postgres",
            };
        }
    }
    if (tenant_ctx.expect_postgres_state) {
        return .{
            .data_source = "context_missing",
            .context_incomplete = true,
        };
    }

    if (user_id_override) |user_id| {
        if (tenant_ctx.user_id) |ctx_user_id| {
            if (!std.mem.eql(u8, user_id, ctx_user_id)) {
                return .{
                    .data_source = "context_missing",
                    .context_incomplete = true,
                };
            }
        }
    }

    const user_root = try resolveScopedUserRoot(allocator, config, tenant_ctx, user_id_override);
    defer if (user_root) |value| allocator.free(value);
    const root_path = user_root orelse return .{ .data_source = "file_fallback" };
    const path = try std.fmt.allocPrint(allocator, "{s}/channel_state.json", .{root_path});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return .{ .data_source = "file_fallback" };
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(raw);
    return .{
        .state = try parseTelegramStateJson(allocator, raw),
        .data_source = "file_fallback",
    };
}

fn parseTelegramStateJson(allocator: std.mem.Allocator, raw: []const u8) !TelegramState {
    var state = TelegramState{};
    errdefer state.deinit(allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const telegram_obj = blk: {
        if (parsed.value.object.get("telegram")) |telegram_value| {
            if (telegram_value == .object) break :blk telegram_value.object;
        }
        // Postgres-backed telegram state is stored as top-level object fields.
        // File fallback (channel_state.json) stores telegram under a nested key.
        break :blk parsed.value.object;
    };

    if (telegram_obj.get("connected")) |connected_value| {
        if (connected_value == .bool) state.connected = connected_value.bool;
    }
    if (telegram_obj.get("account_id")) |account_value| {
        if (account_value == .string and account_value.string.len > 0) {
            state.account_id = try allocator.dupe(u8, account_value.string);
        }
    }
    if (telegram_obj.get("chat_id")) |chat_id_value| {
        state.chat_id = switch (chat_id_value) {
            .integer => chat_id_value.integer,
            .string => std.fmt.parseInt(i64, chat_id_value.string, 10) catch null,
            else => null,
        };
    }
    return state;
}

fn hasTelegramRuntimeState(state: TelegramState) bool {
    return state.connected != null or state.account_id != null or state.chat_id != null;
}

fn isTelegramConfigured(config: *const config_mod.Config, state: TelegramState) bool {
    return config.channels.telegram.len > 0 or hasTelegramRuntimeState(state);
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn writeTestFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

test "runtime info tool name" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    try std.testing.expectEqualStrings("runtime_info", t.name());
}

test "runtime info summary includes state backend keys" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:test",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer root.clearTurnContext();
    const parsed = try root.parseTestArgs("{\"section\":\"summary\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"state_backend_configured\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"enabled_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"data_source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"context_incomplete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"chat_provider_effective\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"chat_fallback_chain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"embedding_provider_effective\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"provider_data_source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deferred_controls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"identity_mapping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"multimodal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ownership_lease\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"parallel_tools_rollout_percent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"entity_scope_source\":\"config_default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"telegram_dm_same_user_main\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"telegram_group_session_policy\":\"thread\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"session_idle_evict_on_request_path\":false") != null);
}

test "runtime info session surfaces canonical same-user lane truth" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();

    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:zaki-bot:user:7:main",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer root.clearTurnContext();
    root.setTenantContext(.{
        .user_id = "7",
        .numeric_user_id = 7,
    });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"section\":\"session\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"session_lane\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"canonical_user_id\":\"7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"same_user_truth\":true") != null);
}

test "runtime info parseToolkitAvailability supports object items" {
    const raw =
        \\{"items":[{"slug":"gmail-send"}],"page":1}
    ;
    const avail = parseToolkitAvailability(raw, std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, true), avail);
}

test "runtime info parseToolkitAvailability supports total" {
    const raw =
        \\{"total":0}
    ;
    const avail = parseToolkitAvailability(raw, std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, false), avail);
}

test "runtime info parseConnectedAccounts maps gmail drive calendar" {
    const raw =
        \\[
        \\  {"toolkit_slug":"gmail","status":"connected"},
        \\  {"appName":"googledrive","status":"active"},
        \\  {"app":"googlecalendar","status":"connected"}
        \\]
    ;
    const status = parseConnectedAccounts(raw, std.testing.allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expect(status.gmail_connected);
    try std.testing.expect(status.google_drive_connected);
    try std.testing.expect(status.google_calendar_connected);
}

test "runtime info telegram configured uses runtime state fallback" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    const empty_state = TelegramState{};
    try std.testing.expect(!isTelegramConfigured(&cfg, empty_state));

    const connected_state = TelegramState{ .connected = true };
    try std.testing.expect(isTelegramConfigured(&cfg, connected_state));
}

test "runtime info telegram snapshot marks context missing for expected postgres state" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    const snapshot = try readTelegramState(std.testing.allocator, &cfg, .{
        .user_id = "7",
        .expect_postgres_state = true,
    }, null);
    var snapshot_mut = snapshot;
    defer snapshot_mut.deinit(std.testing.allocator);
    try std.testing.expect(snapshot.context_incomplete);
    try std.testing.expectEqualStrings("context_missing", snapshot.data_source);
}

test "runtime info integrations composio entity scope uses override and tenant context" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.composio.enabled = true;
    cfg.composio.entity_id = "default-entity";

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();

    root.setTenantContext(.{ .user_id = "42" });
    defer root.clearTenantContext();

    const parsed_tenant = try root.parseTestArgs("{\"section\":\"integrations\"}");
    defer parsed_tenant.deinit();
    const tenant_result = try t.execute(std.testing.allocator, parsed_tenant.value.object);
    defer std.testing.allocator.free(tenant_result.output);
    try std.testing.expect(tenant_result.success);
    try std.testing.expect(std.mem.indexOf(u8, tenant_result.output, "\"entity_id\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tenant_result.output, "\"entity_scope_source\":\"tenant_context\"") != null);

    const parsed_override = try root.parseTestArgs("{\"section\":\"integrations\",\"user_id\":\"7\"}");
    defer parsed_override.deinit();
    const override_result = try t.execute(std.testing.allocator, parsed_override.value.object);
    defer std.testing.allocator.free(override_result.output);
    try std.testing.expect(override_result.success);
    try std.testing.expect(std.mem.indexOf(u8, override_result.output, "\"entity_id\":\"7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, override_result.output, "\"entity_scope_source\":\"user_id_override\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, override_result.output, "\"identity_mapping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, override_result.output, "\"multimodal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, override_result.output, "\"ownership_lease\"") != null);
}

test "runtime info summary surfaces active dispatcher state" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.agent.parallel_tools = true;
    cfg.agent.parallel_tools_rollout_percent = 40;
    cfg.agent.tool_dispatcher = "parallel";
    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:test",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer root.clearTurnContext();
    const parsed = try root.parseTestArgs("{\"section\":\"summary\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"parallel_tools\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"parallel_tools_rollout_percent\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"tool_dispatcher_effective\":\"parallel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deferred_controls\":[]") != null);
}

test "runtime info summary surfaces unsupported dispatcher as deferred-explicit" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.agent.parallel_tools = true;
    cfg.agent.tool_dispatcher = "xml";
    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    const parsed = try root.parseTestArgs("{\"section\":\"summary\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"tool_dispatcher_supported\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unsupported_fallback:auto") != null);
}

test "runtime info telegram snapshot treats invalid override as context missing in postgres mode" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    const snapshot = try readTelegramState(std.testing.allocator, &cfg, .{
        .user_id = "7",
        .numeric_user_id = 7,
        .expect_postgres_state = true,
    }, "invalid-user-id");
    var snapshot_mut = snapshot;
    defer snapshot_mut.deinit(std.testing.allocator);
    try std.testing.expect(snapshot.context_incomplete);
    try std.testing.expectEqualStrings("context_missing", snapshot.data_source);
}

test "runtime info telegram snapshot reads fallback file from scoped tenant root override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const users_root = try std.fs.path.join(std.testing.allocator, &.{ base, "users" });
    defer std.testing.allocator.free(users_root);
    try std.fs.makeDirAbsolute(users_root);

    const user_root = try std.fs.path.join(std.testing.allocator, &.{ users_root, "7" });
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    const channel_state_path = try std.fs.path.join(std.testing.allocator, &.{ user_root, "channel_state.json" });
    defer std.testing.allocator.free(channel_state_path);
    try writeTestFile(channel_state_path, "{\"telegram\":{\"connected\":true,\"account_id\":\"main\",\"chat_id\":1110331014}}\n");

    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.data_root = users_root;

    const snapshot = try readTelegramState(std.testing.allocator, &cfg, .{}, "7");
    var snapshot_mut = snapshot;
    defer snapshot_mut.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("file_fallback", snapshot.data_source);
    try std.testing.expectEqual(@as(?bool, true), snapshot.state.connected);
    try std.testing.expectEqualStrings("main", snapshot.state.account_id.?);
    try std.testing.expectEqual(@as(?i64, 1110331014), snapshot.state.chat_id);
}

test "runtime info heartbeat reads effective tenant heartbeat file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const users_root = try std.fs.path.join(std.testing.allocator, &.{ base, "users" });
    defer std.testing.allocator.free(users_root);
    try std.fs.makeDirAbsolute(users_root);

    const user_root = try std.fs.path.join(std.testing.allocator, &.{ users_root, "1" });
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    const workspace = try std.fs.path.join(std.testing.allocator, &.{ user_root, "workspace" });
    defer std.testing.allocator.free(workspace);
    try std.fs.makeDirAbsolute(workspace);

    const heartbeat_path = try std.fs.path.join(std.testing.allocator, &.{ user_root, "heartbeat.json" });
    defer std.testing.allocator.free(heartbeat_path);
    try writeTestFile(heartbeat_path, "{\"enabled\":true,\"intervalSec\":300}\n");

    var cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.tenant.data_root = users_root;
    cfg.heartbeat.enabled = false;
    cfg.heartbeat.interval_minutes = 60;

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTenantContext(.{ .user_id = "1", .numeric_user_id = 1 });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"section\":\"heartbeat\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"interval_minutes\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"data_source\":\"file\"") != null);
}

test "runtime info scheduler reports context missing for tenant postgres scope without state manager" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTenantContext(.{
        .user_id = "1",
        .numeric_user_id = 1,
        .expect_postgres_state = true,
    });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"section\":\"scheduler\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"scheduler_truth\":\"context_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"tenant_context_attached\":false") != null);
}

test "runtime info summary aligns scheduler backend and data source for override without tenant context" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    const parsed = try root.parseTestArgs("{\"section\":\"summary\",\"user_id\":\"1\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"scheduler_backend\":\"context_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"data_source\":\"context_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"context_incomplete\":true") != null);
}

test "runtime info execution truth surfaces compact founder-readable status" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";
    cfg.reliability.fallback_providers = &.{"anthropic"};

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:test:user:1:task:ship",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer root.clearTurnContext();
    root.setTenantContext(.{ .user_id = "1", .expect_postgres_state = true });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"section\":\"execution_truth\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_key\":\"agent:test:user:1:task:ship\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"owner\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"status\":\"degraded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"degraded\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"fallback_active\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"fallback_reason\":\"local_fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"fallback_chain\":\"anthropic\"") != null);
}

test "runtime info execution truth surfaces recovered failed task from durable ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const state_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace, "state" });
    defer std.testing.allocator.free(state_dir);
    try std.fs.makeDirAbsolute(state_dir);
    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ state_dir, "subagent_tasks.jsonl" });
    defer std.testing.allocator.free(ledger_path);
    try writeTestFile(
        ledger_path,
        "{\"id\":7,\"status\":\"failed\",\"label\":\"recover\",\"task_summary\":\"recover\",\"task_prompt\":\"recover prompt\",\"session_key\":\"agent:zaki-bot:user:1:main\",\"origin_channel\":\"agent\",\"origin_chat_id\":\"session:recover\",\"result\":null,\"error\":\"process_restarted_before_completion\",\"started_at\":42,\"completed_at\":84}\n",
    );

    var cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.fallback_providers = &.{"anthropic"};

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:zaki-bot:user:1:task:7",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer root.clearTurnContext();
    root.setTenantContext(.{ .user_id = "1" });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"section\":\"execution_truth\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"status\":\"attention\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"result\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"failure\":\"process_restarted_before_completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"degraded\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"degraded_reason\":\"\"") != null);
}

test "runtime info execution truth from main surfaces active background task truth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const state_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace, "state" });
    defer std.testing.allocator.free(state_dir);
    try std.fs.makeDirAbsolute(state_dir);
    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ state_dir, "subagent_tasks.jsonl" });
    defer std.testing.allocator.free(ledger_path);
    try writeTestFile(
        ledger_path,
        "{\"id\":7,\"status\":\"failed\",\"label\":\"recover\",\"task_summary\":\"recover\",\"task_prompt\":\"recover prompt\",\"request_session_key\":\"agent:zaki-bot:user:1:main\",\"runtime_session_key\":\"agent:zaki-bot:user:1:task:7\",\"error\":\"process_restarted_before_completion\",\"started_at\":42,\"completed_at\":84}\n" ++
            "{\"id\":8,\"status\":\"running\",\"label\":\"ship\",\"task_summary\":\"ship\",\"task_prompt\":\"ship prompt\",\"request_session_key\":\"agent:zaki-bot:user:1:main\",\"runtime_session_key\":\"agent:zaki-bot:user:1:task:8\",\"started_at\":100}\n",
    );

    var cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.fallback_providers = &.{"anthropic"};

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:zaki-bot:user:1:main",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer root.clearTurnContext();
    root.setTenantContext(.{ .user_id = "1" });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"section\":\"execution_truth\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_key\":\"agent:zaki-bot:user:1:task:8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"current_session_key\":\"agent:zaki-bot:user:1:main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"selection_rule\":\"main_active_task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"result\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"status\":\"active\"") != null);
}

test "runtime info execution truth from main falls back to attention task when no active task exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const state_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace, "state" });
    defer std.testing.allocator.free(state_dir);
    try std.fs.makeDirAbsolute(state_dir);
    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ state_dir, "subagent_tasks.jsonl" });
    defer std.testing.allocator.free(ledger_path);
    try writeTestFile(
        ledger_path,
        "{\"id\":7,\"status\":\"failed\",\"label\":\"recover\",\"task_summary\":\"recover\",\"task_prompt\":\"recover prompt\",\"request_session_key\":\"agent:zaki-bot:user:1:main\",\"runtime_session_key\":\"agent:zaki-bot:user:1:task:7\",\"error\":\"process_restarted_before_completion\",\"started_at\":42,\"completed_at\":84}\n" ++
            "{\"id\":8,\"status\":\"completed\",\"label\":\"done\",\"task_summary\":\"done\",\"task_prompt\":\"done prompt\",\"request_session_key\":\"agent:zaki-bot:user:1:main\",\"runtime_session_key\":\"agent:zaki-bot:user:1:task:8\",\"result\":\"completed\",\"started_at\":21,\"completed_at\":40}\n",
    );

    var cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.fallback_providers = &.{"anthropic"};

    var tool_impl = RuntimeInfoTool{ .config = &cfg };
    const t = tool_impl.tool();
    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:zaki-bot:user:1:main",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer root.clearTurnContext();
    root.setTenantContext(.{ .user_id = "1" });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"section\":\"execution_truth\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_key\":\"agent:zaki-bot:user:1:task:7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"current_session_key\":\"agent:zaki-bot:user:1:main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"selection_rule\":\"main_attention_task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"failure\":\"process_restarted_before_completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"status\":\"attention\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"degraded\":false") != null);
}

test "runtime info parseTelegramStateJson supports top-level postgres shape" {
    const raw =
        \\{"connected":true,"account_id":"main","chat_id":1110331014}
    ;
    var state = try parseTelegramStateJson(std.testing.allocator, raw);
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, true), state.connected);
    try std.testing.expectEqualStrings("main", state.account_id.?);
    try std.testing.expectEqual(@as(?i64, 1110331014), state.chat_id);
}
