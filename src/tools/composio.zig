const std = @import("std");
const appendJsonEscaped = @import("../util.zig").appendJsonEscaped;
const root = @import("root.zig");
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

        // Try v3 first, fall back to v2
        const v3_result = try self.listActionsV3(allocator, app);
        if (v3_result.success) return v3_result;

        // Free v3 error resources before fallback
        if (v3_result.error_msg) |e| allocator.free(e);
        if (v3_result.output.len > 0) allocator.free(v3_result.output);

        return self.listActionsV2(allocator, app);
    }

    // ── v3 execute action ──────────────────────────────────────────

    fn executeActionV3(self: *ComposioTool, allocator: std.mem.Allocator, action_name: []const u8, args: JsonObjectMap, entity_id: ?[]const u8, connected_account_id: ?[]const u8) !ToolResult {
        const slug = try normalizeToolSlug(allocator, action_name);
        defer allocator.free(slug);

        var url_buf: [512]u8 = undefined;
        const url = buildExecuteToolUrlV3(&url_buf, slug) catch
            return ToolResult.fail("URL too long");

        const eid = normalizeEntityId(entity_id);

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
        try appendJsonEscaped(&out, allocator, eid);
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

    fn executeActionV2(self: *ComposioTool, allocator: std.mem.Allocator, action_name: []const u8, args: JsonObjectMap) !ToolResult {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V2 ++ "/actions/{s}/execute", .{action_name}) catch
            return ToolResult.fail("URL too long");

        // Re-serialize ObjectMap to JSON for the HTTP body
        const json_val = std.json.Value{ .object = args };
        const body = std.json.Stringify.valueAlloc(allocator, json_val, .{}) catch
            return ToolResult.fail("Failed to serialize args");
        defer allocator.free(body);

        return self.httpPost(allocator, url, body);
    }

    fn executeAction(self: *ComposioTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action_name = root.getString(args, "tool_slug") orelse
            root.getString(args, "action_name") orelse
            return ToolResult.fail("Missing 'action_name' (or 'tool_slug') for execute");

        const entity_id = root.getString(args, "entity_id");
        const connected_account_id = root.getString(args, "connected_account_id");

        // Try v3 first, fall back to v2
        const v3_result = try self.executeActionV3(allocator, action_name, args, entity_id, connected_account_id);
        if (v3_result.success) return v3_result;

        // Free v3 error resources before fallback
        if (v3_result.error_msg) |e| allocator.free(e);
        if (v3_result.output.len > 0) allocator.free(v3_result.output);

        return self.executeActionV2(allocator, action_name, args);
    }

    // ── v3 connect ─────────────────────────────────────────────────

    fn connectActionV3(self: *ComposioTool, allocator: std.mem.Allocator, entity: []const u8, auth_config_id: []const u8, args: JsonObjectMap) !ToolResult {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, COMPOSIO_API_BASE_V3 ++ "/connected_accounts/link", .{}) catch
            return ToolResult.fail("URL too long");
        const body = buildConnectBodyV3(allocator, entity, auth_config_id, args) catch
            return ToolResult.fail("Failed to build connect body");
        defer allocator.free(body);

        return self.httpPost(allocator, url, body);
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

            if (parseFirstAuthConfigId(allocator, lookup.output)) |auth_id| {
                return auth_id;
            } else |_| {}
        }

        return error.AuthConfigNotFound;
    }

    fn connectAction(self: *ComposioTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const app = root.getString(args, "app");
        const auth_config_id_in = root.getString(args, "auth_config_id");
        if (app == null and auth_config_id_in == null) {
            return ToolResult.fail("Missing 'app' or 'auth_config_id' for connect");
        }

        const entity_raw = root.getString(args, "entity_id");
        const entity = if (entity_raw) |e| e else self.entity_id;

        var auth_config_id_owned: ?[]u8 = null;
        defer if (auth_config_id_owned) |owned| allocator.free(owned);
        const auth_config_id = if (auth_config_id_in) |given|
            given
        else blk: {
            const app_name = app orelse return ToolResult.fail("Missing 'app' for connect");
            auth_config_id_owned = self.resolveAuthConfigIdV3(allocator, app_name) catch |err| {
                return switch (err) {
                    error.AuthConfigNotFound => blk_err: {
                        const msg = allocator.dupe(u8, "No v3 auth_config found for app. Pass auth_config_id explicitly.") catch
                            break :blk_err ToolResult.fail("No v3 auth_config found for app. Pass auth_config_id explicitly.");
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

        return self.connectActionV3(allocator, entity, auth_config_id, args);
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
        argv_buf[argc] = "-sL";
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

    /// Run curl as a child process and return stdout on success, stderr on failure.
    fn runCurl(_: *ComposioTool, allocator: std.mem.Allocator, argv: []const []const u8) !ToolResult {
        const proc = @import("process_util.zig");
        const result = try proc.run(allocator, argv, .{});
        defer allocator.free(result.stderr);
        if (result.success) {
            if (result.stdout.len > 0) return ToolResult{ .success = true, .output = result.stdout };
            allocator.free(result.stdout);
            return ToolResult{ .success = true, .output = try allocator.dupe(u8, "(empty response)") };
        }
        defer allocator.free(result.stdout);
        if (result.exit_code != null) {
            const err_out = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "curl failed with non-zero exit code");
            return ToolResult{ .success = false, .output = "", .error_msg = err_out };
        }
        return ToolResult{ .success = false, .output = "", .error_msg = "curl terminated by signal" };
    }
};

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

fn lowerNoSeparators(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (input) |c| {
        if (c == '-' or c == '_' or c == ' ') continue;
        try out.append(allocator, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(allocator);
}

fn parseFirstAuthConfigId(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const obj = parsed.value.object;

    if (extractAuthConfigIdFromObject(allocator, obj)) |id| return id else |_| {}

    const list_fields = [_][]const u8{ "items", "data", "results", "auth_configs" };
    for (list_fields) |field| {
        const list_val = obj.get(field) orelse continue;
        if (list_val != .array) continue;
        for (list_val.array.items) |item| {
            if (item != .object) continue;
            if (extractAuthConfigIdFromObject(allocator, item.object)) |id| return id else |_| {}
        }
    }

    return error.AuthConfigNotFound;
}

fn extractAuthConfigIdFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    if (obj.get("status")) |status_val| {
        if (status_val == .string and std.ascii.eqlIgnoreCase(status_val.string, "DISABLED")) {
            return error.AuthConfigDisabled;
        }
    }
    const id_fields = [_][]const u8{ "id", "auth_config_id", "authConfigId", "nanoid" };
    for (id_fields) |field| {
        const id_val = obj.get(field) orelse continue;
        if (id_val == .string and id_val.string.len > 0) {
            return allocator.dupe(u8, id_val.string);
        }
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

test "composio lowerNoSeparators normalizes toolkit slug variants" {
    const alloc = std.testing.allocator;
    const normalized = try lowerNoSeparators(alloc, "Google-Drive");
    defer alloc.free(normalized);
    try std.testing.expectEqualStrings("googledrive", normalized);
}

test "composio parseFirstAuthConfigId reads id from items payload" {
    const alloc = std.testing.allocator;
    const id = try parseFirstAuthConfigId(alloc,
        \\{"items":[{"id":"ac_abc123","status":"ENABLED"}]}
    );
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
