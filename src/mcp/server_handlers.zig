//! MCP server — method handlers.
//!
//! Pure result-builders for the MCP methods nullalis implements. Each
//! function takes already-resolved inputs and returns a heap-owned JSON
//! string for the `result` field of a JSON-RPC response. No I/O, no
//! transport — `src/mcp_server.zig` wires these to the stdio loop.
//!
//! Methods implemented:
//!   initialize   — capability/version negotiation
//!   tools/list   — the curated (or full) tool catalog
//!   tools/call   — execute one tool, return MCP content blocks
//!   ping         — liveness check (returns {})

const std = @import("std");
const tools_mod = @import("../tools/root.zig");
const json_util = @import("../json_util.zig");
const policy = @import("server_policy.zig");
const protocol = @import("server_protocol.zig");
const version = @import("../version.zig");
const Allocator = std.mem.Allocator;

/// Build the `initialize` result. Advertises the protocol version, the
/// server's identity, and the single capability nullalis exposes: tools.
/// Resources/prompts are advertised as absent — see the PR notes for the
/// `resources` deferral rationale.
pub fn buildInitializeResult(allocator: Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{"listChanged":false}}}},"serverInfo":{{"name":"nullalis","version":"{s}"}}}}
    , .{ protocol.protocol_version, version.string });
}

/// Build the `tools/list` result from the live tool registry, filtered by
/// the exposure policy. Each entry carries `name`, `description`, and
/// `inputSchema` — the tool's own `parametersJson()` is a JSON Schema
/// object, spliced verbatim. Caller owns the returned slice.
pub fn buildToolsListResult(
    allocator: Allocator,
    tools: []const tools_mod.Tool,
    expose_all: bool,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"tools\":[");

    var first = true;
    for (tools) |t| {
        const tname = t.name();
        if (!policy.shouldExpose(tname, expose_all)) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;

        try buf.appendSlice(allocator, "{\"name\":");
        try json_util.appendJsonString(&buf, allocator, tname);
        try buf.appendSlice(allocator, ",\"description\":");
        try json_util.appendJsonString(&buf, allocator, t.description());
        try buf.appendSlice(allocator, ",\"inputSchema\":");
        const schema = t.parametersJson();
        // A tool's parametersJson should be a JSON Schema object. Guard
        // against an empty/blank value so we always emit valid JSON.
        if (isLikelyJsonObject(schema)) {
            try buf.appendSlice(allocator, schema);
        } else {
            try buf.appendSlice(allocator, "{\"type\":\"object\"}");
        }
        try buf.append(allocator, '}');
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// Outcome of a `tools/call`. `result_json` is the JSON-RPC `result` value
/// (an MCP content envelope) when `err` is null; otherwise `err` describes
/// a protocol-level failure (unknown tool, denied tool, bad params) that
/// the caller should turn into a JSON-RPC error response.
///
/// Note the MCP distinction: a tool that *runs* but fails (e.g. file not
/// found) is NOT a protocol error — it returns a normal `result` with
/// `isError:true`. A protocol error is reserved for "the request itself
/// was malformed or the tool does not exist / is not permitted".
pub const CallOutcome = struct {
    result_json: ?[]u8 = null,
    err: ?struct {
        code: protocol.ErrorCode,
        message: []const u8,
    } = null,
};

/// Execute a `tools/call`. `params` is the JSON-RPC params value, expected
/// to be `{"name": "...", "arguments": {...}}`. Resolves the tool from the
/// registry, enforces the exposure policy, dispatches it, and wraps the
/// output in an MCP content envelope.
///
/// `params` must outlive this call — `arguments` is read from it during
/// dispatch. Caller owns `outcome.result_json` when set.
pub fn handleToolsCall(
    allocator: Allocator,
    tools: []const tools_mod.Tool,
    expose_all: bool,
    params: ?std.json.Value,
) !CallOutcome {
    const p = params orelse return .{ .err = .{
        .code = .invalid_params,
        .message = "tools/call requires params",
    } };
    if (p != .object) return .{ .err = .{
        .code = .invalid_params,
        .message = "tools/call params must be an object",
    } };

    const name_val = p.object.get("name") orelse return .{ .err = .{
        .code = .invalid_params,
        .message = "tools/call params missing 'name'",
    } };
    if (name_val != .string) return .{ .err = .{
        .code = .invalid_params,
        .message = "tools/call 'name' must be a string",
    } };
    const tool_name = name_val.string;

    // Exposure gate first: do not reveal that an unsafe tool exists.
    if (!policy.shouldExpose(tool_name, expose_all)) {
        return .{ .err = .{
            .code = .method_not_found,
            .message = "unknown or unavailable tool",
        } };
    }

    // Resolve the tool from the live registry.
    var matched: ?tools_mod.Tool = null;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), tool_name)) {
            matched = t;
            break;
        }
    }
    const tool = matched orelse return .{ .err = .{
        .code = .method_not_found,
        .message = "unknown or unavailable tool",
    } };

    // Per-call arena for tool execution. The agent dispatches tools against
    // an arena too (see `Agent.executeToolCall` in agent/root.zig): a tool's
    // ToolResult `output`/`error_msg` may be heap-allocated OR a static
    // literal, and there is no per-field flag to tell them apart — so the
    // ownership contract is "the caller arena reclaims everything". We do
    // the same: the tool allocates into `arena`, we copy the text we need
    // into a `allocator`-owned envelope, then `arena.deinit()` frees the
    // tool's scratch wholesale (a no-op for literals).
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `arguments` may be absent (tool with no params) → empty object.
    const empty_args = std.json.ObjectMap.init(arena);
    const args: tools_mod.JsonObjectMap = blk: {
        const a = p.object.get("arguments") orelse break :blk empty_args;
        if (a != .object) return .{ .err = .{
            .code = .invalid_params,
            .message = "tools/call 'arguments' must be an object",
        } };
        break :blk a.object;
    };

    // Dispatch. A tool returning `error` (as opposed to a failed ToolResult)
    // is an internal fault, not a protocol error in the caller's request.
    const tr = tool.execute(arena, args) catch |e| {
        const msg = try std.fmt.allocPrint(arena, "tool execution failed: {s}", .{@errorName(e)});
        return .{ .result_json = try buildContentEnvelope(allocator, msg, true) };
    };

    if (tr.success) {
        return .{ .result_json = try buildContentEnvelope(allocator, tr.output, false) };
    } else {
        const msg = tr.error_msg orelse "tool reported failure";
        return .{ .result_json = try buildContentEnvelope(allocator, msg, true) };
    }
}

/// Wrap a text payload in the MCP `tools/call` result envelope:
///   {"content":[{"type":"text","text":"..."}],"isError":<bool>}
fn buildContentEnvelope(allocator: Allocator, text: []const u8, is_error: bool) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"content\":[{\"type\":\"text\",\"text\":");
    try json_util.appendJsonString(&buf, allocator, text);
    try buf.appendSlice(allocator, "}],\"isError\":");
    try buf.appendSlice(allocator, if (is_error) "true" else "false");
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// Cheap structural check: does the string look like a JSON object? Used
/// only to guard against a tool returning a blank/non-object schema. Not a
/// full validator — the tool's own schema is trusted to be well-formed.
fn isLikelyJsonObject(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
}

// ── Tests ───────────────────────────────────────────────────────

const testing = std.testing;

// A minimal in-test tool used to exercise the handlers without booting
// the real registry. Echoes a fixed string or fails on demand.
const FakeTool = struct {
    name_str: []const u8,
    fail: bool = false,
    err_on_execute: bool = false,

    const vt = tools_mod.Tool.VTable{
        .execute = &execImpl,
        .name = &nameImpl,
        .description = &descImpl,
        .parameters_json = &paramsImpl,
    };
    fn tool(self: *FakeTool) tools_mod.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vt };
    }
    fn execImpl(ptr: *anyopaque, allocator: Allocator, args: tools_mod.JsonObjectMap) anyerror!tools_mod.ToolResult {
        _ = args;
        const self: *FakeTool = @ptrCast(@alignCast(ptr));
        if (self.err_on_execute) return error.Boom;
        if (self.fail) return tools_mod.ToolResult.fail("fake failure");
        const out = try allocator.dupe(u8, "fake output");
        return tools_mod.ToolResult.ok(out);
    }
    fn nameImpl(ptr: *anyopaque) []const u8 {
        return (@as(*FakeTool, @ptrCast(@alignCast(ptr)))).name_str;
    }
    fn descImpl(_: *anyopaque) []const u8 {
        return "a fake tool";
    }
    fn paramsImpl(_: *anyopaque) []const u8 {
        return "{\"type\":\"object\",\"properties\":{}}";
    }
};

test "server_handlers: buildInitializeResult advertises tools capability" {
    const out = try buildInitializeResult(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"protocolVersion\":\"2024-11-05\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"serverInfo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"tools\"") != null);
    // Must be valid JSON.
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    p.deinit();
}

test "server_handlers: buildToolsListResult filters by exposure policy" {
    var safe = FakeTool{ .name_str = "calculator" };
    var unsafe = FakeTool{ .name_str = "shell" };
    const list = [_]tools_mod.Tool{ safe.tool(), unsafe.tool() };

    // Default policy: only the safe tool appears.
    const out = try buildToolsListResult(testing.allocator, &list, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "calculator") != null);
    try testing.expect(std.mem.indexOf(u8, out, "shell") == null);

    // Result must be valid JSON with a tools array.
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.object.get("tools").?.array.items.len);
}

test "server_handlers: buildToolsListResult expose_all includes everything" {
    var safe = FakeTool{ .name_str = "calculator" };
    var unsafe = FakeTool{ .name_str = "shell" };
    const list = [_]tools_mod.Tool{ safe.tool(), unsafe.tool() };
    const out = try buildToolsListResult(testing.allocator, &list, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "calculator") != null);
    try testing.expect(std.mem.indexOf(u8, out, "shell") != null);
}

test "server_handlers: handleToolsCall executes a permitted tool" {
    var t = FakeTool{ .name_str = "calculator" };
    const list = [_]tools_mod.Tool{t.tool()};
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"name":"calculator","arguments":{}}
    , .{});
    defer p.deinit();
    const outcome = try handleToolsCall(testing.allocator, &list, false, p.value);
    defer if (outcome.result_json) |r| testing.allocator.free(r);
    try testing.expect(outcome.err == null);
    try testing.expect(std.mem.indexOf(u8, outcome.result_json.?, "fake output") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.result_json.?, "\"isError\":false") != null);
}

test "server_handlers: handleToolsCall denies an unsafe tool as method_not_found" {
    var t = FakeTool{ .name_str = "shell" };
    const list = [_]tools_mod.Tool{t.tool()};
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"name":"shell","arguments":{"command":"rm -rf /"}}
    , .{});
    defer p.deinit();
    const outcome = try handleToolsCall(testing.allocator, &list, false, p.value);
    defer if (outcome.result_json) |r| testing.allocator.free(r);
    try testing.expect(outcome.err != null);
    try testing.expectEqual(protocol.ErrorCode.method_not_found, outcome.err.?.code);
}

test "server_handlers: handleToolsCall reports a failing tool via isError, not protocol error" {
    var t = FakeTool{ .name_str = "calculator", .fail = true };
    const list = [_]tools_mod.Tool{t.tool()};
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"name":"calculator","arguments":{}}
    , .{});
    defer p.deinit();
    const outcome = try handleToolsCall(testing.allocator, &list, false, p.value);
    defer if (outcome.result_json) |r| testing.allocator.free(r);
    try testing.expect(outcome.err == null); // not a protocol error
    try testing.expect(std.mem.indexOf(u8, outcome.result_json.?, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.result_json.?, "fake failure") != null);
}

test "server_handlers: handleToolsCall surfaces an internal tool error as isError" {
    var t = FakeTool{ .name_str = "calculator", .err_on_execute = true };
    const list = [_]tools_mod.Tool{t.tool()};
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"name":"calculator","arguments":{}}
    , .{});
    defer p.deinit();
    const outcome = try handleToolsCall(testing.allocator, &list, false, p.value);
    defer if (outcome.result_json) |r| testing.allocator.free(r);
    try testing.expect(outcome.err == null);
    try testing.expect(std.mem.indexOf(u8, outcome.result_json.?, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.result_json.?, "Boom") != null);
}

test "server_handlers: handleToolsCall rejects missing name" {
    const list = [_]tools_mod.Tool{};
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"arguments":{}}
    , .{});
    defer p.deinit();
    const outcome = try handleToolsCall(testing.allocator, &list, false, p.value);
    defer if (outcome.result_json) |r| testing.allocator.free(r);
    try testing.expect(outcome.err != null);
    try testing.expectEqual(protocol.ErrorCode.invalid_params, outcome.err.?.code);
}

test "server_handlers: handleToolsCall rejects unknown permitted-name tool" {
    // 'calculator' is on the safe list but not in the (empty) registry.
    const list = [_]tools_mod.Tool{};
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"name":"calculator","arguments":{}}
    , .{});
    defer p.deinit();
    const outcome = try handleToolsCall(testing.allocator, &list, false, p.value);
    defer if (outcome.result_json) |r| testing.allocator.free(r);
    try testing.expect(outcome.err != null);
    try testing.expectEqual(protocol.ErrorCode.method_not_found, outcome.err.?.code);
}

test "server_handlers: isLikelyJsonObject guards blank schemas" {
    try testing.expect(isLikelyJsonObject("{\"type\":\"object\"}"));
    try testing.expect(isLikelyJsonObject("  {}  "));
    try testing.expect(!isLikelyJsonObject(""));
    try testing.expect(!isLikelyJsonObject("not json"));
}
