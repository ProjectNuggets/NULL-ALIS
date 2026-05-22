//! MCP (Model Context Protocol) client.
//!
//! Connects to external MCP tool servers — over stdio (child process) or
//! HTTP (Streamable HTTP / SSE) — speaks JSON-RPC 2.0, and wraps the tools
//! they expose into the agent's standard Tool vtable so the agent calls them
//! like any built-in tool. `resources` and `prompts` discovery is also
//! supported (see `listResources` / `listPrompts`).
//!
//! ── Multi-turn stability (the Sprint-2 fix) ─────────────────────
//! MCP was disabled behind `_mcp_servers_disabled_pending_stability_fix`
//! because the gateway crashed after ~5 turns with MCP active. Root cause:
//!   1. The old `readLine` returned the *first* line off the server's stdout
//!      and assumed it was the response. MCP servers legitimately interleave
//!      `notifications/*` frames (progress, logging, list_changed) with
//!      responses, so a notification got mistaken for the response and every
//!      following request read a stale, off-by-one frame. Drift compounded
//!      until a parse produced garbage and the turn loop crashed.
//!   2. `next_id += 1` and the shared stdin/stdout pipes had no concurrency
//!      guard. One `McpServer` is shared by every tool it exposes; the
//!      parallel tool dispatcher could (with a future metadata change) run
//!      two MCP calls on it at once and cross their frames.
//! The fix: id-correlated frame routing in `mcp/transport.zig` (skip
//! notifications, answer foreign server requests, return only the response
//! whose id matches) plus a per-server `Mutex` here so every JSON-RPC
//! exchange on a server is atomic end-to-end. `connect()`/`callTool()` also
//! reconnect once on a dead transport so a server crash mid-session is
//! recovered instead of poisoning the rest of the session.

const std = @import("std");
const tools_mod = @import("tools/root.zig");
const config_mod = @import("config.zig");
const json_util = @import("json_util.zig");
const version = @import("version.zig");
const transport_mod = @import("mcp/transport.zig");
const jsonrpc = @import("mcp/jsonrpc.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.mcp);

pub const McpServerConfig = config_mod.McpServerConfig;
pub const Transport = transport_mod.Transport;

// Re-export the protocol submodules so `@import("mcp.zig").jsonrpc` works and
// their tests are discovered through the lib test root.
pub const jsonrpc_mod = jsonrpc;
pub const transport = transport_mod;

/// Max attempts for a JSON-RPC exchange. One initial try + one reconnect
/// retry: enough to ride out a single server crash without masking a server
/// that is genuinely broken.
const MAX_ATTEMPTS: u32 = 2;

/// Errors surfaced by McpServer operations. Declared explicitly because
/// `connectLocked` and `exchangeLocked` are mutually recursive (reconnect
/// path), which defeats Zig's inferred-error-set resolution.
pub const McpError = error{
    TransportInit,
    ConnectFailed,
    InvalidHandshake,
    NotConnected,
    ExchangeFailed,
    InvalidJson,
    JsonRpcError,
    MissingResult,
    WriteFailed,
    ReadFailed,
    ReadTimeout,
    EndOfStream,
    EmptyResponse,
    HttpError,
    IdMismatch,
    SpawnFailed,
    OutOfMemory,
};

// ── Tool / resource / prompt definitions from a server ──────────

pub const McpToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

pub const McpResourceDef = struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8,
};

pub const McpPromptDef = struct {
    name: []const u8,
    description: []const u8,
};

// ── McpServer — one connection, transport-agnostic ──────────────

pub const McpServer = struct {
    allocator: Allocator,
    name: []const u8,
    config: McpServerConfig,
    transport: ?Transport = null,
    next_id: i64 = 1,
    /// Serializes every JSON-RPC exchange on this server. One McpServer is
    /// shared by all the tools it exposes; the agent's parallel tool
    /// dispatcher may invoke two of them concurrently. Without this lock the
    /// two exchanges interleave on one pipe and corrupt each other — the
    /// concurrency half of the multi-turn stability bug.
    mutex: std.Thread.Mutex = .{},
    /// Server-advertised capabilities, captured from the `initialize` result.
    caps: Capabilities = .{},

    pub const Capabilities = struct {
        tools: bool = false,
        resources: bool = false,
        prompts: bool = false,
    };

    pub fn init(allocator: Allocator, config: McpServerConfig) McpServer {
        return .{
            .allocator = allocator,
            .name = config.name,
            .config = config,
        };
    }

    pub fn deinit(self: *McpServer) void {
        if (self.transport) |t| {
            t.close();
            t.destroy(self.allocator);
        }
        self.transport = null;
    }

    /// Spawn/attach the transport and perform the MCP `initialize` handshake.
    pub fn connect(self: *McpServer) McpError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connectLocked();
    }

    /// Caller must hold `mutex`.
    fn connectLocked(self: *McpServer) McpError!void {
        // Drop any prior transport (reconnect path).
        if (self.transport) |t| {
            t.close();
            t.destroy(self.allocator);
            self.transport = null;
        }
        self.next_id = 1;

        const t = transport_mod.create(self.allocator, self.config) catch return error.TransportInit;
        // Publish the transport immediately so exactly one owner (the
        // errdefer below) tears it down on any failure past this point.
        // Without clearing `self.transport`, a later deinit() would close +
        // destroy an already-freed transport — a double-free.
        self.transport = t;
        errdefer {
            t.close();
            t.destroy(self.allocator);
            self.transport = null;
        }
        t.connect() catch return error.ConnectFailed;

        // initialize handshake
        const init_params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"nullalis\",\"version\":\"{s}\"}}}}",
            .{version.string},
        );
        defer self.allocator.free(init_params);

        const init_resp = self.exchangeLocked("initialize", init_params) catch return error.InvalidHandshake;
        defer self.allocator.free(init_resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, init_resp, .{}) catch
            return error.InvalidHandshake;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidHandshake;
        const result = parsed.value.object.get("result") orelse return error.InvalidHandshake;
        if (result != .object) return error.InvalidHandshake;
        _ = result.object.get("protocolVersion") orelse return error.InvalidHandshake;

        // Record which primitives the server actually advertises.
        if (result.object.get("capabilities")) |cv| {
            if (cv == .object) {
                self.caps.tools = cv.object.get("tools") != null;
                self.caps.resources = cv.object.get("resources") != null;
                self.caps.prompts = cv.object.get("prompts") != null;
            }
        }

        // `initialized` notification — no response expected.
        (self.transport.?).notify("notifications/initialized", null) catch {};
    }

    /// Send a JSON-RPC request and return the response frame. Caller holds
    /// `mutex`. Reconnects once on a dead transport (server crash recovery).
    fn exchangeLocked(self: *McpServer, method: []const u8, params: ?[]const u8) McpError![]const u8 {
        var attempt: u32 = 0;
        while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
            const t = self.transport orelse return error.NotConnected;
            const id = self.next_id;
            self.next_id += 1;
            const frame = t.request(id, method, params) catch |err| {
                // A transport failure on a non-initialize call: try one
                // reconnect. `initialize` itself never recurses here — it
                // calls exchangeLocked directly with a fresh transport.
                const is_handshake = std.mem.eql(u8, method, "initialize");
                if (!is_handshake and attempt + 1 < MAX_ATTEMPTS and isRecoverable(err)) {
                    log.warn("[{s}] {s}: {s} — reconnecting", .{ self.name, method, @errorName(err) });
                    self.connectLocked() catch return err;
                    continue;
                }
                return err;
            };
            return frame;
        }
        return error.ExchangeFailed;
    }

    fn isRecoverable(err: anyerror) bool {
        return switch (err) {
            error.NotConnected,
            error.WriteFailed,
            error.ReadFailed,
            error.EndOfStream,
            error.HttpError,
            error.EmptyResponse,
            error.IdMismatch,
            => true,
            else => false,
        };
    }

    /// Request the list of tools from the server.
    pub fn listTools(self: *McpServer) ![]McpToolDef {
        self.mutex.lock();
        defer self.mutex.unlock();
        const resp = try self.exchangeLocked("tools/list", "{}");
        defer self.allocator.free(resp);
        return try parseToolsListResponse(self.allocator, resp);
    }

    /// Request the list of resources from the server. Empty slice if the
    /// server does not advertise the `resources` capability.
    pub fn listResources(self: *McpServer) ![]McpResourceDef {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.caps.resources) return self.allocator.alloc(McpResourceDef, 0);
        const resp = try self.exchangeLocked("resources/list", "{}");
        defer self.allocator.free(resp);
        return try parseResourcesListResponse(self.allocator, resp);
    }

    /// Request the list of prompts from the server. Empty slice if the server
    /// does not advertise the `prompts` capability.
    pub fn listPrompts(self: *McpServer) ![]McpPromptDef {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.caps.prompts) return self.allocator.alloc(McpPromptDef, 0);
        const resp = try self.exchangeLocked("prompts/list", "{}");
        defer self.allocator.free(resp);
        return try parsePromptsListResponse(self.allocator, resp);
    }

    /// Read a resource by URI. Caller owns the returned text.
    pub fn readResource(self: *McpServer, uri: []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var params: std.ArrayListUnmanaged(u8) = .empty;
        defer params.deinit(self.allocator);
        try params.appendSlice(self.allocator, "{\"uri\":");
        try json_util.appendJsonString(&params, self.allocator, uri);
        try params.append(self.allocator, '}');
        const resp = try self.exchangeLocked("resources/read", params.items);
        defer self.allocator.free(resp);
        return try parseResourceReadResponse(self.allocator, resp);
    }

    /// Call a tool on the server. `args_json` is a complete JSON object.
    pub fn callTool(self: *McpServer, tool_name: []const u8, args_json: []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var params_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer params_buf.deinit(self.allocator);
        try params_buf.appendSlice(self.allocator, "{\"name\":");
        try json_util.appendJsonString(&params_buf, self.allocator, tool_name);
        try params_buf.appendSlice(self.allocator, ",\"arguments\":");
        try params_buf.appendSlice(self.allocator, args_json);
        try params_buf.append(self.allocator, '}');

        const resp = try self.exchangeLocked("tools/call", params_buf.items);
        defer self.allocator.free(resp);
        return try parseCallToolResponse(self.allocator, resp);
    }
};

// ── Response parsers ────────────────────────────────────────────

fn checkRpcError(value: std.json.Value) !void {
    if (value != .object) return error.InvalidJson;
    if (value.object.get("error")) |_| return error.JsonRpcError;
}

pub fn parseToolsListResponse(allocator: Allocator, resp: []const u8) ![]McpToolDef {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    try checkRpcError(parsed.value);
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    if (result != .object) return error.InvalidJson;
    const tools_val = result.object.get("tools") orelse return error.MissingResult;
    if (tools_val != .array) return error.InvalidJson;

    var list: std.ArrayList(McpToolDef) = .{};
    errdefer {
        for (list.items) |d| {
            allocator.free(d.name);
            allocator.free(d.description);
            allocator.free(d.input_schema);
        }
        list.deinit(allocator);
    }

    for (tools_val.array.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string) continue;

        const desc_val = item.object.get("description");
        const desc = if (desc_val) |d| (if (d == .string) d.string else "") else "";

        const schema_val = item.object.get("inputSchema");
        const schema_str = if (schema_val) |s|
            try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(s, .{})})
        else
            try allocator.dupe(u8, "{}");
        errdefer allocator.free(schema_str);

        const name_dup = try allocator.dupe(u8, name_val.string);
        errdefer allocator.free(name_dup);
        const desc_dup = try allocator.dupe(u8, desc);

        try list.append(allocator, .{
            .name = name_dup,
            .description = desc_dup,
            .input_schema = schema_str,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn parseResourcesListResponse(allocator: Allocator, resp: []const u8) ![]McpResourceDef {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    try checkRpcError(parsed.value);
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    if (result != .object) return error.InvalidJson;
    const arr = result.object.get("resources") orelse return error.MissingResult;
    if (arr != .array) return error.InvalidJson;

    var list: std.ArrayList(McpResourceDef) = .{};
    errdefer {
        for (list.items) |d| {
            allocator.free(d.uri);
            allocator.free(d.name);
            allocator.free(d.description);
            allocator.free(d.mime_type);
        }
        list.deinit(allocator);
    }

    for (arr.array.items) |item| {
        if (item != .object) continue;
        const uri_val = item.object.get("uri") orelse continue;
        if (uri_val != .string) continue;
        const name = strField(item, "name");
        const desc = strField(item, "description");
        const mime = strField(item, "mimeType");

        const uri_dup = try allocator.dupe(u8, uri_val.string);
        errdefer allocator.free(uri_dup);
        const name_dup = try allocator.dupe(u8, name);
        errdefer allocator.free(name_dup);
        const desc_dup = try allocator.dupe(u8, desc);
        errdefer allocator.free(desc_dup);
        const mime_dup = try allocator.dupe(u8, mime);

        try list.append(allocator, .{
            .uri = uri_dup,
            .name = name_dup,
            .description = desc_dup,
            .mime_type = mime_dup,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn parsePromptsListResponse(allocator: Allocator, resp: []const u8) ![]McpPromptDef {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    try checkRpcError(parsed.value);
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    if (result != .object) return error.InvalidJson;
    const arr = result.object.get("prompts") orelse return error.MissingResult;
    if (arr != .array) return error.InvalidJson;

    var list: std.ArrayList(McpPromptDef) = .{};
    errdefer {
        for (list.items) |d| {
            allocator.free(d.name);
            allocator.free(d.description);
        }
        list.deinit(allocator);
    }

    for (arr.array.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string) continue;
        const desc = strField(item, "description");

        const name_dup = try allocator.dupe(u8, name_val.string);
        errdefer allocator.free(name_dup);
        const desc_dup = try allocator.dupe(u8, desc);

        try list.append(allocator, .{ .name = name_dup, .description = desc_dup });
    }
    return list.toOwnedSlice(allocator);
}

pub fn parseResourceReadResponse(allocator: Allocator, resp: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    try checkRpcError(parsed.value);
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    if (result != .object) return error.InvalidJson;
    const contents = result.object.get("contents") orelse return error.MissingResult;
    if (contents != .array) return error.InvalidJson;

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    for (contents.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("text")) |tv| {
            if (tv == .string) {
                if (output.items.len > 0) try output.append(allocator, '\n');
                try output.appendSlice(allocator, tv.string);
            }
        }
    }
    return output.toOwnedSlice(allocator);
}

fn strField(item: std.json.Value, key: []const u8) []const u8 {
    if (item != .object) return "";
    const v = item.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

pub fn parseCallToolResponse(allocator: Allocator, resp: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    if (parsed.value.object.get("error")) |_| return error.JsonRpcError;

    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    if (result != .object) return error.InvalidJson;

    const content = result.object.get("content") orelse return error.MissingResult;
    if (content != .array) return error.InvalidJson;

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    for (content.array.items) |item| {
        if (item != .object) continue;
        const text_val = item.object.get("text") orelse continue;
        if (text_val != .string) continue;
        if (output.items.len > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, text_val.string);
    }

    // A tool may legitimately return non-text content (image/resource only).
    // Surface a marker rather than an empty string so the agent isn't misled
    // into thinking the call produced nothing.
    if (output.items.len == 0 and content.array.items.len > 0) {
        try output.appendSlice(allocator, "[MCP tool returned non-text content]");
    }

    return output.toOwnedSlice(allocator);
}

// ── McpToolWrapper — adapts an MCP tool to the Tool vtable ──────

pub const McpToolWrapper = struct {
    allocator: Allocator,
    server: *McpServer,
    owns_server: bool,
    original_name: []const u8,
    prefixed_name: []const u8,
    desc: []const u8,
    params_json: []const u8,

    const vtable = tools_mod.Tool.VTable{
        .execute = &executeImpl,
        .name = &nameImpl,
        .description = &descImpl,
        .parameters_json = &paramsImpl,
        .deinit = &deinitImpl,
    };

    pub fn tool(self: *McpToolWrapper) tools_mod.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ptr: *anyopaque, allocator: Allocator, args: tools_mod.JsonObjectMap) anyerror!tools_mod.ToolResult {
        const self: *McpToolWrapper = @ptrCast(@alignCast(ptr));
        const json_val = std.json.Value{ .object = args };
        const args_json = std.json.Stringify.valueAlloc(allocator, json_val, .{}) catch
            return tools_mod.ToolResult.fail("Failed to serialize tool arguments");
        defer allocator.free(args_json);
        const output = self.server.callTool(self.original_name, args_json) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "MCP tool '{s}' failed: {s}", .{ self.original_name, @errorName(err) }) catch
                return tools_mod.ToolResult.fail("MCP tool call failed");
            return tools_mod.ToolResult.fail(msg);
        };
        return tools_mod.ToolResult.ok(output);
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        const self: *McpToolWrapper = @ptrCast(@alignCast(ptr));
        return self.prefixed_name;
    }

    fn descImpl(ptr: *anyopaque) []const u8 {
        const self: *McpToolWrapper = @ptrCast(@alignCast(ptr));
        return self.desc;
    }

    fn paramsImpl(ptr: *anyopaque) []const u8 {
        const self: *McpToolWrapper = @ptrCast(@alignCast(ptr));
        return self.params_json;
    }

    fn deinitImpl(ptr: *anyopaque, allocator: Allocator) void {
        _ = allocator;
        const self: *McpToolWrapper = @ptrCast(@alignCast(ptr));
        const alloc = self.allocator;
        if (self.owns_server) {
            self.server.deinit();
            alloc.destroy(self.server);
        }
        alloc.free(self.original_name);
        alloc.free(self.prefixed_name);
        alloc.free(self.desc);
        alloc.free(self.params_json);
        alloc.destroy(self);
    }
};

// ── Top-level init ──────────────────────────────────────────────

/// Initialize MCP tools from config. Connects to each server, discovers its
/// tools, and returns them wrapped in the standard Tool vtable. Errors from
/// individual servers are logged and skipped — MCP is additive.
///
/// Resources and prompts are discovered too (logged for operator visibility);
/// they are not surfaced as Tool entries because they are not callable like
/// tools. A future change can expose `resources/read` as a synthetic tool.
pub fn initMcpTools(allocator: Allocator, configs: []const McpServerConfig) ![]tools_mod.Tool {
    var all_tools: std.ArrayList(tools_mod.Tool) = .{};
    errdefer {
        for (all_tools.items) |t| t.deinit(allocator);
        all_tools.deinit(allocator);
    }

    for (configs) |cfg| {
        var server = try allocator.create(McpServer);
        server.* = McpServer.init(allocator, cfg);

        server.connect() catch |err| {
            log.err("MCP server '{s}': connect failed: {s}", .{ cfg.name, @errorName(err) });
            server.deinit();
            allocator.destroy(server);
            continue;
        };

        // resources / prompts discovery — informational; failures are soft.
        if (server.caps.resources) {
            if (server.listResources()) |res| {
                defer {
                    for (res) |r| {
                        allocator.free(r.uri);
                        allocator.free(r.name);
                        allocator.free(r.description);
                        allocator.free(r.mime_type);
                    }
                    allocator.free(res);
                }
                log.info("MCP server '{s}': {d} resources advertised", .{ cfg.name, res.len });
            } else |err| {
                log.warn("MCP server '{s}': resources/list failed: {s}", .{ cfg.name, @errorName(err) });
            }
        }
        if (server.caps.prompts) {
            if (server.listPrompts()) |pr| {
                defer {
                    for (pr) |p| {
                        allocator.free(p.name);
                        allocator.free(p.description);
                    }
                    allocator.free(pr);
                }
                log.info("MCP server '{s}': {d} prompts advertised", .{ cfg.name, pr.len });
            } else |err| {
                log.warn("MCP server '{s}': prompts/list failed: {s}", .{ cfg.name, @errorName(err) });
            }
        }

        const tool_defs = server.listTools() catch |err| {
            log.err("MCP server '{s}': tools/list failed: {s}", .{ cfg.name, @errorName(err) });
            server.deinit();
            allocator.destroy(server);
            continue;
        };
        defer allocator.free(tool_defs);

        var transferred_count: usize = 0;
        errdefer {
            var i: usize = transferred_count;
            while (i < tool_defs.len) : (i += 1) {
                allocator.free(tool_defs[i].name);
                allocator.free(tool_defs[i].description);
                allocator.free(tool_defs[i].input_schema);
            }
            if (transferred_count == 0) {
                server.deinit();
                allocator.destroy(server);
            }
        }

        for (tool_defs, 0..) |td, idx| {
            var wrapper = try allocator.create(McpToolWrapper);
            errdefer allocator.destroy(wrapper);
            const prefixed_name = try std.fmt.allocPrint(allocator, "mcp_{s}_{s}", .{ cfg.name, td.name });
            errdefer allocator.free(prefixed_name);
            wrapper.* = .{
                .allocator = allocator,
                .server = server,
                .owns_server = idx == 0,
                .original_name = td.name,
                .prefixed_name = prefixed_name,
                .desc = td.description,
                .params_json = td.input_schema,
            };
            try all_tools.append(allocator, wrapper.tool());
            transferred_count += 1;
        }

        if (transferred_count == 0) {
            server.deinit();
            allocator.destroy(server);
        }

        log.info("MCP server '{s}' ({s}): {d} tools registered", .{
            cfg.name,
            @tagName(cfg.transport),
            tool_defs.len,
        });
    }

    return all_tools.toOwnedSlice(allocator);
}

// ── Tests ───────────────────────────────────────────────────────

test "McpServer init fields" {
    const cfg = McpServerConfig{
        .name = "test-server",
        .command = "/usr/bin/echo",
        .args = &.{"hello"},
        .env = &.{.{ .key = "FOO", .value = "bar" }},
    };
    const server = McpServer.init(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("test-server", server.name);
    try std.testing.expectEqual(@as(i64, 1), server.next_id);
    try std.testing.expect(server.transport == null);
    try std.testing.expectEqualStrings("/usr/bin/echo", server.config.command);
    try std.testing.expectEqual(McpServerConfig.Transport.stdio, server.config.transport);
}

test "parseToolsListResponse valid" {
    const resp =
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[
        \\  {"name":"read_file","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}
        \\]}}
    ;
    const defs = try parseToolsListResponse(std.testing.allocator, resp);
    defer {
        for (defs) |d| {
            std.testing.allocator.free(d.name);
            std.testing.allocator.free(d.description);
            std.testing.allocator.free(d.input_schema);
        }
        std.testing.allocator.free(defs);
    }
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("read_file", defs[0].name);
    try std.testing.expectEqualStrings("Read a file", defs[0].description);
    try std.testing.expect(defs[0].input_schema.len > 0);
}

test "parseToolsListResponse empty tools" {
    const resp =
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}
    ;
    const defs = try parseToolsListResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(defs);
    try std.testing.expectEqual(@as(usize, 0), defs.len);
}

test "parseToolsListResponse error" {
    const resp =
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Invalid request"}}
    ;
    try std.testing.expectError(error.JsonRpcError, parseToolsListResponse(std.testing.allocator, resp));
}

test "parseToolsListResponse tool with no inputSchema defaults" {
    const resp =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"ping","description":"x"}]}}
    ;
    const defs = try parseToolsListResponse(std.testing.allocator, resp);
    defer {
        for (defs) |d| {
            std.testing.allocator.free(d.name);
            std.testing.allocator.free(d.description);
            std.testing.allocator.free(d.input_schema);
        }
        std.testing.allocator.free(defs);
    }
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("{}", defs[0].input_schema);
}

test "parseResourcesListResponse valid" {
    const resp =
        \\{"jsonrpc":"2.0","id":4,"result":{"resources":[
        \\  {"uri":"file:///x.txt","name":"x","description":"a file","mimeType":"text/plain"}
        \\]}}
    ;
    const defs = try parseResourcesListResponse(std.testing.allocator, resp);
    defer {
        for (defs) |d| {
            std.testing.allocator.free(d.uri);
            std.testing.allocator.free(d.name);
            std.testing.allocator.free(d.description);
            std.testing.allocator.free(d.mime_type);
        }
        std.testing.allocator.free(defs);
    }
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("file:///x.txt", defs[0].uri);
    try std.testing.expectEqualStrings("text/plain", defs[0].mime_type);
}

test "parsePromptsListResponse valid" {
    const resp =
        \\{"jsonrpc":"2.0","id":5,"result":{"prompts":[{"name":"summarize","description":"sum it"}]}}
    ;
    const defs = try parsePromptsListResponse(std.testing.allocator, resp);
    defer {
        for (defs) |d| {
            std.testing.allocator.free(d.name);
            std.testing.allocator.free(d.description);
        }
        std.testing.allocator.free(defs);
    }
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("summarize", defs[0].name);
}

test "parseResourceReadResponse concatenates text contents" {
    const resp =
        \\{"jsonrpc":"2.0","id":6,"result":{"contents":[{"uri":"x","text":"line1"},{"uri":"x","text":"line2"}]}}
    ;
    const out = try parseResourceReadResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("line1\nline2", out);
}

test "parseCallToolResponse valid" {
    const resp =
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hello world"}]}}
    ;
    const output = try parseCallToolResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello world", output);
}

test "parseCallToolResponse multiple content" {
    const resp =
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"line1"},{"type":"text","text":"line2"}]}}
    ;
    const output = try parseCallToolResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("line1\nline2", output);
}

test "parseCallToolResponse non-text content yields marker" {
    const resp =
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"image","data":"base64"}]}}
    ;
    const output = try parseCallToolResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("[MCP tool returned non-text content]", output);
}

test "parseCallToolResponse error" {
    const resp =
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found"}}
    ;
    try std.testing.expectError(error.JsonRpcError, parseCallToolResponse(std.testing.allocator, resp));
}

test "parseCallToolResponse invalid json" {
    try std.testing.expectError(error.InvalidJson, parseCallToolResponse(std.testing.allocator, "not json"));
}

test "McpToolWrapper vtable name" {
    var server = McpServer.init(std.testing.allocator, .{ .name = "fs", .command = "echo" });
    var wrapper = McpToolWrapper{
        .allocator = std.testing.allocator,
        .server = &server,
        .owns_server = false,
        .original_name = "read_file",
        .prefixed_name = "mcp_fs_read_file",
        .desc = "Read a file from disk",
        .params_json = "{}",
    };
    const t = wrapper.tool();
    try std.testing.expectEqualStrings("mcp_fs_read_file", t.name());
}

test "McpToolWrapper vtable description" {
    var server = McpServer.init(std.testing.allocator, .{ .name = "fs", .command = "echo" });
    var wrapper = McpToolWrapper{
        .allocator = std.testing.allocator,
        .server = &server,
        .owns_server = false,
        .original_name = "read_file",
        .prefixed_name = "mcp_fs_read_file",
        .desc = "Read a file from disk",
        .params_json = "{}",
    };
    const t = wrapper.tool();
    try std.testing.expectEqualStrings("Read a file from disk", t.description());
}

test "McpToolWrapper vtable parameters_json" {
    var server = McpServer.init(std.testing.allocator, .{ .name = "fs", .command = "echo" });
    var wrapper = McpToolWrapper{
        .allocator = std.testing.allocator,
        .server = &server,
        .owns_server = false,
        .original_name = "read_file",
        .prefixed_name = "mcp_fs_read_file",
        .desc = "Read a file",
        .params_json = "{\"type\":\"object\"}",
    };
    const t = wrapper.tool();
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", t.parametersJson());
}

test "initMcpTools empty configs" {
    const tools = try initMcpTools(std.testing.allocator, &.{});
    defer std.testing.allocator.free(tools);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

test "isRecoverable classification" {
    try std.testing.expect(McpServer.isRecoverable(error.EndOfStream));
    try std.testing.expect(McpServer.isRecoverable(error.HttpError));
    try std.testing.expect(!McpServer.isRecoverable(error.JsonRpcError));
    try std.testing.expect(!McpServer.isRecoverable(error.OutOfMemory));
}

test "http transport config inference" {
    const cfg = McpServerConfig{ .name = "remote", .transport = .http, .url = "http://localhost:9000/mcp" };
    const server = McpServer.init(std.testing.allocator, cfg);
    try std.testing.expectEqual(McpServerConfig.Transport.http, server.config.transport);
    try std.testing.expectEqualStrings("http://localhost:9000/mcp", server.config.url);
}
