//! MCP client — live integration test against a real MCP server.
//!
//! Drives the *actual* `McpServer` client against the reference
//! `@modelcontextprotocol/server-everything`, which exposes tools, resources,
//! and prompts and emits its own notifications — exactly the conditions that
//! triggered the multi-turn stability bug.
//!
//! Two tests:
//!   * stdio transport — connect/initialize, tools/list, EIGHT consecutive
//!     tools/call (the bug crashed the gateway after ~5 turns; this is the
//!     regression pin for the id-correlated framing fix), resources/list,
//!     prompts/list.
//!   * http transport — same, against a Streamable HTTP server; proves the
//!     `Mcp-Session-Id` header is captured on `initialize` and echoed on
//!     every later request (the server rejects requests that omit it).
//!
//! Opt-in: needs `npx` on PATH (and network for the first run), so it is NOT
//! part of the canonical `zig build test` gate's real exercise. Run with:
//!   NULLALIS_MCP_LIVE_TEST=1 zig build test-mcp-live
//! For the HTTP test, first start a server:
//!   npx -y @modelcontextprotocol/server-everything streamableHttp
//! Without the env var both tests are no-op passes, so the step is always
//! safe to depend on.

const std = @import("std");
const nullalis = @import("nullalis");
const mcp = nullalis.mcp;

fn liveEnabled() bool {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, "NULLALIS_MCP_LIVE_TEST") catch return false;
    defer std.heap.page_allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

test "live MCP server: multi-turn stability over stdio" {
    if (!liveEnabled()) {
        std.debug.print("[mcp-live] skipped (set NULLALIS_MCP_LIVE_TEST=1 to run)\n", .{});
        return;
    }
    const allocator = std.testing.allocator;

    var server = mcp.McpServer.init(allocator, .{
        .name = "everything",
        .transport = .stdio,
        .command = "npx",
        .args = &.{ "-y", "@modelcontextprotocol/server-everything" },
        // The server's first npx run may fetch the package — generous budget.
        .read_line_timeout_secs = 120,
    });
    defer server.deinit();

    try server.connect();
    std.debug.print("[mcp-live] connected; caps: tools={} resources={} prompts={}\n", .{
        server.caps.tools, server.caps.resources, server.caps.prompts,
    });
    try std.testing.expect(server.caps.tools);

    const tools = try server.listTools();
    defer {
        for (tools) |t| {
            allocator.free(t.name);
            allocator.free(t.description);
            allocator.free(t.input_schema);
        }
        allocator.free(tools);
    }
    std.debug.print("[mcp-live] tools/list: {d} tools\n", .{tools.len});
    try std.testing.expect(tools.len > 0);

    // EIGHT consecutive tool calls — the regression pin. The reference
    // server's `echo` tool returns the input back; we assert each turn's
    // marker survives so a single off-by-one frame would be caught.
    var turn: u32 = 1;
    while (turn <= 8) : (turn += 1) {
        const args = try std.fmt.allocPrint(allocator, "{{\"message\":\"turn-{d}\"}}", .{turn});
        defer allocator.free(args);
        const out = try server.callTool("echo", args);
        defer allocator.free(out);
        const marker = try std.fmt.allocPrint(allocator, "turn-{d}", .{turn});
        defer allocator.free(marker);
        if (std.mem.indexOf(u8, out, marker) == null) {
            std.debug.print("[mcp-live] FAIL turn {d}: expected '{s}' in '{s}'\n", .{ turn, marker, out });
            return error.MultiTurnDrift;
        }
    }
    std.debug.print("[mcp-live] 8 consecutive tools/call OK — no frame drift\n", .{});

    if (server.caps.resources) {
        const res = try server.listResources();
        defer {
            for (res) |r| {
                allocator.free(r.uri);
                allocator.free(r.name);
                allocator.free(r.description);
                allocator.free(r.mime_type);
            }
            allocator.free(res);
        }
        std.debug.print("[mcp-live] resources/list: {d} resources\n", .{res.len});
    }

    if (server.caps.prompts) {
        const prompts = try server.listPrompts();
        defer {
            for (prompts) |p| {
                allocator.free(p.name);
                allocator.free(p.description);
            }
            allocator.free(prompts);
        }
        std.debug.print("[mcp-live] prompts/list: {d} prompts\n", .{prompts.len});
    }

    std.debug.print("[mcp-live] PASS\n", .{});
}

test "live MCP server: HTTP transport with session id" {
    if (!liveEnabled()) {
        std.debug.print("[mcp-live-http] skipped (set NULLALIS_MCP_LIVE_TEST=1 to run)\n", .{});
        return;
    }
    // Requires a Streamable HTTP MCP server already listening, e.g.:
    //   npx -y @modelcontextprotocol/server-everything streamableHttp
    // Skipped (not failed) when nothing answers on the URL, so the suite
    // stays green when only the stdio server is available.
    const default_url = "http://localhost:3001/mcp";
    const url = std.process.getEnvVarOwned(std.heap.page_allocator, "NULLALIS_MCP_HTTP_URL") catch default_url;
    defer if (url.ptr != default_url.ptr) std.heap.page_allocator.free(url);

    const allocator = std.testing.allocator;
    var server = mcp.McpServer.init(allocator, .{
        .name = "everything-http",
        .transport = .http,
        .url = url,
        .read_line_timeout_secs = 30,
    });
    defer server.deinit();

    server.connect() catch |err| {
        std.debug.print("[mcp-live-http] no HTTP server at {s} ({s}) — skipping\n", .{ url, @errorName(err) });
        return;
    };
    std.debug.print("[mcp-live-http] connected; caps: tools={}\n", .{server.caps.tools});

    const tools = try server.listTools();
    defer {
        for (tools) |t| {
            allocator.free(t.name);
            allocator.free(t.description);
            allocator.free(t.input_schema);
        }
        allocator.free(tools);
    }
    std.debug.print("[mcp-live-http] tools/list: {d} tools\n", .{tools.len});
    try std.testing.expect(tools.len > 0);

    // Multi-turn over HTTP — every request must carry the captured
    // Mcp-Session-Id or the server rejects it ("Server not initialized").
    var turn: u32 = 1;
    while (turn <= 5) : (turn += 1) {
        const args = try std.fmt.allocPrint(allocator, "{{\"message\":\"http-{d}\"}}", .{turn});
        defer allocator.free(args);
        const out = try server.callTool("echo", args);
        defer allocator.free(out);
        const marker = try std.fmt.allocPrint(allocator, "http-{d}", .{turn});
        defer allocator.free(marker);
        if (std.mem.indexOf(u8, out, marker) == null) {
            std.debug.print("[mcp-live-http] FAIL turn {d}: '{s}' not in '{s}'\n", .{ turn, marker, out });
            return error.HttpMultiTurnDrift;
        }
    }
    std.debug.print("[mcp-live-http] 5 consecutive HTTP tools/call OK — session id held\n", .{});
    std.debug.print("[mcp-live-http] PASS\n", .{});
}
