//! Web Search Tool — internet search via Exa and Brave APIs.
//!
//! Provider selection is controlled by tools.web_search_provider or WEB_SEARCH_PROVIDER:
//! - auto (default): Exa first when EXA_API_KEY is set, fallback to Brave
//! - exa: Exa only
//! - brave: Brave only
//! If the selected mode lacks its API key, runtime falls back to the other provider when possible.

const std = @import("std");
const root = @import("root.zig");
const platform = @import("../platform.zig");
const http_util = @import("../root.zig").http_util;
const net_security = @import("../root.zig").net_security;
const json_util = @import("../json_util.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Maximum number of search results.
const MAX_RESULTS: usize = 10;
/// Default number of search results.
const DEFAULT_COUNT: usize = 5;
/// Max snippet length in formatted output.
const MAX_SNIPPET_CHARS: usize = 280;

const EXA_BASE_URL = "https://api.exa.ai/search";
const EXA_HOST = "api.exa.ai";
const BRAVE_BASE_URL = "https://api.search.brave.com/res/v1/web/search";
const BRAVE_HOST = "api.search.brave.com";

const ENV_PROVIDER = "WEB_SEARCH_PROVIDER";
const ENV_EXA_API_KEY = "EXA_API_KEY";
const ENV_BRAVE_API_KEY = "BRAVE_API_KEY";

const SearchProviderMode = enum {
    auto,
    exa,
    brave,
};

const ResolvedApiKey = struct {
    value: []const u8,
    owned: bool = false,
};

const ExaAttempt = union(enum) {
    success: ToolResult,
    fallbackable_error: []u8,
    fatal_error: []u8,
};

/// Web search tool using Exa/Brave APIs.
pub const WebSearchTool = struct {
    /// Optional config override from tools.web_search_provider.
    /// Empty means: use WEB_SEARCH_PROVIDER env selection.
    provider_mode_override: []const u8 = "",
    /// Optional config override from tools.web_search_exa_api_key.
    /// Empty means: use EXA_API_KEY env resolution.
    exa_api_key_override: []const u8 = "",
    /// Optional config override from tools.web_search_brave_api_key.
    /// Empty means: use BRAVE_API_KEY env resolution.
    brave_api_key_override: []const u8 = "",

    pub const tool_name = "web_search";
    pub const tool_description = "Search the open web for external facts. Prefer `http_request` for known APIs and `runtime_info` for local runtime truth.";
    pub const tool_params =
        \\{"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"Search query"},"count":{"type":"integer","minimum":1,"maximum":10,"default":5,"description":"Number of results (1-10)"}},"required":["query"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *WebSearchTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *WebSearchTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing required 'query' parameter");

        if (std.mem.trim(u8, query, " \t\n\r").len == 0)
            return ToolResult.fail("'query' must not be empty");

        const count = parseCount(args);
        const mode = resolveProviderMode(self.provider_mode_override, allocator);
        return switch (mode) {
            .auto => executeAutoMode(allocator, query, count, self.exa_api_key_override, self.brave_api_key_override),
            .exa => executeExaMode(allocator, query, count, self.exa_api_key_override, self.brave_api_key_override),
            .brave => executeBraveMode(allocator, query, count, self.brave_api_key_override, self.exa_api_key_override),
        };
    }
};

/// Parse count from args ObjectMap. Returns DEFAULT_COUNT if not found or invalid.
fn parseCount(args: JsonObjectMap) usize {
    const val_i64 = root.getInt(args, "count") orelse return DEFAULT_COUNT;
    if (val_i64 < 1) return 1;
    const val: usize = if (val_i64 > @as(i64, @intCast(MAX_RESULTS))) MAX_RESULTS else @intCast(val_i64);
    return val;
}

/// URL-encode a string (percent-encoding).
pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else if (c == ' ') {
            try buf.append(allocator, '+');
        } else {
            try buf.appendSlice(allocator, &.{ '%', hexDigit(c >> 4), hexDigit(c & 0x0f) });
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn hexDigit(v: u8) u8 {
    return "0123456789ABCDEF"[v & 0x0f];
}

fn resolveProviderMode(provider_mode_override: []const u8, allocator: std.mem.Allocator) SearchProviderMode {
    const trimmed_override = std.mem.trim(u8, provider_mode_override, " \t\r\n");
    if (trimmed_override.len > 0) return parseProviderMode(trimmed_override);

    const raw = platform.getEnvOrNull(allocator, ENV_PROVIDER) orelse return .auto;
    defer allocator.free(raw);
    return parseProviderMode(raw);
}

fn parseProviderMode(raw: []const u8) SearchProviderMode {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .auto;
    if (std.ascii.eqlIgnoreCase(trimmed, "exa")) return .exa;
    if (std.ascii.eqlIgnoreCase(trimmed, "brave")) return .brave;
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return .auto;
    return .auto;
}

fn getTrimmedEnvOrNull(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    const raw = platform.getEnvOrNull(allocator, key) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return @constCast(raw);
    const out = allocator.dupe(u8, trimmed) catch {
        allocator.free(raw);
        return null;
    };
    allocator.free(raw);
    return out;
}

fn resolveApiKey(allocator: std.mem.Allocator, configured_key: []const u8, env_key: []const u8) ?ResolvedApiKey {
    const configured_trimmed = std.mem.trim(u8, configured_key, " \t\r\n");
    if (configured_trimmed.len > 0) {
        return .{ .value = configured_trimmed, .owned = false };
    }
    const env_val = getTrimmedEnvOrNull(allocator, env_key) orelse return null;
    return .{ .value = env_val, .owned = true };
}

fn freeResolvedApiKey(allocator: std.mem.Allocator, key: ?ResolvedApiKey) void {
    if (key) |k| {
        if (k.owned) allocator.free(k.value);
    }
}

fn exaStatusAllowsFallback(status_code: u16) bool {
    return status_code == 429 or status_code >= 500;
}

fn preferredAutoProvider(has_exa: bool, has_brave: bool) ?SearchProviderMode {
    if (has_exa) return .exa;
    if (has_brave) return .brave;
    return null;
}

fn executeAutoMode(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    exa_key_override: []const u8,
    brave_key_override: []const u8,
) !ToolResult {
    const exa_key = resolveApiKey(allocator, exa_key_override, ENV_EXA_API_KEY);
    defer freeResolvedApiKey(allocator, exa_key);

    const brave_key = resolveApiKey(allocator, brave_key_override, ENV_BRAVE_API_KEY);
    defer freeResolvedApiKey(allocator, brave_key);

    const preferred = preferredAutoProvider(exa_key != null, brave_key != null) orelse
        return ToolResult.fail("No search provider configured. Set tools.web_search_exa_api_key/tools.web_search_brave_api_key or EXA_API_KEY/BRAVE_API_KEY.");

    if (preferred == .exa) {
        const exa_attempt = try tryExaSearch(allocator, query, count, exa_key.?.value);
        switch (exa_attempt) {
            .success => |result| return result,
            .fatal_error => |msg| return .{ .success = false, .output = "", .error_msg = msg },
            .fallbackable_error => |msg| {
                defer allocator.free(msg);
                if (brave_key) |key| return executeBraveSearchWithKey(allocator, query, count, key.value);
                const err_msg = try std.fmt.allocPrint(
                    allocator,
                    "Exa search failed ({s}) and Brave key is not set for fallback.",
                    .{msg},
                );
                return .{ .success = false, .output = "", .error_msg = err_msg };
            },
        }
    }

    return executeBraveSearchWithKey(allocator, query, count, brave_key.?.value);
}

fn executeExaMode(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    exa_key_override: []const u8,
    brave_key_override: []const u8,
) !ToolResult {
    const exa_key = resolveApiKey(allocator, exa_key_override, ENV_EXA_API_KEY);
    defer freeResolvedApiKey(allocator, exa_key);
    if (exa_key) |key| {
        const exa_attempt = try tryExaSearch(allocator, query, count, key.value);
        return switch (exa_attempt) {
            .success => |result| result,
            .fallbackable_error => |msg| .{ .success = false, .output = "", .error_msg = msg },
            .fatal_error => |msg| .{ .success = false, .output = "", .error_msg = msg },
        };
    }

    const brave_key = resolveApiKey(allocator, brave_key_override, ENV_BRAVE_API_KEY);
    defer freeResolvedApiKey(allocator, brave_key);
    if (brave_key) |key| return executeBraveSearchWithKey(allocator, query, count, key.value);

    return ToolResult.fail("Exa key not set. Configure tools.web_search_exa_api_key or EXA_API_KEY.");
}

fn executeBraveMode(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    brave_key_override: []const u8,
    exa_key_override: []const u8,
) !ToolResult {
    const brave_key = resolveApiKey(allocator, brave_key_override, ENV_BRAVE_API_KEY);
    defer freeResolvedApiKey(allocator, brave_key);
    if (brave_key) |key| return executeBraveSearchWithKey(allocator, query, count, key.value);

    const exa_key = resolveApiKey(allocator, exa_key_override, ENV_EXA_API_KEY);
    defer freeResolvedApiKey(allocator, exa_key);
    if (exa_key) |key| {
        const exa_attempt = try tryExaSearch(allocator, query, count, key.value);
        return switch (exa_attempt) {
            .success => |result| result,
            .fallbackable_error => |msg| .{ .success = false, .output = "", .error_msg = msg },
            .fatal_error => |msg| .{ .success = false, .output = "", .error_msg = msg },
        };
    }

    return ToolResult.fail("Brave key not set. Configure tools.web_search_brave_api_key or BRAVE_API_KEY. Get a free key at https://brave.com/search/api/");
}

fn executeBraveSearchWithKey(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    brave_api_key: []const u8,
) !ToolResult {
    const encoded_query = try urlEncode(allocator, query);
    defer allocator.free(encoded_query);

    const url_str = try std.fmt.allocPrint(
        allocator,
        "{s}?q={s}&count={d}",
        .{ BRAVE_BASE_URL, encoded_query, count },
    );
    defer allocator.free(url_str);

    const auth_header = try std.fmt.allocPrint(allocator, "X-Subscription-Token: {s}", .{brave_api_key});
    defer allocator.free(auth_header);

    const headers = [_][]const u8{
        auth_header,
        "Accept: application/json",
    };

    const connect_host = net_security.resolveConnectHost(allocator, BRAVE_HOST, 443) catch
        return ToolResult.fail("Unable to verify Brave Search host safety");
    defer allocator.free(connect_host);

    const response = http_util.request_with_mode(
        allocator,
        // Keep search on curl transport for runtime stability.
        .{ .mode = .curl_only },
        .{
            .method = "GET",
            .url = url_str,
            .headers = &headers,
            .timeout_ms = 20_000,
            .subsystem = .tools,
            .resolve_host = BRAVE_HOST,
            .resolve_port = 443,
            .connect_host = connect_host,
        },
    ) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Brave search request failed: {}", .{err});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(response.body);

    if (response.status_code != 200) {
        const msg = try std.fmt.allocPrint(allocator, "Brave Search API returned HTTP {d}", .{response.status_code});
        return .{ .success = false, .output = "", .error_msg = msg };
    }

    return formatBraveResults(allocator, response.body, query);
}

fn buildExaSearchBody(allocator: std.mem.Allocator, query: []const u8, count: usize) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.append(allocator, '{');
    try json_util.appendJsonKey(&body, allocator, "query");
    try json_util.appendJsonString(&body, allocator, query);
    try body.append(allocator, ',');
    try json_util.appendJsonKey(&body, allocator, "type");
    try json_util.appendJsonString(&body, allocator, "auto");
    try body.append(allocator, ',');
    try json_util.appendJsonInt(&body, allocator, "numResults", @intCast(count));
    try body.append(allocator, '}');

    return body.toOwnedSlice(allocator);
}

fn tryExaSearch(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    exa_api_key: []const u8,
) !ExaAttempt {
    const request_body = try buildExaSearchBody(allocator, query, count);
    defer allocator.free(request_body);

    const auth_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{exa_api_key});
    defer allocator.free(auth_header);
    const headers = [_][]const u8{
        auth_header,
        "Content-Type: application/json",
        "Accept: application/json",
    };

    const connect_host = net_security.resolveConnectHost(allocator, EXA_HOST, 443) catch
        return .{ .fatal_error = try allocator.dupe(u8, "Unable to verify Exa host safety") };
    defer allocator.free(connect_host);

    const response = http_util.request_with_mode(
        allocator,
        // Keep search on curl transport for runtime stability.
        .{ .mode = .curl_only },
        .{
            .method = "POST",
            .url = EXA_BASE_URL,
            .body = request_body,
            .headers = &headers,
            .timeout_ms = 20_000,
            .subsystem = .tools,
            .resolve_host = EXA_HOST,
            .resolve_port = 443,
            .connect_host = connect_host,
        },
    ) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Exa search request failed: {}", .{err});
        return .{ .fallbackable_error = msg };
    };
    defer allocator.free(response.body);

    if (response.status_code != 200) {
        const msg = try std.fmt.allocPrint(allocator, "Exa Search API returned HTTP {d}", .{response.status_code});
        if (exaStatusAllowsFallback(response.status_code)) {
            return .{ .fallbackable_error = msg };
        }
        return .{ .fatal_error = msg };
    }

    const parsed = try formatExaResults(allocator, response.body, query);
    if (!parsed.success) {
        const reason = parsed.error_msg orelse "unknown parse error";
        const msg = try std.fmt.allocPrint(allocator, "Exa response parse failed: {s}", .{reason});
        return .{ .fallbackable_error = msg };
    }
    return .{ .success = parsed };
}

/// Parse Brave Search JSON and format as text results.
pub fn formatBraveResults(allocator: std.mem.Allocator, json_body: []const u8, query: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch
        return ToolResult.fail("Failed to parse search response JSON");
    defer parsed.deinit();

    const root_val = switch (parsed.value) {
        .object => |o| o,
        else => return ToolResult.fail("Unexpected search response format"),
    };

    // Extract web results
    const web = root_val.get("web") orelse
        return ToolResult.ok("No web results found.");

    const web_obj = switch (web) {
        .object => |o| o,
        else => return ToolResult.ok("No web results found."),
    };

    const results = web_obj.get("results") orelse
        return ToolResult.ok("No web results found.");

    const results_arr = switch (results) {
        .array => |a| a,
        else => return ToolResult.ok("No web results found."),
    };

    if (results_arr.items.len == 0)
        return ToolResult.ok("No web results found.");

    return formatSearchResults(allocator, query, results_arr.items, "title", "url", "description");
}

/// Parse Exa Search JSON and format as text results.
pub fn formatExaResults(allocator: std.mem.Allocator, json_body: []const u8, query: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch
        return ToolResult.fail("Failed to parse search response JSON");
    defer parsed.deinit();

    const root_val = switch (parsed.value) {
        .object => |o| o,
        else => return ToolResult.fail("Unexpected search response format"),
    };

    const results_val = root_val.get("results") orelse
        return ToolResult.ok("No web results found.");
    const results_arr = switch (results_val) {
        .array => |a| a,
        else => return ToolResult.ok("No web results found."),
    };
    if (results_arr.items.len == 0) return ToolResult.ok("No web results found.");

    // Format results
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try std.fmt.format(buf.writer(allocator), "Results for: {s}\n\n", .{query});

    var rank: usize = 0;
    for (results_arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const title = extractString(obj, "title") orelse "(no title)";
        const url = extractString(obj, "url") orelse "(no url)";
        const desc = exaResultDescription(obj) orelse "";

        rank += 1;
        try appendFormattedResult(buf.writer(allocator), rank, title, url, desc);
    }

    if (rank == 0) return ToolResult.ok("No web results found.");
    return ToolResult.ok(try buf.toOwnedSlice(allocator));
}

fn formatSearchResults(
    allocator: std.mem.Allocator,
    query: []const u8,
    items: []const std.json.Value,
    title_key: []const u8,
    url_key: []const u8,
    desc_key: []const u8,
) !ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try std.fmt.format(buf.writer(allocator), "Results for: {s}\n\n", .{query});

    var rank: usize = 0;
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const title = extractString(obj, title_key) orelse "(no title)";
        const url = extractString(obj, url_key) orelse "(no url)";
        const desc = extractString(obj, desc_key) orelse "";

        rank += 1;
        try appendFormattedResult(buf.writer(allocator), rank, title, url, desc);
    }

    if (rank == 0) return ToolResult.ok("No web results found.");
    return ToolResult.ok(try buf.toOwnedSlice(allocator));
}

fn appendFormattedResult(writer: anytype, rank: usize, title: []const u8, url: []const u8, desc: []const u8) !void {
    try std.fmt.format(writer, "{d}. {s}\n   {s}\n", .{ rank, title, url });
    if (desc.len > 0) {
        const snippet = std.mem.trim(u8, desc, " \t\r\n");
        if (snippet.len > MAX_SNIPPET_CHARS) {
            try std.fmt.format(writer, "   {s}...\n", .{snippet[0..MAX_SNIPPET_CHARS]});
        } else {
            try std.fmt.format(writer, "   {s}\n", .{snippet});
        }
    }
    try writer.writeByte('\n');
}

fn exaResultDescription(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("highlights")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item == .string and item.string.len > 0) return item.string;
            }
        }
    }
    if (extractString(obj, "summary")) |value| return value;
    if (extractString(obj, "text")) |value| return value;
    if (extractString(obj, "snippet")) |value| return value;
    return null;
}

fn extractString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "WebSearchTool name and description" {
    var wst = WebSearchTool{};
    const t = wst.tool();
    try testing.expectEqualStrings("web_search", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "WebSearchTool missing query fails" {
    var wst = WebSearchTool{};
    const parsed = try root.parseTestArgs("{\"count\":5}");
    defer parsed.deinit();
    const result = try wst.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing required 'query' parameter", result.error_msg.?);
}

test "WebSearchTool empty query fails" {
    var wst = WebSearchTool{};
    const parsed = try root.parseTestArgs("{\"query\":\"  \"}");
    defer parsed.deinit();
    const result = try wst.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("'query' must not be empty", result.error_msg.?);
}

test "WebSearchTool no API key fails with helpful message" {
    // This test relies on EXA_API_KEY and BRAVE_API_KEY not being set in test env.
    // If it is set, the test would try to make a real request
    if (platform.getEnvOrNull(testing.allocator, ENV_BRAVE_API_KEY)) |k| {
        testing.allocator.free(k);
        return;
    }
    if (platform.getEnvOrNull(testing.allocator, ENV_EXA_API_KEY)) |k| {
        testing.allocator.free(k);
        return;
    }
    var wst = WebSearchTool{};
    const parsed = try root.parseTestArgs("{\"query\":\"zig programming\"}");
    defer parsed.deinit();
    const result = try wst.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "web_search_exa_api_key") != null or std.mem.indexOf(u8, result.error_msg.?, "web_search_brave_api_key") != null);
}

test "resolveApiKey prefers configured value and trims whitespace" {
    const resolved = resolveApiKey(testing.allocator, "  exa-config-key \n", "NULLALIS_TEST_KEY_NOT_SET") orelse return error.TestUnexpectedResult;
    defer if (resolved.owned) testing.allocator.free(resolved.value);
    try testing.expectEqualStrings("exa-config-key", resolved.value);
    try testing.expect(!resolved.owned);
}

test "parseCount defaults to 5" {
    const p1 = try root.parseTestArgs("{}");
    defer p1.deinit();
    try testing.expectEqual(@as(usize, DEFAULT_COUNT), parseCount(p1.value.object));
    const p2 = try root.parseTestArgs("{\"query\":\"test\"}");
    defer p2.deinit();
    try testing.expectEqual(@as(usize, DEFAULT_COUNT), parseCount(p2.value.object));
}

test "parseCount clamps to range" {
    const p1 = try root.parseTestArgs("{\"count\":0}");
    defer p1.deinit();
    try testing.expectEqual(@as(usize, 1), parseCount(p1.value.object));
    const p2 = try root.parseTestArgs("{\"count\":100}");
    defer p2.deinit();
    try testing.expectEqual(@as(usize, MAX_RESULTS), parseCount(p2.value.object));
    const p3 = try root.parseTestArgs("{\"count\":3}");
    defer p3.deinit();
    try testing.expectEqual(@as(usize, 3), parseCount(p3.value.object));
}

test "urlEncode basic" {
    const encoded = try urlEncode(testing.allocator, "hello world");
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("hello+world", encoded);
}

test "urlEncode special chars" {
    const encoded = try urlEncode(testing.allocator, "a&b=c");
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("a%26b%3Dc", encoded);
}

test "urlEncode passthrough" {
    const encoded = try urlEncode(testing.allocator, "simple-test_123.txt~");
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("simple-test_123.txt~", encoded);
}

test "formatBraveResults parses valid JSON" {
    const json =
        \\{"web":{"results":[
        \\  {"title":"Zig Language","url":"https://ziglang.org","description":"Zig is a systems language."},
        \\  {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","description":"Source code."}
        \\]}}
    ;
    const result = try formatBraveResults(testing.allocator, json, "zig programming");
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "Results for: zig programming") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "1. Zig Language") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "https://ziglang.org") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "2. Zig GitHub") != null);
}

test "formatBraveResults empty results" {
    const json = "{\"web\":{\"results\":[]}}";
    const result = try formatBraveResults(testing.allocator, json, "nothing");
    try testing.expect(result.success);
    try testing.expectEqualStrings("No web results found.", result.output);
}

test "formatBraveResults no web key" {
    const json = "{\"query\":{\"original\":\"test\"}}";
    const result = try formatBraveResults(testing.allocator, json, "test");
    try testing.expect(result.success);
    try testing.expectEqualStrings("No web results found.", result.output);
}

test "formatBraveResults invalid JSON" {
    const result = try formatBraveResults(testing.allocator, "not json", "q");
    try testing.expect(!result.success);
}

test "parseProviderMode supports known values and defaults" {
    try testing.expectEqual(SearchProviderMode.auto, parseProviderMode(""));
    try testing.expectEqual(SearchProviderMode.auto, parseProviderMode("AUTO"));
    try testing.expectEqual(SearchProviderMode.exa, parseProviderMode("exa"));
    try testing.expectEqual(SearchProviderMode.exa, parseProviderMode(" ExA "));
    try testing.expectEqual(SearchProviderMode.brave, parseProviderMode("brave"));
    try testing.expectEqual(SearchProviderMode.auto, parseProviderMode("unknown"));
}

test "resolveProviderMode prefers config override over env" {
    try testing.expectEqual(SearchProviderMode.exa, resolveProviderMode("exa", testing.allocator));
    try testing.expectEqual(SearchProviderMode.brave, resolveProviderMode("brave", testing.allocator));
    try testing.expectEqual(SearchProviderMode.auto, resolveProviderMode("auto", testing.allocator));
}

test "preferredAutoProvider selection" {
    try testing.expectEqual(@as(?SearchProviderMode, .exa), preferredAutoProvider(true, true));
    try testing.expectEqual(@as(?SearchProviderMode, .exa), preferredAutoProvider(true, false));
    try testing.expectEqual(@as(?SearchProviderMode, .brave), preferredAutoProvider(false, true));
    try testing.expectEqual(@as(?SearchProviderMode, null), preferredAutoProvider(false, false));
}

test "exaStatusAllowsFallback decision matrix" {
    try testing.expect(exaStatusAllowsFallback(429));
    try testing.expect(exaStatusAllowsFallback(500));
    try testing.expect(exaStatusAllowsFallback(503));
    try testing.expect(!exaStatusAllowsFallback(400));
    try testing.expect(!exaStatusAllowsFallback(401));
    try testing.expect(!exaStatusAllowsFallback(403));
}

test "buildExaSearchBody escapes query and sets count" {
    const body = try buildExaSearchBody(testing.allocator, "zig \"lang\"", 7);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"query\":\"zig \\\"lang\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"numResults\":7") != null);
}

test "formatExaResults parses valid JSON" {
    const json =
        \\{"results":[
        \\  {"title":"Exa One","url":"https://exa.ai/one","highlights":["first highlight"],"text":"ignored"},
        \\  {"title":"Exa Two","url":"https://exa.ai/two","text":"full text snippet"}
        \\]}
    ;
    const result = try formatExaResults(testing.allocator, json, "exa query");
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "Results for: exa query") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "1. Exa One") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "first highlight") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "2. Exa Two") != null);
}

test "formatExaResults empty results" {
    const json = "{\"results\":[]}";
    const result = try formatExaResults(testing.allocator, json, "none");
    try testing.expect(result.success);
    try testing.expectEqualStrings("No web results found.", result.output);
}

test "formatExaResults invalid JSON" {
    const result = try formatExaResults(testing.allocator, "invalid json", "q");
    try testing.expect(!result.success);
}
