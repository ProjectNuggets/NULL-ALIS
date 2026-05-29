//! Sprint S4 — end-to-end coverage across every shipped extension_* tool.
//!
//! For each of the ten tools we exercise four paths:
//!   1. no_extension_connected → ToolResult.success=false, error_msg
//!      contains "no extension connected".
//!   2. happy path (mock conn replies ok:true) → ToolResult.success=true.
//!   3. timeout → ToolResult.success=false, error_msg contains "timeout"
//!      or "did not respond".
//!   4. extension-reported error (`ok:false` from the mock) →
//!      ToolResult.success=false, error_msg contains "extension reported error".
//!
//! Cross-tool pin: a regression where any tool stops surfacing one of
//! these named states would fail here even if the per-tool inline tests
//! are still passing.
//!
//! S4 hardening: each scenario runs through `runScenario` which wraps
//! ToolResult lifecycle and conn refcount handoff in defers so:
//!   (a) the deliverer thread is joined BEFORE the conn ref is dropped,
//!       closing the use-after-free race the prior shape had;
//!   (b) every tool allocation (whether the tool returned a static-string
//!       error_msg or a heap-allocated one) is freed via an arena so the
//!       cleanup is uniform — no more "do not free this branch" carve-outs.

const std = @import("std");
const nullalis = @import("nullalis");
const hub_mod = nullalis.extension_ws.hub;
const tools = nullalis.tools;
const config_mod = nullalis.config;

/// Minimal Config that satisfies allTools's runtime_info requirement.
/// workspace_dir + config_path are inert for the extension_* code path.
const TEST_CONFIG = config_mod.Config{
    .workspace_dir = "/tmp",
    .config_path = "/tmp/nullalis-mock-hub-e2e-test/config.json",
    .allocator = std.testing.allocator,
};

// ── Recording stream ─────────────────────────────────────────────────────────
//
// Each `writeText` call appends a fresh heap copy of the frame so that
// `deliverOk`/`deliverErr` can safely look up `writes.items[0]`.

const RecordingStream = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *RecordingStream = @ptrCast(@alignCast(ctx));
        const copy = try self.allocator.dupe(u8, text);
        try self.writes.append(self.allocator, copy);
    }

    pub fn close(_: *anyopaque) void {}

    pub fn deinit(self: *RecordingStream) void {
        for (self.writes.items) |w| self.allocator.free(w);
        self.writes.deinit(self.allocator);
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn extractCommandId(frame: []const u8) ?[]const u8 {
    const needle = "\"command_id\":\"";
    const start_idx = std.mem.indexOf(u8, frame, needle) orelse return null;
    const after = start_idx + needle.len;
    const end_idx = std.mem.indexOfScalarPos(u8, frame, after, '"') orelse return null;
    return frame[after..end_idx];
}

/// Wait until the tool has written the command frame, extract the
/// command_id, and deliver an ok:true reply with `result_json_body`.
fn deliverOk(conn: *hub_mod.ExtensionWsConn, stream: *RecordingStream, result_json_body: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 1000 and stream.writes.items.len == 0) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (stream.writes.items.len == 0) return error.NoFrame;
    const cmd_id = extractCommandId(stream.writes.items[0]) orelse return error.NoCommandId;
    var buf: [4096]u8 = undefined;
    const reply = try std.fmt.bufPrint(
        &buf,
        "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{s}}}",
        .{ cmd_id, result_json_body },
    );
    try conn.deliverResult(reply);
}

/// Wait until the tool has written the command frame, extract the
/// command_id, and deliver an ok:false reply carrying `code` + `message`.
fn deliverErr(conn: *hub_mod.ExtensionWsConn, stream: *RecordingStream, code: []const u8, message: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 1000 and stream.writes.items.len == 0) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (stream.writes.items.len == 0) return error.NoFrame;
    const cmd_id = extractCommandId(stream.writes.items[0]) orelse return error.NoCommandId;
    var buf: [4096]u8 = undefined;
    const reply = try std.fmt.bufPrint(
        &buf,
        "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}",
        .{ cmd_id, code, message },
    );
    try conn.deliverResult(reply);
}

// ── Tool harness table ────────────────────────────────────────────────────────
//
// Each entry records the minimum-valid args_json for that tool and a
// plausible happy-path `result` body to hand back from the mock.
//
// Schema notes (confirmed from src/tools/extension_*.zig):
//   extension_fill_form  — fields items require "selector" + "text" (NOT "value")
//   extension_scroll     — requires "direction": enum(up|down|top|bottom) (NOT "y")
//   extension_get_text   — "selector" is optional; {} is valid
//   extension_get_dom    — "selector" is optional; {} is valid
//   extension_screenshot — no required fields; {} is valid
//   extension_list_tabs  — no required fields; {} is valid

const ToolHarness = struct {
    name: []const u8,
    args_json: []const u8,
    happy_result_body: []const u8,
};

const TOOL_HARNESSES = [_]ToolHarness{
    .{ .name = "extension_navigate",   .args_json = "{\"url\":\"https://example.com\"}",                           .happy_result_body = "{\"tab_id\":1,\"url\":\"https://example.com/\"}" },
    .{ .name = "extension_click",      .args_json = "{\"selector\":\"#x\"}",                                       .happy_result_body = "{\"clicked\":true}" },
    .{ .name = "extension_type",       .args_json = "{\"selector\":\"#x\",\"text\":\"hi\"}",                       .happy_result_body = "{\"typed\":true}" },
    .{ .name = "extension_fill_form",  .args_json = "{\"fields\":[{\"selector\":\"#a\",\"text\":\"v\"}]}",         .happy_result_body = "{\"filled\":1}" },
    .{ .name = "extension_screenshot", .args_json = "{}",                                                           .happy_result_body = "{\"png_b64\":\"AAA\"}" },
    .{ .name = "extension_get_text",   .args_json = "{}",                                                           .happy_result_body = "{\"text\":\"hello\"}" },
    .{ .name = "extension_get_dom",    .args_json = "{}",                                                           .happy_result_body = "{\"html\":\"<p/>\"}" },
    .{ .name = "extension_wait_for",   .args_json = "{\"selector\":\"#x\"}",                                       .happy_result_body = "{\"found\":true}" },
    .{ .name = "extension_scroll",     .args_json = "{\"direction\":\"down\"}",                                    .happy_result_body = "{\"scrolled\":true}" },
    .{ .name = "extension_list_tabs",  .args_json = "{}",                                                           .happy_result_body = "{\"tabs\":[]}" },
};

// ── Tool-list helpers ─────────────────────────────────────────────────────────

fn findTool(tool_list: []const tools.Tool, name: []const u8) ?tools.Tool {
    for (tool_list) |t| {
        if (std.mem.eql(u8, t.name(), name)) return t;
    }
    return null;
}

/// Mutate each extension_* tool's `timeout_ms` field to a small value so
/// the timeout-path test doesn't sleep for the 30 s default.  Walks the
/// same tool family bindExtensionTools knows about.
fn setTinyTimeout(tool_list: []const tools.Tool, name: []const u8) void {
    const tiny: u64 = 30;
    inline for (.{
        .{ "extension_navigate",   tools.extension_navigate.ExtensionNavigateTool },
        .{ "extension_click",      tools.extension_click.ExtensionClickTool },
        .{ "extension_type",       tools.extension_type.ExtensionTypeTool },
        .{ "extension_fill_form",  tools.extension_fill_form.ExtensionFillFormTool },
        .{ "extension_screenshot", tools.extension_screenshot.ExtensionScreenshotTool },
        .{ "extension_get_text",   tools.extension_get_text.ExtensionGetTextTool },
        .{ "extension_get_dom",    tools.extension_get_dom.ExtensionGetDomTool },
        .{ "extension_wait_for",   tools.extension_wait_for.ExtensionWaitForTool },
        .{ "extension_scroll",     tools.extension_scroll.ExtensionScrollTool },
        .{ "extension_list_tabs",  tools.extension_list_tabs.ExtensionListTabsTool },
    }) |pair| {
        if (std.mem.eql(u8, name, pair[0])) {
            for (tool_list) |t| {
                if (std.mem.eql(u8, t.name(), name)) {
                    const ent: *pair[1] = @ptrCast(@alignCast(t.ptr));
                    ent.timeout_ms = tiny;
                    return;
                }
            }
        }
    }
}

// ── Scenario verdict ──────────────────────────────────────────────────────────

const ScenarioVerdict = enum {
    expect_no_extension_connected,
    expect_success,
    expect_timeout,
    expect_extension_reported_error,
};

/// Spawn either an ok-deliverer, an err-deliverer, or no deliverer at
/// all depending on the scenario.
const Deliverer = enum {
    none,
    ok_reply,
    err_reply,
};

/// Run one tool-scenario combination cleanly:
///   - tool execution uses a per-call arena so any ToolResult fields
///     (static or heap) are freed atomically with `arena.deinit()`,
///     regardless of which tool branch returned them.
///   - deliverer thread (when spawned) is joined BEFORE the conn ref
///     is dropped, closing the use-after-free race the prior layout
///     had if `findTool` returned null with a live thread still
///     holding the conn pointer.
fn runScenario(
    harness: ToolHarness,
    verdict: ScenarioVerdict,
    deliverer: Deliverer,
) !void {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var stream = RecordingStream{ .allocator = std.testing.allocator };
    defer stream.deinit();

    // Conn lifecycle: only register if the scenario isn't testing the
    // "no extension connected" path.
    const conn_opt: ?*hub_mod.ExtensionWsConn = if (verdict == .expect_no_extension_connected) null else try hub.registerConn(
        "alice",
        @ptrCast(&stream),
        RecordingStream.writeText,
        @ptrCast(&stream),
        RecordingStream.close,
    );
    // Caller's ref dropped here. Hub's ref dropped by hub.deinit. The
    // pair ensures the conn frees by test end.
    defer if (conn_opt) |c| hub.destroyConn(c);

    const tool_list = try tools.allTools(std.testing.allocator, "/tmp", .{
        .config = &TEST_CONFIG,
        .extension_ws_hub = &hub,
    });
    defer tools.deinitTools(std.testing.allocator, tool_list);
    tools.bindExtensionTools(tool_list, "alice");

    if (verdict == .expect_timeout) {
        setTinyTimeout(tool_list, harness.name);
    }

    // Spawn deliverer BEFORE finding the tool so that if `findTool`
    // returns null we still reach the defer-join chain rather than
    // racing the explicit cleanup. The thread.join defer is declared
    // AFTER conn's destroyConn defer so it fires FIRST (defers run
    // LIFO) — guarantees the thread is joined before the conn ref
    // is released.
    var deliverer_thread: ?std.Thread = null;
    defer if (deliverer_thread) |th| th.join();

    if (conn_opt) |conn| {
        switch (deliverer) {
            .none => {},
            .ok_reply => {
                const Ctx = struct {
                    c: *hub_mod.ExtensionWsConn,
                    s: *RecordingStream,
                    body: []const u8,
                    fn run(ctx: @This()) void {
                        deliverOk(ctx.c, ctx.s, ctx.body) catch {};
                    }
                };
                deliverer_thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .c = conn, .s = &stream, .body = harness.happy_result_body }});
            },
            .err_reply => {
                const Ctx = struct {
                    c: *hub_mod.ExtensionWsConn,
                    s: *RecordingStream,
                    fn run(ctx: @This()) void {
                        deliverErr(ctx.c, ctx.s, "denied", "user blocked the action") catch {};
                    }
                };
                deliverer_thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .c = conn, .s = &stream }});
            },
        }
    }

    const t = findTool(tool_list, harness.name) orelse {
        std.debug.print("missing tool {s}\n", .{harness.name});
        try std.testing.expect(false);
        return;
    };

    // Per-scenario arena: every allocation the tool execution makes
    // (whether the tool returns a static-string error_msg or a heap
    // one) is owned by the arena and freed atomically when this
    // function returns. No "do NOT free this branch" carve-outs;
    // the cleanup is the same shape regardless of which path the
    // tool takes.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try tools.parseTestArgs(harness.args_json);
    defer parsed.deinit();

    const result = try t.execute(a, parsed.value.object);

    switch (verdict) {
        .expect_no_extension_connected => {
            try std.testing.expect(!result.success);
            try std.testing.expect(result.error_msg != null);
            if (std.mem.indexOf(u8, result.error_msg.?, "no extension connected") == null) {
                std.debug.print("{s} error_msg='{s}'\n", .{ harness.name, result.error_msg.? });
                try std.testing.expect(false);
            }
        },
        .expect_success => {
            if (!result.success) {
                std.debug.print("{s} unexpected fail error_msg={?s}\n", .{ harness.name, result.error_msg });
                try std.testing.expect(false);
            }
        },
        .expect_timeout => {
            try std.testing.expect(!result.success);
            try std.testing.expect(result.error_msg != null);
            if (std.mem.indexOf(u8, result.error_msg.?, "timeout") == null and
                std.mem.indexOf(u8, result.error_msg.?, "did not respond") == null)
            {
                std.debug.print("{s} timeout msg='{s}'\n", .{ harness.name, result.error_msg.? });
                try std.testing.expect(false);
            }
        },
        .expect_extension_reported_error => {
            try std.testing.expect(!result.success);
            try std.testing.expect(result.error_msg != null);
            if (std.mem.indexOf(u8, result.error_msg.?, "extension reported error") == null) {
                std.debug.print("{s} denied msg='{s}'\n", .{ harness.name, result.error_msg.? });
                try std.testing.expect(false);
            }
        },
    }
}

// ── Test 1: no extension connected ───────────────────────────────────────────

test "E2E: every extension_* tool surfaces no_extension_connected when nothing paired" {
    for (TOOL_HARNESSES) |h| {
        try runScenario(h, .expect_no_extension_connected, .none);
    }
}

// ── Test 2: happy path ────────────────────────────────────────────────────────

test "E2E: every extension_* tool happy-path returns success when mock replies ok:true" {
    for (TOOL_HARNESSES) |h| {
        try runScenario(h, .expect_success, .ok_reply);
    }
}

// ── Test 3: timeout ───────────────────────────────────────────────────────────

test "E2E: every extension_* tool surfaces timeout when mock never replies" {
    for (TOOL_HARNESSES) |h| {
        try runScenario(h, .expect_timeout, .none);
    }
}

// ── Test 4: extension-reported error ─────────────────────────────────────────

test "E2E: every extension_* tool surfaces ok:false error frame as named failure" {
    for (TOOL_HARNESSES) |h| {
        try runScenario(h, .expect_extension_reported_error, .err_reply);
    }
}
