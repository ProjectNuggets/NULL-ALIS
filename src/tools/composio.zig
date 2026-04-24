const std = @import("std");
const builtin = @import("builtin");
const appendJsonEscaped = @import("../util.zig").appendJsonEscaped;
const root = @import("root.zig");
const observability = @import("../observability.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const COMPOSIO_API_BASE_V2 = "https://backend.composio.dev/api/v2";
const COMPOSIO_API_BASE_V3 = "https://backend.composio.dev/api/v3";

/// Composio tool — proxy actions to the Composio managed tool platform.
/// Supports 1000+ OAuth integrations (Gmail, Notion, GitHub, Slack, etc.).
/// Operations: list (available actions), execute (run an action), connect (get OAuth URL).
/// Uses v3 API endpoints by default; list/execute keep legacy fallback for compatibility.
pub const ComposioTool = struct {
    api_key: []const u8,
    entity_id: []const u8,
    /// Optional observer for surfacing connector_stale notices to the user
    /// when OAuth/auth config failures happen. Binding rule: no silent
    /// fallback. Callers that have an observer handle may set this;
    /// callers that don't leave it null and notices are dropped here
    /// (log warnings still fire).
    observer: ?*observability.Observer = null,

    fn emitConnectorStaleNotice(self: *const ComposioTool, app_name: []const u8, detail: []const u8) void {
        // Prefer the explicitly-bound observer (rare — tools_slice is shared
        // across sessions so binding per-tool is generally wrong) then fall
        // back to the per-turn threadlocal set by the running agent.
        const obs = self.observer orelse root.getToolObserver() orelse return;
        var message_buf: [192]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buf,
            "Connector auth failed for {s}. You may need to reconnect.",
            .{app_name},
        ) catch "Connector auth failed. You may need to reconnect.";
        const event = observability.ObserverEvent{ .system_notice = .{
            .kind = "connector_stale",
            .severity = "warning",
            .message = message,
            .detail = detail,
        } };
        obs.recordEvent(&event);
    }

    pub const tool_name = "composio";
    pub const tool_description = "Execute actions on 1000+ apps via Composio (Gmail, Notion, GitHub, Slack, etc.). " ++
        "Use action='list' to see available actions, action='execute' with action_name/tool_slug and params, " ++
        "or action='connect' with app/auth_config_id to get OAuth URL.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["list","execute","connect"],"description":"Operation: list, execute, or connect"},"app":{"type":"string","description":"App/toolkit filter for list, or app/toolkit slug for connect"},"action_name":{"type":"string","description":"Action identifier to execute"},"tool_slug":{"type":"string","description":"Preferred v3 tool slug (alias of action_name)"},"params":{"type":"object","description":"Parameters for the action"},"entity_id":{"type":"string","description":"Entity/user ID for multi-user setups"},"auth_config_id":{"type":"string","description":"Optional v3 auth config id for connect"},"callback_url":{"type":"string","description":"Optional callback URL for connect link session"},"connection_data":{"type":"object","description":"Optional connect prefill data for OAuth link generation"},"connected_account_id":{"type":"string","description":"Optional connected account ID for execute"}},"required":["action"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ComposioTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ComposioTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        if (self.api_key.len == 0) {
            return ToolResult.fail("Composio API key not configured. Set composio.api_key in config.");
        }

        if (std.mem.eql(u8, action, "execute") or std.mem.eql(u8, action, "connect")) {
            if (validateTenantScopedEntity(args)) |validation_error| {
                return validation_error;
            }
        }

        if (std.mem.eql(u8, action, "list")) {
            return self.listActions(allocator, args);
        } else if (std.mem.eql(u8, action, "execute")) {
            return self.executeAction(allocator, args);
        } else if (std.mem.eql(u8, action, "connect")) {
            return self.connectAction(allocator, args);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Unknown action '{s}'. Use 'list', 'execute', or 'connect'.", .{action});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
    }

    // ── v3 list actions ────────────────────────────────────────────

    fn listActionsV3(self: *ComposioTool, allocator: std.mem.Allocator, app_name: ?[]const u8) !ToolResult {
        var url_buf: [512]u8 = undefined;
        const url = buildToolsListUrlV3(&url_buf, app_name) catch
            return ToolResult.fail("URL too long");

        return self.httpGet(allocator, url);
    }

    // ── v2 list actions (fallback) ─────────────────────────────────

    fn listActionsV2(self: *ComposioTool, allocator: std.mem.Allocator, app_name: ?[]const u8) !ToolResult {
        var url_buf: [512]u8 = undefined;
        const url = if (app_name) |a|
            std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V2 ++ "/actions?appNames={s}", .{a}) catch
                return ToolResult.fail("URL too long")
        else
            std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V2 ++ "/actions", .{}) catch
                return ToolResult.fail("URL too long");

        return self.httpGet(allocator, url);
    }

    fn listActions(self: *ComposioTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const app = root.getString(args, "app");

        // S7.15 — 60s TTL cache on the `list` action result. The API is
        // slow (multi-second) and returns a stable catalog on 60s
        // windows in practice; caching cuts both latency and API cost
        // for the repeated "what can I do in Gmail?" pattern. Cache key
        // is the (app-filter, v3-or-v2-shape) pair; the lookup strips
        // the v3/v2 distinction because we always try v3 first and a
        // successful v3 response makes v2 moot.
        //
        // Gated on `!builtin.is_test` because the cache is module-
        // scoped and existing tests that exercise listActions against
        // the live API would leak their heap-allocated cache entries
        // past the test-allocator's lifetime. The cache is a pure
        // production optimization; bypassing it in tests costs nothing
        // there and guarantees clean shutdown.
        const cache_key = app orelse "__all__";
        if (!builtin.is_test) {
            if (list_cache.get(allocator, cache_key)) |cached| {
                return ToolResult{ .success = true, .output = cached };
            }
        }

        // Try v3 first, fall back to v2
        const v3_result = try self.listActionsV3(allocator, app);
        if (v3_result.success) {
            if (!builtin.is_test) {
                list_cache.put(allocator, cache_key, v3_result.output) catch {};
            }
            return v3_result;
        }

        // Free v3 error resources before fallback
        if (v3_result.error_msg) |e| allocator.free(e);
        if (v3_result.output.len > 0) allocator.free(v3_result.output);

        const v2_result = try self.listActionsV2(allocator, app);
        if (v2_result.success and !builtin.is_test) {
            list_cache.put(allocator, cache_key, v2_result.output) catch {};
        }
        return v2_result;
    }

    // ── v3 execute action ──────────────────────────────────────────

    const EntityResolution = struct {
        entity_id: []const u8,
        source: []const u8,
    };

    fn explicitEntityArg(args: JsonObjectMap) ?[]const u8 {
        const entity_id = root.getString(args, "entity_id") orelse return null;
        const trimmed = std.mem.trim(u8, entity_id, " \t\r\n");
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    fn validateTenantScopedEntity(args: JsonObjectMap) ?ToolResult {
        const tenant_ctx = root.getTenantContext();
        if (!tenant_ctx.expect_postgres_state) return null;

        const tenant_user_id = tenant_ctx.user_id;
        const explicit_entity = explicitEntityArg(args);

        // Tenant-postgres mode must have authoritative tenant user context.
        if (tenant_user_id == null) {
            return ToolResult.fail("Composio execute/connect requires tenant user context. Use canonical session key agent:zaki-bot:user:<id>:...");
        }

        if (explicit_entity) |eid| {
            if (!std.mem.eql(u8, eid, tenant_user_id.?)) {
                return ToolResult.fail("Composio entity_id must match tenant user scope for this turn.");
            }
        }
        return null;
    }

    fn resolveExecutionEntityId(self: *ComposioTool, args: JsonObjectMap) EntityResolution {
        if (explicitEntityArg(args)) |trimmed| {
            return .{ .entity_id = trimmed, .source = "args" };
        }

        const tenant_ctx = root.getTenantContext();
        if (tenant_ctx.user_id) |tenant_user_id| {
            const trimmed = std.mem.trim(u8, tenant_user_id, " \t\r\n");
            if (trimmed.len > 0) {
                return .{ .entity_id = trimmed, .source = "tenant_ctx" };
            }
        }

        return .{
            .entity_id = normalizeEntityId(self.entity_id),
            .source = "tool_default",
        };
    }

    fn executeActionV3(self: *ComposioTool, allocator: std.mem.Allocator, action_name: []const u8, args: JsonObjectMap, entity_id: []const u8, connected_account_id: ?[]const u8) !ToolResult {
        const slug = try normalizeToolSlug(allocator, action_name);
        defer allocator.free(slug);

        var url_buf: [512]u8 = undefined;
        const url = buildExecuteToolUrlV3(&url_buf, slug) catch
            return ToolResult.fail("URL too long");

        // Build JSON body with arguments, user_id, and optional connected_account_id
        const params_json: ?[]const u8 = blk: {
            if (root.getValue(args, "params")) |pv| {
                break :blk std.json.Stringify.valueAlloc(allocator, pv, .{}) catch null;
            }
            break :blk null;
        };
        defer if (params_json) |pj| allocator.free(pj);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "{\"arguments\":");
        try out.appendSlice(allocator, params_json orelse "{}");
        try out.appendSlice(allocator, ",\"user_id\":\"");
        try appendJsonEscaped(&out, allocator, entity_id);
        try out.appendSlice(allocator, "\"");
        if (connected_account_id) |caid| {
            try out.appendSlice(allocator, ",\"connected_account_id\":\"");
            try appendJsonEscaped(&out, allocator, caid);
            try out.appendSlice(allocator, "\"");
        }
        try out.appendSlice(allocator, "}");
        const body = try out.toOwnedSlice(allocator);
        defer allocator.free(body);

        return self.httpPost(allocator, url, body);
    }

    // ── v2 execute action (fallback) ───────────────────────────────

    fn executeActionV2(self: *ComposioTool, allocator: std.mem.Allocator, action_name: []const u8, args: JsonObjectMap, resolved_entity_id: []const u8) !ToolResult {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V2 ++ "/actions/{s}/execute", .{action_name}) catch
            return ToolResult.fail("URL too long");

        // Ensure entity_id is present for user-scoped execution parity.
        var body_obj = std.json.ObjectMap.init(allocator);
        defer body_obj.deinit();
        var it = args.iterator();
        while (it.next()) |entry| {
            try body_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        const has_explicit_entity = blk: {
            break :blk explicitEntityArg(args) != null;
        };
        if (!has_explicit_entity) {
            try body_obj.put("entity_id", .{ .string = resolved_entity_id });
        }

        // Re-serialize ObjectMap to JSON for the HTTP body.
        const json_val = std.json.Value{ .object = body_obj };
        const body = std.json.Stringify.valueAlloc(allocator, json_val, .{}) catch
            return ToolResult.fail("Failed to serialize args");
        defer allocator.free(body);

        return self.httpPost(allocator, url, body);
    }

    fn executeAction(self: *ComposioTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action_name = root.getString(args, "tool_slug") orelse
            root.getString(args, "action_name") orelse
            return ToolResult.fail("Missing 'action_name' (or 'tool_slug') for execute");

        const entity_resolution = self.resolveExecutionEntityId(args);
        const connected_account_id = root.getString(args, "connected_account_id");

        // Try v3 first, fall back to v2
        const v3_result = try self.executeActionV3(allocator, action_name, args, entity_resolution.entity_id, connected_account_id);
        if (v3_result.success) return v3_result;

        // Free v3 error resources before fallback
        if (v3_result.error_msg) |e| allocator.free(e);
        if (v3_result.output.len > 0) allocator.free(v3_result.output);

        return self.executeActionV2(allocator, action_name, args, entity_resolution.entity_id);
    }

    // ── v3 connect ─────────────────────────────────────────────────

    fn connectActionV3(self: *ComposioTool, allocator: std.mem.Allocator, entity: []const u8, auth_config_id: []const u8, args: JsonObjectMap) !ToolResult {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V3 ++ "/connected_accounts/link", .{}) catch
            return ToolResult.fail("URL too long");
        const body = buildConnectBodyV3(allocator, entity, auth_config_id, args) catch
            return ToolResult.fail("Failed to build connect body");
        defer allocator.free(body);

        var raw = try self.httpPost(allocator, url, body);
        if (!raw.success) return raw;

        const normalized = try normalizeConnectLinkResponse(allocator, raw.output);
        if (normalized) |payload| {
            allocator.free(raw.output);
            raw.output = payload;
        } else if (connectResponseLooksLinkWithoutRedirect(allocator, raw.output)) {
            allocator.free(raw.output);
            raw.output = "";
            raw.success = false;
            raw.error_msg = try allocator.dupe(
                u8,
                "Composio connect response missing redirect_url. Generate a fresh link and open it immediately; do not reuse older links.",
            );
        }
        return raw;
    }

    fn resolveAuthConfigIdV3(self: *ComposioTool, allocator: std.mem.Allocator, app: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, app, " \t\n");
        if (trimmed.len == 0) return error.AuthConfigNotFound;

        const canonical = try lowerNoSeparators(allocator, trimmed);
        defer allocator.free(canonical);

        var candidates: [2][]const u8 = .{ trimmed, canonical };
        var candidate_count: usize = 1;
        if (!std.mem.eql(u8, canonical, trimmed)) {
            candidates[1] = canonical;
            candidate_count = 2;
        }

        var i: usize = 0;
        while (i < candidate_count) : (i += 1) {
            var url_buf: [640]u8 = undefined;
            const url = std.fmt.bufPrint(
                &url_buf,
                COMPOSIO_API_BASE_V3 ++ "/auth_configs?toolkit_slug={s}&show_disabled=false&limit=25",
                .{candidates[i]},
            ) catch return error.AuthConfigLookupFailed;

            const lookup = try self.httpGet(allocator, url);
            defer if (lookup.error_msg) |e| allocator.free(e);
            defer if (lookup.output.len > 0) allocator.free(lookup.output);
            if (!lookup.success) continue;
            const auth_id = parseBestAuthConfigId(allocator, lookup.output, candidates[i]) catch |err| switch (err) {
                error.AuthConfigNotFound => continue,
                error.InvalidResponse => continue,
                error.AuthConfigAmbiguous => return err,
                else => return error.AuthConfigLookupFailed,
            };
            return auth_id;
        }

        return error.AuthConfigNotFound;
    }

    fn connectAction(self: *ComposioTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const app = root.getString(args, "app");
        const auth_config_id_in = root.getString(args, "auth_config_id");
        if (app == null and auth_config_id_in == null) {
            return ToolResult.fail("Missing 'app' or 'auth_config_id' for connect");
        }
        if (root.getString(args, "callback_url")) |callback_url| {
            validateConnectCallbackUrl(callback_url) catch {
                return ToolResult.fail("Invalid 'callback_url'. Use https://... (or http://localhost/127.0.0.1 for local dev).");
            };
        }

        const entity_resolution = self.resolveExecutionEntityId(args);

        var auth_config_id_owned: ?[]u8 = null;
        defer if (auth_config_id_owned) |owned| allocator.free(owned);
        const auth_config_id = if (auth_config_id_in) |given|
            given
        else blk: {
            const app_name = app orelse return ToolResult.fail("Missing 'app' for connect");
            auth_config_id_owned = self.resolveAuthConfigIdV3(allocator, app_name) catch |err| {
                // Binding rule: no silent fallback. Surface as system_notice
                // so the user sees the connector needs reconnection.
                self.emitConnectorStaleNotice(app_name, @errorName(err));
                return switch (err) {
                    error.AuthConfigNotFound => blk_err: {
                        const msg = allocator.dupe(u8, "No v3 auth_config found for app. Pass auth_config_id explicitly.") catch
                            break :blk_err ToolResult.fail("No v3 auth_config found for app. Pass auth_config_id explicitly.");
                        break :blk_err ToolResult{ .success = false, .output = "", .error_msg = msg };
                    },
                    error.AuthConfigAmbiguous => blk_err: {
                        const msg = allocator.dupe(u8, "Multiple equally-ranked auth configs found for app. Pass auth_config_id explicitly.") catch
                            break :blk_err ToolResult.fail("Multiple equally-ranked auth configs found for app. Pass auth_config_id explicitly.");
                        break :blk_err ToolResult{ .success = false, .output = "", .error_msg = msg };
                    },
                    else => blk_err: {
                        const msg = allocator.dupe(u8, "Failed to resolve auth_config_id via v3 auth_configs") catch
                            break :blk_err ToolResult.fail("Failed to resolve auth_config_id via v3 auth_configs");
                        break :blk_err ToolResult{ .success = false, .output = "", .error_msg = msg };
                    },
                };
            };
            break :blk auth_config_id_owned.?;
        };

        return self.connectActionV3(allocator, entity_resolution.entity_id, auth_config_id, args);
    }

    // ── HTTP helpers ───────────────────────────────────────────────

    fn httpGet(self: *ComposioTool, allocator: std.mem.Allocator, url: []const u8) !ToolResult {
        const auth_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{self.api_key});
        defer allocator.free(auth_header);

        var argv_buf: [20][]const u8 = undefined;
        var argc: usize = 0;
        argv_buf[argc] = "curl";
        argc += 1;
        argv_buf[argc] = "-sL";
        argc += 1;
        argv_buf[argc] = "-m";
        argc += 1;
        argv_buf[argc] = "15";
        argc += 1;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = auth_header;
        argc += 1;
        argv_buf[argc] = url;
        argc += 1;

        return self.runCurl(allocator, argv_buf[0..argc]);
    }

    fn httpPost(self: *ComposioTool, allocator: std.mem.Allocator, url: []const u8, body: []const u8) !ToolResult {
        const auth_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{self.api_key});
        defer allocator.free(auth_header);

        var argv_buf: [20][]const u8 = undefined;
        var argc: usize = 0;
        argv_buf[argc] = "curl";
        argc += 1;
        argv_buf[argc] = "-sS";
        argc += 1;
        argv_buf[argc] = "-m";
        argc += 1;
        argv_buf[argc] = "15";
        argc += 1;
        argv_buf[argc] = "-X";
        argc += 1;
        argv_buf[argc] = "POST";
        argc += 1;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = auth_header;
        argc += 1;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = "Content-Type: application/json";
        argc += 1;
        argv_buf[argc] = "-d";
        argc += 1;
        argv_buf[argc] = body;
        argc += 1;
        argv_buf[argc] = url;
        argc += 1;

        return self.runCurl(allocator, argv_buf[0..argc]);
    }

    /// Run curl as a child process with S7.14 exponential-backoff retry on
    /// HTTP 429 (Composio rate-limit). Up to 3 total attempts with 1s / 2s
    /// delays between them. 429 detection looks for the substring `"429"` +
    /// any of {`rate`, `Too Many`, `ratelimit`} in the body — Composio's
    /// error JSON uses a few different shapes depending on endpoint. Other
    /// HTTP failures (401, 500, etc.) return on the first attempt; retries
    /// only fire for the specific backoff-appropriate case.
    fn runCurl(_: *ComposioTool, allocator: std.mem.Allocator, argv: []const []const u8) !ToolResult {
        const proc = @import("process_util.zig");
        const MAX_ATTEMPTS: u8 = 3;
        var attempt: u8 = 0;
        while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
            if (attempt > 0) {
                // Exponential backoff: 1s, 2s. Wall-clock sleep because
                // curl already ran to completion — no event loop to yield to.
                const delay_ns: u64 = (@as(u64, 1) << @intCast(attempt - 1)) * std.time.ns_per_s;
                std.Thread.sleep(delay_ns);
            }

            const result = try proc.run(allocator, argv, .{});
            if (result.success) {
                defer allocator.free(result.stderr);
                if (result.stdout.len == 0) {
                    allocator.free(result.stdout);
                    return ToolResult{ .success = true, .output = try allocator.dupe(u8, "(empty response)") };
                }
                // Inspect body for 429 marker. Only retry if we have budget.
                if (attempt + 1 < MAX_ATTEMPTS and looksLikeRateLimit(result.stdout)) {
                    allocator.free(result.stdout);
                    continue;
                }
                return ToolResult{ .success = true, .output = result.stdout };
            }
            // Non-success process exit: return on the LAST attempt; otherwise
            // try again (curl exit 28 on timeout can be transient).
            defer allocator.free(result.stdout);
            if (attempt + 1 < MAX_ATTEMPTS) {
                allocator.free(result.stderr);
                continue;
            }
            defer allocator.free(result.stderr);
            if (result.exit_code != null) {
                const err_out = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "curl failed with non-zero exit code");
                return ToolResult{ .success = false, .output = "", .error_msg = err_out };
            }
            return ToolResult{ .success = false, .output = "", .error_msg = "curl terminated by signal" };
        }
        // Unreachable — loop returns or breaks; guard against future edits
        // that add a continue without a terminal return.
        return ToolResult{ .success = false, .output = "", .error_msg = "composio retry exhausted" };
    }
};

// S7.15 — 60s TTL cache for Composio `list` action results.
//
// Small fixed-slot cache (16 entries; 1 per app-filter). Entries are
// keyed by the app name (or `"__all__"` for the no-filter case). Both
// key and value are heap-allocated and freed on eviction. Thread-safe
// via a single mutex. Reset helper provided for tests.
const LIST_CACHE_TTL_MS: i64 = 60_000;
const LIST_CACHE_SLOTS: usize = 16;

const ListCacheEntry = struct {
    key: ?[]u8 = null,
    value: ?[]u8 = null,
    expires_at_ms: i64 = 0,
};

const ListCache = struct {
    mutex: std.Thread.Mutex = .{},
    entries: [LIST_CACHE_SLOTS]ListCacheEntry = [_]ListCacheEntry{.{}} ** LIST_CACHE_SLOTS,

    /// Return a fresh heap copy of the cached value for `key`, or null
    /// if absent/expired. Caller owns the returned slice.
    fn get(self: *ListCache, allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        for (&self.entries) |*entry| {
            const ek = entry.key orelse continue;
            if (!std.mem.eql(u8, ek, key)) continue;
            if (now > entry.expires_at_ms) return null;
            const v = entry.value orelse return null;
            return allocator.dupe(u8, v) catch null;
        }
        return null;
    }

    /// Store `value` under `key` with the module TTL. Takes ownership
    /// of nothing — both `key` and `value` are copied. On collision or
    /// expiry the oldest entry gets evicted (simple LRU approximated
    /// by expires_at_ms comparison).
    fn put(self: *ListCache, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        const new_expiry = now + LIST_CACHE_TTL_MS;

        // First pass: update existing entry or fill an empty slot.
        for (&self.entries) |*entry| {
            if (entry.key) |ek| {
                if (std.mem.eql(u8, ek, key)) {
                    if (entry.value) |v| allocator.free(v);
                    entry.value = try allocator.dupe(u8, value);
                    entry.expires_at_ms = new_expiry;
                    return;
                }
            } else {
                entry.key = try allocator.dupe(u8, key);
                errdefer {
                    allocator.free(entry.key.?);
                    entry.key = null;
                }
                entry.value = try allocator.dupe(u8, value);
                entry.expires_at_ms = new_expiry;
                return;
            }
        }

        // All slots full — evict the entry with the earliest expiry.
        var victim_idx: usize = 0;
        var victim_expiry: i64 = self.entries[0].expires_at_ms;
        for (self.entries, 0..) |entry, i| {
            if (entry.expires_at_ms < victim_expiry) {
                victim_expiry = entry.expires_at_ms;
                victim_idx = i;
            }
        }
        const victim = &self.entries[victim_idx];
        if (victim.key) |k| allocator.free(k);
        if (victim.value) |v| allocator.free(v);
        victim.key = try allocator.dupe(u8, key);
        errdefer {
            allocator.free(victim.key.?);
            victim.key = null;
        }
        victim.value = try allocator.dupe(u8, value);
        victim.expires_at_ms = new_expiry;
    }

    /// Reset helper — clears all entries + frees their backing
    /// allocations. Test-only.
    pub fn resetForTest(self: *ListCache, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.key) |k| allocator.free(k);
            if (entry.value) |v| allocator.free(v);
            entry.key = null;
            entry.value = null;
            entry.expires_at_ms = 0;
        }
    }
};

var list_cache: ListCache = .{};

test "ListCache put + get roundtrip" {
    const allocator = std.testing.allocator;
    defer list_cache.resetForTest(allocator);
    list_cache.resetForTest(allocator);

    try list_cache.put(allocator, "gmail", "action-list-1");
    const got = list_cache.get(allocator, "gmail") orelse return error.CacheMissUnexpected;
    defer allocator.free(got);
    try std.testing.expectEqualStrings("action-list-1", got);
}

test "ListCache miss on unknown key" {
    const allocator = std.testing.allocator;
    defer list_cache.resetForTest(allocator);
    list_cache.resetForTest(allocator);

    try std.testing.expect(list_cache.get(allocator, "nonexistent") == null);
}

test "ListCache update existing key frees old value" {
    const allocator = std.testing.allocator;
    defer list_cache.resetForTest(allocator);
    list_cache.resetForTest(allocator);

    try list_cache.put(allocator, "notion", "v1-payload");
    try list_cache.put(allocator, "notion", "v2-payload");
    const got = list_cache.get(allocator, "notion") orelse return error.CacheMissUnexpected;
    defer allocator.free(got);
    try std.testing.expectEqualStrings("v2-payload", got);
}

/// Heuristic rate-limit detector: look for "429" + a rate-related token
/// in the response body. Composio returns rate-limit errors in several
/// shapes (`{"code":429,...}`, `{"status":"rate_limited",...}`, plain
/// "Too Many Requests") so a multi-needle scan is more robust than an
/// exact-shape parse for a retry decision.
fn looksLikeRateLimit(body: []const u8) bool {
    const has_429 = std.mem.indexOf(u8, body, "429") != null;
    if (!has_429) return false;
    if (std.mem.indexOf(u8, body, "rate") != null) return true;
    if (std.mem.indexOf(u8, body, "Rate") != null) return true;
    if (std.mem.indexOf(u8, body, "Too Many") != null) return true;
    if (std.mem.indexOf(u8, body, "too_many") != null) return true;
    return false;
}

test "looksLikeRateLimit detects common 429 shapes" {
    try std.testing.expect(looksLikeRateLimit("{\"code\":429,\"message\":\"rate limited\"}"));
    try std.testing.expect(looksLikeRateLimit("{\"status\":429,\"error\":\"Too Many Requests\"}"));
    try std.testing.expect(looksLikeRateLimit("HTTP 429 rate_limited"));
    try std.testing.expect(!looksLikeRateLimit("{\"code\":200,\"data\":[]}"));
    try std.testing.expect(!looksLikeRateLimit("{\"code\":500,\"message\":\"internal error\"}"));
    // 429 in content without rate context isn't enough to retry — avoids
    // false positives on payloads that happen to contain "429" in a token
    // like an action ID or phone number.
    try std.testing.expect(!looksLikeRateLimit("{\"phone\":\"+14295550000\"}"));
}

// ── Helper functions ────────────────────────────────────────────────

/// Normalize tool slug by trimming only.
/// Composio v3 expects the exact slug shape returned by list APIs
/// (often UPPER_SNAKE_CASE for many toolkits).
pub fn normalizeToolSlug(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\n");
    return allocator.dupe(u8, trimmed);
}

/// Normalize entity ID: trim whitespace, default to "default" if empty.
pub fn normalizeEntityId(entity_id: ?[]const u8) []const u8 {
    if (entity_id) |eid| {
        const trimmed = std.mem.trim(u8, eid, " \t\n");
        if (trimmed.len > 0) return trimmed;
    }
    return "default";
}

fn buildToolsListUrlV3(url_buf: []u8, app_name: ?[]const u8) ![]const u8 {
    return if (app_name) |a|
        std.fmt.bufPrint(url_buf, COMPOSIO_API_BASE_V3 ++ "/tools?toolkit_slug={s}&page=1&page_size=100", .{a})
    else
        std.fmt.bufPrint(url_buf, COMPOSIO_API_BASE_V3 ++ "/tools?page=1&page_size=100", .{});
}

fn buildExecuteToolUrlV3(url_buf: []u8, tool_slug: []const u8) ![]const u8 {
    return std.fmt.bufPrint(url_buf, COMPOSIO_API_BASE_V3 ++ "/tools/execute/{s}", .{tool_slug});
}

fn buildConnectBodyV3(allocator: std.mem.Allocator, entity: []const u8, auth_config_id: []const u8, args: JsonObjectMap) ![]u8 {
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer body_buf.deinit(allocator);
    try body_buf.appendSlice(allocator, "{\"user_id\":\"");
    try appendJsonEscaped(&body_buf, allocator, entity);
    try body_buf.appendSlice(allocator, "\",\"auth_config_id\":\"");
    try appendJsonEscaped(&body_buf, allocator, auth_config_id);
    try body_buf.appendSlice(allocator, "\"");

    if (root.getString(args, "callback_url")) |callback_url| {
        try body_buf.appendSlice(allocator, ",\"callback_url\":\"");
        try appendJsonEscaped(&body_buf, allocator, callback_url);
        try body_buf.appendSlice(allocator, "\"");
    }

    if (root.getValue(args, "connection_data")) |connection_data| {
        const connection_data_json = std.json.Stringify.valueAlloc(allocator, connection_data, .{}) catch null;
        defer if (connection_data_json) |cd| allocator.free(cd);
        if (connection_data_json) |cd| {
            try body_buf.appendSlice(allocator, ",\"connection_data\":");
            try body_buf.appendSlice(allocator, cd);
        }
    }

    try body_buf.appendSlice(allocator, "}");
    return body_buf.toOwnedSlice(allocator);
}

fn isLocalDevCallbackAuthority(rest: []const u8) bool {
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return false;
    const authority = rest[0..end];
    if (std.mem.eql(u8, authority, "localhost")) return true;
    if (std.mem.startsWith(u8, authority, "localhost:")) return true;
    if (std.mem.eql(u8, authority, "127.0.0.1")) return true;
    if (std.mem.startsWith(u8, authority, "127.0.0.1:")) return true;
    if (std.mem.eql(u8, authority, "[::1]")) return true;
    if (std.mem.startsWith(u8, authority, "[::1]:")) return true;
    return false;
}

fn validateConnectCallbackUrl(callback_url: []const u8) !void {
    const trimmed = std.mem.trim(u8, callback_url, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidCallbackUrl;
    if (std.mem.startsWith(u8, trimmed, "https://")) {
        if (trimmed.len <= "https://".len) return error.InvalidCallbackUrl;
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "http://")) {
        const rest = trimmed["http://".len..];
        if (!isLocalDevCallbackAuthority(rest)) return error.InvalidCallbackUrl;
        return;
    }
    return error.InvalidCallbackUrl;
}

fn firstObjectString(obj: std.json.ObjectMap, comptime fields: []const []const u8) ?[]const u8 {
    inline for (fields) |field| {
        if (obj.get(field)) |v| {
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return null;
}

fn selectConnectPayloadObject(root_obj: std.json.ObjectMap) std.json.ObjectMap {
    const redirect_fields = &.{ "redirect_url", "redirectUrl", "url", "link" };
    const token_fields = &.{ "link_token", "linkToken" };
    if (firstObjectString(root_obj, redirect_fields) != null or firstObjectString(root_obj, token_fields) != null) {
        return root_obj;
    }
    if (root_obj.get("data")) |data_val| {
        if (data_val == .object) {
            const nested = data_val.object;
            if (firstObjectString(nested, redirect_fields) != null or firstObjectString(nested, token_fields) != null) {
                return nested;
            }
        }
    }
    return root_obj;
}

fn connectResponseLooksLinkWithoutRedirect(allocator: std.mem.Allocator, raw_body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = selectConnectPayloadObject(parsed.value.object);
    const has_redirect = firstObjectString(obj, &.{ "redirect_url", "redirectUrl", "url", "link" }) != null;
    const has_token = firstObjectString(obj, &.{ "link_token", "linkToken" }) != null;
    return has_token and !has_redirect;
}

/// Normalize Composio connect response into a stable payload that always includes
/// one canonical URL field (`redirect_url`).
fn normalizeConnectLinkResponse(allocator: std.mem.Allocator, raw_body: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const obj = selectConnectPayloadObject(parsed.value.object);
    const redirect_in = firstObjectString(obj, &.{ "redirect_url", "redirectUrl", "url", "link" });
    const link_token = firstObjectString(obj, &.{ "link_token", "linkToken" });
    const expires_at = firstObjectString(obj, &.{ "expires_at", "expiresAt" });
    const connected_account_id = firstObjectString(obj, &.{ "connected_account_id", "connectedAccountId" });
    if (redirect_in == null) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":\"connect_link_created\",\"redirect_url\":\"");
    try appendJsonEscaped(&out, allocator, redirect_in.?);
    try out.appendSlice(allocator, "\"");

    if (expires_at) |value| {
        try out.appendSlice(allocator, ",\"expires_at\":\"");
        try appendJsonEscaped(&out, allocator, value);
        try out.appendSlice(allocator, "\"");
    } else {
        try out.appendSlice(allocator, ",\"expires_at\":null");
    }

    if (connected_account_id) |value| {
        try out.appendSlice(allocator, ",\"connected_account_id\":\"");
        try appendJsonEscaped(&out, allocator, value);
        try out.appendSlice(allocator, "\"");
    } else {
        try out.appendSlice(allocator, ",\"connected_account_id\":null");
    }

    if (link_token) |value| {
        try out.appendSlice(allocator, ",\"link_token\":\"");
        try appendJsonEscaped(&out, allocator, value);
        try out.appendSlice(allocator, "\"");
    } else {
        try out.appendSlice(allocator, ",\"link_token\":null");
    }

    try out.appendSlice(allocator, ",\"generated_at_s\":");
    try std.fmt.format(out.writer(allocator), "{d}", .{std.time.timestamp()});
    try out.appendSlice(allocator, ",\"note\":\"Open redirect_url exactly as returned. Link is short-lived and may be single-use; if invalid, generate a fresh connect link.\"}");
    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

fn lowerNoSeparators(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (input) |c| {
        if (c == '-' or c == '_' or c == ' ') continue;
        try out.append(allocator, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(allocator);
}

const AuthConfigSelection = struct {
    id: []u8,
    score: u8,
    updated_at: []const u8,
};

fn authConfigCanonicalToolkitSlug(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?[]u8 {
    if (obj.get("toolkit")) |toolkit_val| {
        if (toolkit_val == .object) {
            if (toolkit_val.object.get("slug")) |slug_val| {
                if (slug_val == .string and slug_val.string.len > 0) {
                    return try lowerNoSeparators(allocator, slug_val.string);
                }
            }
        }
    }

    const direct = firstObjectString(obj, &.{ "toolkit_slug", "toolkitSlug", "app" }) orelse return null;
    return try lowerNoSeparators(allocator, direct);
}

fn authConfigSelectionScore(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    expected_toolkit_canonical: []const u8,
) !?u8 {
    if (obj.get("status")) |status_val| {
        if (status_val == .string and std.ascii.eqlIgnoreCase(status_val.string, "DISABLED")) {
            return null;
        }
    }
    if (try authConfigCanonicalToolkitSlug(allocator, obj)) |observed| {
        defer allocator.free(observed);
        if (std.mem.eql(u8, observed, expected_toolkit_canonical)) return 2;
    }
    return 1;
}

fn selectionUpdatedAt(obj: std.json.ObjectMap) []const u8 {
    return firstObjectString(obj, &.{ "last_updated_at", "lastUpdatedAt", "updated_at", "updatedAt" }) orelse "";
}

fn considerAuthConfigSelection(
    allocator: std.mem.Allocator,
    maybe_best: *?AuthConfigSelection,
    ambiguous: *bool,
    obj: std.json.ObjectMap,
    expected_toolkit_canonical: []const u8,
) !void {
    const score = (try authConfigSelectionScore(allocator, obj, expected_toolkit_canonical)) orelse return;
    const id = firstObjectString(obj, &.{ "id", "auth_config_id", "authConfigId", "nanoid" }) orelse return;
    const updated_at = selectionUpdatedAt(obj);

    if (maybe_best.* == null) {
        maybe_best.* = .{
            .id = try allocator.dupe(u8, id),
            .score = score,
            .updated_at = updated_at,
        };
        ambiguous.* = false;
        return;
    }

    const best = &maybe_best.*.?;
    var replace = false;
    if (score > best.score) {
        replace = true;
    } else if (score == best.score) {
        const order = std.mem.order(u8, updated_at, best.updated_at);
        if (order == .gt) {
            replace = true;
        } else if (order == .eq and !std.mem.eql(u8, id, best.id)) {
            ambiguous.* = true;
        }
    }

    if (replace) {
        allocator.free(best.id);
        best.* = .{
            .id = try allocator.dupe(u8, id),
            .score = score,
            .updated_at = updated_at,
        };
        ambiguous.* = false;
    }
}

fn parseBestAuthConfigId(allocator: std.mem.Allocator, body: []const u8, expected_toolkit_slug: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const obj = parsed.value.object;
    const expected_toolkit_canonical = try lowerNoSeparators(allocator, expected_toolkit_slug);
    defer allocator.free(expected_toolkit_canonical);

    var best: ?AuthConfigSelection = null;
    defer if (best) |selection| allocator.free(selection.id);
    var ambiguous = false;

    try considerAuthConfigSelection(allocator, &best, &ambiguous, obj, expected_toolkit_canonical);

    const list_fields = [_][]const u8{ "items", "data", "results", "auth_configs" };
    for (list_fields) |field| {
        const list_val = obj.get(field) orelse continue;
        if (list_val != .array) continue;
        for (list_val.array.items) |item| {
            if (item != .object) continue;
            try considerAuthConfigSelection(allocator, &best, &ambiguous, item.object, expected_toolkit_canonical);
        }
    }

    if (best) |selection| {
        if (ambiguous) return error.AuthConfigAmbiguous;
        return allocator.dupe(u8, selection.id);
    }
    return error.AuthConfigNotFound;
}

/// Sanitize error message: redact potential secrets (long alphanumeric strings > 20 chars)
/// and truncate to 240 chars.
pub fn sanitizeErrorMessage(allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
    // Replace newlines with spaces
    var sanitized = try allocator.alloc(u8, msg.len);
    defer allocator.free(sanitized);
    for (msg, 0..) |c, i| {
        sanitized[i] = if (c == '\n') ' ' else c;
    }

    // Scan for long alphanumeric runs (potential tokens) and redact
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);
    var i: usize = 0;
    while (i < sanitized.len) {
        // Check if we're starting an alphanumeric run
        if (std.ascii.isAlphanumeric(sanitized[i])) {
            const start = i;
            while (i < sanitized.len and std.ascii.isAlphanumeric(sanitized[i])) : (i += 1) {}
            const run_len = i - start;
            if (run_len > 20) {
                try result.appendSlice(allocator, "[REDACTED]");
            } else {
                try result.appendSlice(allocator, sanitized[start..i]);
            }
        } else {
            try result.append(allocator, sanitized[i]);
            i += 1;
        }
    }

    // Truncate to 240 chars
    const items = result.items;
    if (items.len <= 240) {
        return try allocator.dupe(u8, items);
    } else {
        const truncated = try allocator.alloc(u8, 243); // 240 + "..."
        @memcpy(truncated[0..240], items[0..240]);
        @memcpy(truncated[240..243], "...");
        return truncated;
    }
}

/// Extract error message from JSON response body.
/// Tries {"error":{"message":"..."}} then {"message":"..."}.
pub fn extractApiErrorMessage(allocator: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const root_val = parsed.value;

    // Try {"error":{"message":"..."}}
    if (root_val.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg_val| {
                if (msg_val == .string) {
                    return try allocator.dupe(u8, msg_val.string);
                }
            }
        }
    }

    // Try {"message":"..."}
    if (root_val.object.get("message")) |msg_val| {
        if (msg_val == .string) {
            return try allocator.dupe(u8, msg_val.string);
        }
    }

    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "composio tool name" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    try std.testing.expectEqualStrings("composio", t.name());
}

test "composio tool schema has action" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "action") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "action_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "tool_slug") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "app") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "connected_account_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "auth_config_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "callback_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "connection_data") != null);
}

test "composio missing action returns error" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action") != null);
}

test "composio unknown action returns error" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"unknown\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown action") != null);
}

test "composio no api key returns error" {
    var ct = ComposioTool{ .api_key = "", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"list\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "API key") != null);
}

test "composio list action invokes curl" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"list\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    // curl actually runs — may succeed with API error JSON or fail with network error
    // Either way, we get a result (not a Zig error)
    try std.testing.expect(result.output.len > 0 or result.error_msg != null);
}

test "composio list with app filter invokes curl" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"list\", \"app\": \"gmail\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.output.len > 0 or result.error_msg != null);
}

test "composio execute missing action_name" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"execute\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action_name") != null);
}

test "composio execute with action_name invokes curl" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"execute\", \"action_name\": \"GMAIL_SEND\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    // curl runs against real API — may return error JSON or network failure
    try std.testing.expect(result.output.len > 0 or result.error_msg != null);
}

test "composio connect missing app" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"connect\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "app") != null or std.mem.indexOf(u8, result.error_msg.?, "auth_config_id") != null);
}

test "composio connect with app invokes curl" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"connect\", \"app\": \"gmail\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    // curl runs — result depends on network, but should not crash
    try std.testing.expect(result.output.len > 0 or result.error_msg != null);
}

test "composio execute fails closed when tenant context missing in tenant-postgres mode" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    root.setTenantContext(.{
        .expect_postgres_state = true,
    });
    defer root.clearTenantContext();
    const parsed = try root.parseTestArgs("{\"action\": \"execute\", \"action_name\": \"GMAIL_SEND\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "requires tenant user context") != null);
}

test "composio execute rejects mismatched explicit entity in tenant-postgres mode" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default" };
    const t = ct.tool();
    root.setTenantContext(.{
        .expect_postgres_state = true,
        .user_id = "42",
    });
    defer root.clearTenantContext();
    const parsed = try root.parseTestArgs("{\"action\": \"execute\", \"action_name\": \"GMAIL_SEND\", \"entity_id\":\"7\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "must match tenant user scope") != null);
}

// ── v3 helper tests ─────────────────────────────────────────────────

test "composio v3 api base url" {
    try std.testing.expectEqualStrings("https://backend.composio.dev/api/v3", COMPOSIO_API_BASE_V3);
}

test "composio buildToolsListUrlV3 uses toolkit_slug filter" {
    var buf: [512]u8 = undefined;
    const url = try buildToolsListUrlV3(&buf, "gmail");
    try std.testing.expect(std.mem.indexOf(u8, url, "toolkit_slug=gmail") != null);
}

test "composio buildExecuteToolUrlV3 uses execute prefix path" {
    var buf: [512]u8 = undefined;
    const url = try buildExecuteToolUrlV3(&buf, "gmail-list-labels");
    try std.testing.expectEqualStrings("https://backend.composio.dev/api/v3/tools/execute/gmail-list-labels", url);
}

test "composio buildConnectBodyV3 includes auth_config_id and user_id" {
    const alloc = std.testing.allocator;
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const body = try buildConnectBodyV3(alloc, "user-1", "ac_123", parsed.value.object);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"user_id\":\"user-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"auth_config_id\":\"ac_123\"") != null);
}

test "composio buildConnectBodyV3 includes callback_url and connection_data when provided" {
    const alloc = std.testing.allocator;
    const parsed = try root.parseTestArgs(
        \\{"callback_url":"https://example.com/cb","connection_data":{"tenant":"acme"}}
    );
    defer parsed.deinit();
    const body = try buildConnectBodyV3(alloc, "user-1", "ac_123", parsed.value.object);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"callback_url\":\"https://example.com/cb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"connection_data\":{\"tenant\":\"acme\"}") != null);
}

test "composio validateConnectCallbackUrl accepts https" {
    try validateConnectCallbackUrl("https://example.com/cb");
}

test "composio validateConnectCallbackUrl accepts local http" {
    try validateConnectCallbackUrl("http://localhost:3000/cb");
    try validateConnectCallbackUrl("http://127.0.0.1:8080/cb");
    try validateConnectCallbackUrl("http://[::1]:8787/cb");
}

test "composio validateConnectCallbackUrl rejects non-local http" {
    try std.testing.expectError(error.InvalidCallbackUrl, validateConnectCallbackUrl("http://example.com/cb"));
}

test "composio validateConnectCallbackUrl rejects malformed values" {
    try std.testing.expectError(error.InvalidCallbackUrl, validateConnectCallbackUrl(""));
    try std.testing.expectError(error.InvalidCallbackUrl, validateConnectCallbackUrl("ftp://example.com/cb"));
}

test "composio normalizeConnectLinkResponse prefers redirect_url" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"link_token":"lk_abc","redirect_url":"https://connect.composio.dev/link/lk_abc?sid=1","expires_at":"2026-03-10T00:00:00Z","connected_account_id":"ca_123"}
    ;
    const normalized = try normalizeConnectLinkResponse(alloc, raw);
    defer if (normalized) |v| alloc.free(v);
    try std.testing.expect(normalized != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.?, "\"redirect_url\":\"https://connect.composio.dev/link/lk_abc?sid=1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.?, "\"connected_account_id\":\"ca_123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.?, "\"generated_at_s\":") != null);
}

test "composio normalizeConnectLinkResponse requires redirect_url" {
    const alloc = std.testing.allocator;
    const raw = "{\"link_token\":\"lk_xyz\"}";
    const normalized = try normalizeConnectLinkResponse(alloc, raw);
    try std.testing.expect(normalized == null);
}

test "composio normalizeConnectLinkResponse supports nested data payload" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"status":"ok","data":{"link_token":"lk_nested","redirect_url":"https://connect.composio.dev/link/lk_nested","expires_at":"2026-03-10T00:00:00Z","connected_account_id":"ca_nested"}}
    ;
    const normalized = try normalizeConnectLinkResponse(alloc, raw);
    defer if (normalized) |v| alloc.free(v);
    try std.testing.expect(normalized != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.?, "\"redirect_url\":\"https://connect.composio.dev/link/lk_nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.?, "\"connected_account_id\":\"ca_nested\"") != null);
}

test "composio connectResponseLooksLinkWithoutRedirect flags unusable payload" {
    const alloc = std.testing.allocator;
    try std.testing.expect(connectResponseLooksLinkWithoutRedirect(alloc, "{\"link_token\":\"lk_xyz\"}"));
    try std.testing.expect(connectResponseLooksLinkWithoutRedirect(alloc, "{\"data\":{\"link_token\":\"lk_xyz\"}}"));
    try std.testing.expect(!connectResponseLooksLinkWithoutRedirect(alloc, "{\"redirect_url\":\"https://connect.composio.dev/link/lk_ok\"}"));
}

test "composio normalizeConnectLinkResponse returns null for non-object payload" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeConnectLinkResponse(alloc, "[]");
    try std.testing.expect(normalized == null);
}

test "composio lowerNoSeparators normalizes toolkit slug variants" {
    const alloc = std.testing.allocator;
    const normalized = try lowerNoSeparators(alloc, "Google-Drive");
    defer alloc.free(normalized);
    try std.testing.expectEqualStrings("googledrive", normalized);
}

test "composio parseBestAuthConfigId reads id from items payload" {
    const alloc = std.testing.allocator;
    const id = try parseBestAuthConfigId(alloc,
        \\{"items":[{"id":"ac_abc123","status":"ENABLED"}]}
    , "github");
    defer alloc.free(id);
    try std.testing.expectEqualStrings("ac_abc123", id);
}

test "composio parseBestAuthConfigId prefers exact toolkit match over newer non-match" {
    const alloc = std.testing.allocator;
    const id = try parseBestAuthConfigId(alloc,
        \\{"items":[{"id":"ac_new","status":"ENABLED","toolkit":{"slug":"gmail"},"last_updated_at":"2026-03-15T12:00:00Z"},{"id":"ac_exact","status":"ENABLED","toolkit":{"slug":"github"},"last_updated_at":"2026-03-14T12:00:00Z"}]}
    , "github");
    defer alloc.free(id);
    try std.testing.expectEqualStrings("ac_exact", id);
}

test "composio parseBestAuthConfigId ignores disabled entries" {
    const alloc = std.testing.allocator;
    const id = try parseBestAuthConfigId(alloc,
        \\{"items":[{"id":"ac_disabled","status":"DISABLED","toolkit":{"slug":"github"}},{"id":"ac_enabled","status":"ENABLED","toolkit":{"slug":"github"}}]}
    , "github");
    defer alloc.free(id);
    try std.testing.expectEqualStrings("ac_enabled", id);
}

test "composio parseBestAuthConfigId uses latest updated timestamp for ties" {
    const alloc = std.testing.allocator;
    const id = try parseBestAuthConfigId(alloc,
        \\{"items":[{"id":"ac_old","status":"ENABLED","toolkit":{"slug":"github"},"last_updated_at":"2026-03-14T12:00:00Z"},{"id":"ac_new","status":"ENABLED","toolkit":{"slug":"github"},"last_updated_at":"2026-03-15T12:00:00Z"}]}
    , "github");
    defer alloc.free(id);
    try std.testing.expectEqualStrings("ac_new", id);
}

test "composio parseBestAuthConfigId returns ambiguous when tie remains" {
    const alloc = std.testing.allocator;
    const result = parseBestAuthConfigId(alloc,
        \\{"items":[{"id":"ac_a","status":"ENABLED","toolkit":{"slug":"github"},"last_updated_at":"2026-03-15T12:00:00Z"},{"id":"ac_b","status":"ENABLED","toolkit":{"slug":"github"},"last_updated_at":"2026-03-15T12:00:00Z"}]}
    , "github");
    try std.testing.expectError(error.AuthConfigAmbiguous, result);
}

test "composio parseBestAuthConfigId supports direct toolkit_slug field" {
    const alloc = std.testing.allocator;
    const id = try parseBestAuthConfigId(alloc,
        \\{"items":[{"id":"ac_abc123","status":"ENABLED","toolkit_slug":"github"}]}
    , "github");
    defer alloc.free(id);
    try std.testing.expectEqualStrings("ac_abc123", id);
}

test "composio normalizeToolSlug preserves UPPER_SNAKE" {
    const alloc = std.testing.allocator;
    const result = try normalizeToolSlug(alloc, "GMAIL_FETCH_EMAILS");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("GMAIL_FETCH_EMAILS", result);
}

test "composio normalizeToolSlug trims whitespace only" {
    const alloc = std.testing.allocator;
    const result = try normalizeToolSlug(alloc, "  github-list-repos  ");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("github-list-repos", result);
}

test "composio normalizeEntityId defaults to default" {
    try std.testing.expectEqualStrings("default", normalizeEntityId(null));
    try std.testing.expectEqualStrings("default", normalizeEntityId(""));
    try std.testing.expectEqualStrings("default", normalizeEntityId("   "));
}

test "composio normalizeEntityId trims whitespace" {
    try std.testing.expectEqualStrings("workspace-user", normalizeEntityId("  workspace-user  "));
    try std.testing.expectEqualStrings("my-entity", normalizeEntityId("my-entity"));
}

test "composio resolveExecutionEntityId priority args tenant default" {
    var ct = ComposioTool{ .api_key = "test-key", .entity_id = "default-entity" };

    const parsed_args = try root.parseTestArgs("{\"action\":\"execute\",\"action_name\":\"gmail-list-labels\",\"entity_id\":\" 7 \"}");
    defer parsed_args.deinit();
    const from_args = ct.resolveExecutionEntityId(parsed_args.value.object);
    try std.testing.expectEqualStrings("7", from_args.entity_id);
    try std.testing.expectEqualStrings("args", from_args.source);

    root.setTenantContext(.{ .user_id = "42" });
    defer root.clearTenantContext();
    const parsed_tenant = try root.parseTestArgs("{\"action\":\"execute\",\"action_name\":\"gmail-list-labels\"}");
    defer parsed_tenant.deinit();
    const from_tenant = ct.resolveExecutionEntityId(parsed_tenant.value.object);
    try std.testing.expectEqualStrings("42", from_tenant.entity_id);
    try std.testing.expectEqualStrings("tenant_ctx", from_tenant.source);

    root.clearTenantContext();
    const parsed_default = try root.parseTestArgs("{\"action\":\"execute\",\"action_name\":\"gmail-list-labels\"}");
    defer parsed_default.deinit();
    const from_default = ct.resolveExecutionEntityId(parsed_default.value.object);
    try std.testing.expectEqualStrings("default-entity", from_default.entity_id);
    try std.testing.expectEqualStrings("tool_default", from_default.source);
}

test "composio extractApiErrorMessage parses message format" {
    const alloc = std.testing.allocator;
    const result = try extractApiErrorMessage(alloc, "{\"message\":\"invalid api key\"}");
    defer if (result) |r| alloc.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("invalid api key", result.?);
}

test "composio extractApiErrorMessage parses nested error format" {
    const alloc = std.testing.allocator;
    const result = try extractApiErrorMessage(alloc, "{\"error\":{\"message\":\"tool not found\"}}");
    defer if (result) |r| alloc.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("tool not found", result.?);
}

test "composio extractApiErrorMessage returns null for non-json" {
    const alloc = std.testing.allocator;
    const result = try extractApiErrorMessage(alloc, "not-json-at-all");
    try std.testing.expect(result == null);
}

test "composio sanitizeErrorMessage truncates at 240 chars" {
    const alloc = std.testing.allocator;
    // Build a message longer than 240 chars using short words (< 20 chars each)
    // so they won't be redacted. "word " is 5 chars, 60 * 5 = 300 chars.
    const long_msg = "word " ** 60;
    const result = try sanitizeErrorMessage(alloc, long_msg);
    defer alloc.free(result);
    try std.testing.expect(result.len == 243); // 240 + "..."
    try std.testing.expect(std.mem.endsWith(u8, result, "..."));
}
