//! MCP (Model Context Protocol) — server.
//!
//! Makes nullalis *be* an MCP server: it exposes nullalis's own tool
//! registry over JSON-RPC 2.0 so external MCP clients (Claude Desktop,
//! Cursor, another agent, another nullalis instance) can call nullalis
//! tools and query its memory.
//!
//! This is the inverse of `src/mcp.zig` (the MCP *client*, which spawns
//! external servers and calls *their* tools). Where the client builds
//! requests and parses responses, this server parses requests and builds
//! responses. They share the same wire format and protocol version.
//!
//! Transport: stdio (newline-delimited JSON, one message per line) — the
//! same shape `claude mcp serve` uses, so any client that can launch a
//! stdio MCP server can launch `nullalis mcp serve`.
//!
//! Entry point: `nullalis mcp serve` (see `runMcpCommand`). The stdio
//! loop runs until stdin EOF.
//!
//! Security: the exposed tool set is curated by `mcp/server_policy.zig`
//! (deny-by-default; read-mostly subset). The caller auth boundary is
//! `mcp/server_auth.zig`. See those modules for the threat model.

const std = @import("std");
const tools_mod = @import("tools/root.zig");
const config_mod = @import("config.zig");
const protocol = @import("mcp/server_protocol.zig");
const policy = @import("mcp/server_policy.zig");
const auth = @import("mcp/server_auth.zig");
const handlers = @import("mcp/server_handlers.zig");
const version = @import("version.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.mcp_server);

/// Hard cap on a single inbound JSON-RPC message. A line longer than this
/// is rejected with a parse error rather than allowed to exhaust memory —
/// an MCP server is an attack surface and unbounded reads are a DoS.
pub const max_message_bytes: usize = 4 * 1024 * 1024;

// ── Server state ────────────────────────────────────────────────

/// Live MCP server. Holds the tool registry, the resolved exposure +
/// auth policy, and the handshake state machine. One instance per
/// `nullalis mcp serve` process.
pub const Server = struct {
    allocator: Allocator,
    /// The tool registry. Borrowed — owned by the caller (`runServeCommand`).
    tools: []const tools_mod.Tool,
    /// Resolved once at startup: is the full-registry escape hatch on?
    expose_all: bool,
    /// Caller auth boundary.
    auth_config: auth.AuthConfig,
    /// Set true once a valid `initialize` request has been processed.
    /// MCP requires `initialize` before any other request.
    initialized: bool = false,
    /// Set true once the caller authenticated (via `initialize`). When
    /// `auth_config.required()` is false this is always considered true.
    authenticated: bool = false,

    pub fn init(
        allocator: Allocator,
        tools: []const tools_mod.Tool,
        expose_all: bool,
        auth_config: auth.AuthConfig,
    ) Server {
        return .{
            .allocator = allocator,
            .tools = tools,
            .expose_all = expose_all,
            .auth_config = auth_config,
        };
    }

    /// True when the caller may invoke non-handshake methods.
    fn callerAuthorized(self: *const Server) bool {
        return !self.auth_config.required() or self.authenticated;
    }

    /// Process one parsed JSON-RPC message and, for requests, produce the
    /// response line (without the trailing newline). Notifications return
    /// null (no response). The caller owns a non-null return value.
    pub fn handleMessage(self: *Server, msg: protocol.ParsedMessage) !?[]u8 {
        switch (msg.kind) {
            .notification => {
                handleNotification(msg);
                return null;
            },
            .request => return try self.handleRequest(msg),
        }
    }

    fn handleNotification(msg: protocol.ParsedMessage) void {
        // `notifications/initialized` confirms the client finished the
        // handshake. Other notifications (cancelled, progress) are accepted
        // and ignored — nullalis's server side is stateless per request.
        if (std.mem.eql(u8, msg.method, "notifications/initialized")) {
            log.debug("client sent notifications/initialized", .{});
        } else {
            log.debug("ignoring notification: {s}", .{msg.method});
        }
    }

    fn handleRequest(self: *Server, msg: protocol.ParsedMessage) !?[]u8 {
        const a = self.allocator;

        // `initialize` is the one method allowed before initialization,
        // and it carries the auth token.
        if (std.mem.eql(u8, msg.method, "initialize")) {
            return try self.handleInitialize(msg);
        }

        // Everything else requires a completed handshake.
        if (!self.initialized) {
            return try protocol.buildError(
                a,
                msg.id_int,
                msg.id_str,
                .invalid_request,
                "server not initialized — send 'initialize' first",
            );
        }

        // ...and an authorized caller.
        if (!self.callerAuthorized()) {
            return try protocol.buildError(
                a,
                msg.id_int,
                msg.id_str,
                .unauthorized,
                "unauthorized — a valid authToken is required",
            );
        }

        if (std.mem.eql(u8, msg.method, "ping")) {
            return try protocol.buildResponse(a, msg.id_int, msg.id_str, "{}");
        }

        if (std.mem.eql(u8, msg.method, "tools/list")) {
            const result = try handlers.buildToolsListResult(a, self.tools, self.expose_all);
            defer a.free(result);
            return try protocol.buildResponse(a, msg.id_int, msg.id_str, result);
        }

        if (std.mem.eql(u8, msg.method, "tools/call")) {
            const outcome = try handlers.handleToolsCall(a, self.tools, self.expose_all, msg.params);
            defer if (outcome.result_json) |r| a.free(r);
            if (outcome.err) |e| {
                return try protocol.buildError(a, msg.id_int, msg.id_str, e.code, e.message);
            }
            return try protocol.buildResponse(a, msg.id_int, msg.id_str, outcome.result_json.?);
        }

        // resources/* and prompts/* are not implemented — see PR notes.
        return try protocol.buildError(
            a,
            msg.id_int,
            msg.id_str,
            .method_not_found,
            "method not supported by nullalis MCP server",
        );
    }

    fn handleInitialize(self: *Server, msg: protocol.ParsedMessage) !?[]u8 {
        const a = self.allocator;

        // Enforce the auth boundary at the handshake. The token (if the
        // operator configured one) rides in `clientInfo.authToken`.
        if (self.auth_config.required()) {
            const presented = auth.extractTokenFromInitParams(msg.params);
            self.auth_config.verify(presented) catch {
                log.warn("rejected initialize: bad or missing authToken", .{});
                return try protocol.buildError(
                    a,
                    msg.id_int,
                    msg.id_str,
                    .unauthorized,
                    "unauthorized — clientInfo.authToken missing or invalid",
                );
            };
            self.authenticated = true;
        } else {
            self.authenticated = true;
        }

        self.initialized = true;
        log.info("MCP client initialized (authenticated={any})", .{self.authenticated});

        const result = try handlers.buildInitializeResult(a);
        defer a.free(result);
        return try protocol.buildResponse(a, msg.id_int, msg.id_str, result);
    }
};

// ── stdio transport loop ────────────────────────────────────────

/// Run the stdio JSON-RPC loop until stdin EOF. Each line is parsed,
/// dispatched, and (for requests) a response line is written to stdout.
/// Parse failures produce a JSON-RPC parse-error response with a null id.
///
/// One-message-per-line framing matches `src/mcp.zig` (the client) and
/// `claude mcp serve`. Lines exceeding `max_message_bytes` are rejected.
pub fn runStdioLoop(server: *Server) !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(server.allocator);
    var byte: [1]u8 = undefined;
    var overlong = false;

    while (true) {
        const n = stdin.read(&byte) catch |e| {
            log.err("stdin read failed: {s}", .{@errorName(e)});
            return e;
        };
        if (n == 0) {
            // EOF — process any final partial line, then exit.
            if (line_buf.items.len > 0 and !overlong) {
                try dispatchLine(server, stdout, line_buf.items);
            }
            log.info("stdin closed — MCP server shutting down", .{});
            return;
        }

        if (byte[0] == '\n') {
            if (overlong) {
                // The line we just finished skipping was too long.
                try writeLine(server.allocator, stdout, try parseErrorResponse(server.allocator));
                overlong = false;
            } else if (line_buf.items.len > 0) {
                try dispatchLine(server, stdout, line_buf.items);
            }
            line_buf.clearRetainingCapacity();
            continue;
        }
        if (byte[0] == '\r') continue; // tolerate CRLF

        if (overlong) continue; // still skipping an oversized line

        if (line_buf.items.len >= max_message_bytes) {
            log.warn("inbound message exceeds {d} bytes — rejecting", .{max_message_bytes});
            line_buf.clearRetainingCapacity();
            overlong = true;
            continue;
        }
        try line_buf.append(server.allocator, byte[0]);
    }
}

/// Parse + dispatch one complete line, writing a response if one is due.
fn dispatchLine(server: *Server, stdout: std.fs.File, line: []const u8) !void {
    const a = server.allocator;

    const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch {
        log.warn("malformed JSON on stdin — sending parse error", .{});
        try writeLine(a, stdout, try parseErrorResponse(a));
        return;
    };
    defer parsed.deinit();

    const msg = protocol.parseMessage(parsed.value) catch {
        // Valid JSON, invalid JSON-RPC. We may not have an id to echo.
        const resp = try protocol.buildError(a, null, null, .invalid_request, "not a valid JSON-RPC message");
        try writeLine(a, stdout, resp);
        return;
    };

    const response = try server.handleMessage(msg);
    if (response) |resp| {
        try writeLine(a, stdout, resp);
    }
}

/// Build a standalone parse-error response (null id). `writeLine` frees it.
fn parseErrorResponse(allocator: Allocator) ![]u8 {
    return protocol.buildError(allocator, null, null, .parse_error, "failed to parse JSON-RPC message");
}

/// Write one response line (`line` + '\n') to stdout, then free `line`
/// with the allocator that produced it. stdout writes for MCP are small
/// and infrequent; an unbuffered direct write keeps the response
/// immediately visible to the client and avoids a flush dance.
fn writeLine(allocator: Allocator, stdout: std.fs.File, line: []u8) !void {
    defer allocator.free(line);
    try stdout.writeAll(line);
    try stdout.writeAll("\n");
}

// ── Entry point: `nullalis mcp serve` ───────────────────────────

/// CLI dispatch for `nullalis mcp ...`. Currently the only subcommand is
/// `serve`. Returns a non-zero process exit on usage error.
pub fn runMcpCommand(allocator: Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len == 0 or std.mem.eql(u8, sub_args[0], "--help") or std.mem.eql(u8, sub_args[0], "-h")) {
        printUsage();
        if (sub_args.len == 0) std.process.exit(1);
        return;
    }
    if (std.mem.eql(u8, sub_args[0], "serve")) {
        return runServeCommand(allocator, sub_args[1..]);
    }
    std.debug.print("Unknown mcp subcommand: {s}\n\n", .{sub_args[0]});
    printUsage();
    std.process.exit(1);
}

fn printUsage() void {
    const usage =
        \\nullalis mcp -- expose nullalis as an MCP (Model Context Protocol) server.
        \\
        \\USAGE:
        \\  nullalis mcp serve [--expose-all]
        \\
        \\COMMANDS:
        \\  serve     Run the MCP server over stdio (JSON-RPC 2.0).
        \\
        \\OPTIONS:
        \\  --expose-all   Expose the full tool registry instead of the curated
        \\                 safe subset. Equivalent to NULLALIS_MCP_EXPOSE_ALL=1.
        \\                 Only honored for trusted-stdio deployments.
        \\
        \\ENVIRONMENT:
        \\  NULLALIS_MCP_AUTH_TOKEN          Require this token in clientInfo.authToken.
        \\  NULLALIS_INTERNAL_SERVICE_TOKEN  Fallback auth token (shared with gateway).
        \\  NULLALIS_MCP_EXPOSE_ALL=1        Expose the full tool registry.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

/// `nullalis mcp serve` — build the tool registry, resolve the policy,
/// and run the stdio loop. Stays a standalone process mode; it is NOT a
/// gateway route.
fn runServeCommand(allocator: Allocator, sub_args: []const []const u8) !void {
    var expose_all_flag = false;
    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "--expose-all")) {
            expose_all_flag = true;
        } else {
            std.debug.print("Unknown option for 'mcp serve': {s}\n\n", .{arg});
            printUsage();
            std.process.exit(1);
        }
    }

    // Load config for workspace_dir + tools_config. Fall back to the
    // current directory when there is no config so `mcp serve` works
    // zero-config.
    var cfg_opt: ?config_mod.Config = config_mod.Config.load(allocator) catch null;
    defer if (cfg_opt) |*c| c.deinit();

    const workspace_dir: []const u8 = if (cfg_opt) |c| c.workspace_dir else ".";
    const cfg_ptr: ?*const config_mod.Config = if (cfg_opt) |*c| c else null;

    // Resolve the exposure policy: CLI flag OR env var.
    const expose_all = expose_all_flag or policy.exposeAllEnabled(allocator);

    // Resolve the auth boundary.
    var weak_token = false;
    var auth_config = auth.AuthConfig.load(allocator, &weak_token);
    defer auth_config.deinit();
    if (weak_token) {
        log.warn("ignoring configured MCP auth token: shorter than {d} chars", .{auth.token_min_len});
    }

    // Build the tool registry. `tool_profile = .main` and HTTP enabled so
    // web_search / web_fetch (in the safe subset) are available. The
    // exposure policy still gates what an external caller can see/call;
    // building the full set just means the safe subset is present.
    const tools = tools_mod.allTools(allocator, workspace_dir, .{
        .tool_profile = .main,
        .config = cfg_ptr,
        .http_enabled = true,
        .tools_config = if (cfg_ptr) |c| c.tools else .{},
    }) catch |e| {
        log.err("failed to build tool registry: {s}", .{@errorName(e)});
        return e;
    };
    defer {
        for (tools) |t| t.deinit(allocator);
        allocator.free(tools);
    }

    // Startup log goes to stderr (stdout is the JSON-RPC channel — it must
    // carry nothing but protocol messages).
    log.info(
        "nullalis MCP server starting: version={s} workspace={s} expose_all={any} auth_required={any} exposed_tools~={d}",
        .{
            version.string,
            workspace_dir,
            expose_all,
            auth_config.required(),
            if (expose_all) tools.len else policy.safeSubsetCount(),
        },
    );
    if (!auth_config.required()) {
        log.warn("MCP server running WITHOUT an auth token (open stdio mode) — set NULLALIS_MCP_AUTH_TOKEN to require one", .{});
    }
    if (expose_all) {
        log.warn("MCP server exposing the FULL tool registry (includes shell/file-write/etc.) — escape hatch is active", .{});
    }

    var server = Server.init(allocator, tools, expose_all, auth_config);
    try runStdioLoop(&server);
}

// ── Tests ───────────────────────────────────────────────────────

const testing = std.testing;

// Build a Server with an empty registry and no auth, for handshake tests.
fn testServer(tools: []const tools_mod.Tool) Server {
    return Server.init(testing.allocator, tools, false, .{ .token = null, .allocator = testing.allocator });
}

fn parse(line: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
}

test "mcp_server: request before initialize is rejected" {
    var srv = testServer(&.{});
    const p = try parse(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = (try srv.handleMessage(msg)).?;
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "not initialized") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "-32600") != null);
}

test "mcp_server: initialize completes the handshake" {
    var srv = testServer(&.{});
    const p = try parse(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test"}}}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = (try srv.handleMessage(msg)).?;
    defer testing.allocator.free(resp);
    try testing.expect(srv.initialized);
    try testing.expect(std.mem.indexOf(u8, resp, "serverInfo") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "nullalis") != null);
}

test "mcp_server: notifications/initialized produces no response" {
    var srv = testServer(&.{});
    const p = try parse(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = try srv.handleMessage(msg);
    try testing.expect(resp == null);
}

test "mcp_server: tools/list after initialize returns an empty array for empty registry" {
    var srv = testServer(&.{});
    srv.initialized = true;
    srv.authenticated = true;
    const p = try parse(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = (try srv.handleMessage(msg)).?;
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"tools\":[]") != null);
}

test "mcp_server: ping after initialize returns empty result" {
    var srv = testServer(&.{});
    srv.initialized = true;
    srv.authenticated = true;
    const p = try parse(
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = (try srv.handleMessage(msg)).?;
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"result\":{}") != null);
}

test "mcp_server: unknown method after initialize is method_not_found" {
    var srv = testServer(&.{});
    srv.initialized = true;
    srv.authenticated = true;
    const p = try parse(
        \\{"jsonrpc":"2.0","id":4,"method":"resources/list"}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = (try srv.handleMessage(msg)).?;
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
}

test "mcp_server: initialize with auth required rejects a missing token" {
    var srv = Server.init(testing.allocator, &.{}, false, .{
        .token = try testing.allocator.dupe(u8, "a-long-enough-token-here"),
        .allocator = testing.allocator,
    });
    defer srv.auth_config.deinit();
    const p = try parse(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"test"}}}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = (try srv.handleMessage(msg)).?;
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "-32001") != null);
    try testing.expect(!srv.initialized);
}

test "mcp_server: initialize with auth required accepts the correct token" {
    var srv = Server.init(testing.allocator, &.{}, false, .{
        .token = try testing.allocator.dupe(u8, "a-long-enough-token-here"),
        .allocator = testing.allocator,
    });
    defer srv.auth_config.deinit();
    const p = try parse(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"test","authToken":"a-long-enough-token-here"}}}
    );
    defer p.deinit();
    const msg = try protocol.parseMessage(p.value);
    const resp = (try srv.handleMessage(msg)).?;
    defer testing.allocator.free(resp);
    try testing.expect(srv.initialized);
    try testing.expect(srv.authenticated);
    try testing.expect(std.mem.indexOf(u8, resp, "serverInfo") != null);
}

test "mcp_server: max_message_bytes is a sane DoS bound" {
    try testing.expect(max_message_bytes >= 64 * 1024);
}
