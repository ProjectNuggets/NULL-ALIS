//! CLI entry point — single-message and interactive REPL modes.
//!
//! Extracted from agent/root.zig. Contains `run()` (the main entry point
//! for `nullalis agent`) and the streaming stdout callback.

const std = @import("std");
const log = std.log.scoped(.agent);
const Config = @import("../config.zig").Config;
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const observability = @import("../observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const subagent_mod = @import("../subagent.zig");
const cli_mod = @import("../channels/cli.zig");
const security = @import("../security/policy.zig");
const onboard = @import("../onboard.zig");
const tenant_runtime_scope = @import("../tenant_runtime_scope.zig");

const Agent = @import("root.zig").Agent;

/// Streaming callback that writes chunks directly to stdout.
fn cliStreamCallback(_: *anyopaque, chunk: providers.StreamChunk) void {
    if (chunk.delta.len == 0) return;
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const wr = &bw.interface;
    wr.print("{s}", .{chunk.delta}) catch {};
    wr.flush() catch {};
}

/// V1.14.4 review F-1 / HI-03 closure — Standalone CLI subagent delivery.
///
/// Mirrors `cliSubagentCompletionDelivery` in main.zig (the function
/// can't be shared because main.zig is the binary entrypoint and not
/// importable; same shape, kept literal for review traceability). The
/// `nullalis agent` subcommand's SubagentManager runs with bus=null;
/// without this attach, subagent results land in subagent.zig:709's
/// path=none branch and get silently discarded — the original symptom
/// of `project_subagent_received_bug`.
///
/// stderr is the right surface in CLI mode because stdout carries
/// the agent's streamed reply (cliStreamCallback above). Mixing
/// subagent fallback content into stdout would corrupt the
/// user-visible reply stream.
///
/// Errors are non-fatal — std.debug.print swallows write errors per
/// std library convention; we never actually return an error.
fn cliSubagentCompletionDelivery(
    _: ?*anyopaque,
    session_key: []const u8,
    content: []const u8,
) anyerror!void {
    std.debug.print(
        "\n[subagent → {s}]\n{s}\n\n",
        .{ session_key, content },
    );
}

/// Run the agent in single-message or interactive REPL mode.
/// This is the main entry point called by `nullalis agent`.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var cfg = Config.load(allocator) catch {
        log.err("No config found. Run `nullalis onboard` first.", .{});
        return;
    };
    defer cfg.deinit();

    var out_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&out_buf);
    const w = &bw.interface;

    // Parse agent-specific flags
    var message_arg: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var explicit_user_id: ?[]const u8 = null;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg: []const u8 = args[i];
            if ((std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) and i + 1 < args.len) {
                i += 1;
                message_arg = args[i];
            } else if ((std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) and i + 1 < args.len) {
                i += 1;
                session_id = args[i];
            } else if (std.mem.eql(u8, arg, "--user-id") and i + 1 < args.len) {
                i += 1;
                explicit_user_id = args[i];
            }
        }
    }

    var scoped_runtime = try tenant_runtime_scope.resolveForAgentSession(
        allocator,
        &cfg,
        session_id,
        explicit_user_id,
    );
    defer scoped_runtime.deinit(allocator);

    cfg.validate() catch |err| {
        Config.printValidationError(err);
        return;
    };

    // Ensure lifecycle parity: seed workspace files on first agent run
    // so prompts always have the expected bootstrap context.
    const project_ctx = onboard.projectContextForConfig(&cfg);
    try onboard.scaffoldWorkspace(allocator, cfg.workspace_dir, &project_ctx);

    // Create a noop observer
    var noop = observability.NoopObserver{};
    const obs = noop.observer();

    // Record agent start
    const start_event = ObserverEvent{ .agent_start = .{
        .provider = cfg.default_provider,
        .model = cfg.default_model orelse "(default)",
    } };
    obs.recordEvent(&start_event);

    // Initialize MCP tools from config
    const mcp_mod = @import("../mcp.zig");
    const mcp_tools: ?[]const tools_mod.Tool = if (cfg.mcp_servers.len > 0)
        mcp_mod.initMcpTools(allocator, cfg.mcp_servers) catch |err| blk: {
            log.warn("MCP: init failed: {}", .{err});
            break :blk null;
        }
    else
        null;
    defer if (mcp_tools) |mt| allocator.free(mt);

    // Build security policy from config
    var tracker = security.RateTracker.init(allocator, cfg.autonomy.max_actions_per_hour);
    defer tracker.deinit();

    var policy = security.SecurityPolicy{
        .autonomy = cfg.autonomy.level,
        .workspace_dir = cfg.workspace_dir,
        .workspace_only = cfg.autonomy.workspace_only,
        .allowed_commands = if (cfg.autonomy.allowed_commands.len > 0) cfg.autonomy.allowed_commands else &security.default_allowed_commands,
        .max_actions_per_hour = cfg.autonomy.max_actions_per_hour,
        .require_approval_for_medium_risk = cfg.autonomy.require_approval_for_medium_risk,
        .block_high_risk_commands = cfg.autonomy.block_high_risk_commands,
        .tracker = &tracker,
    };

    // Provider runtime bundle (primary provider + reliability wrapper).
    var runtime_provider = try providers.runtime_bundle.RuntimeProviderBundle.init(allocator, &cfg);
    defer runtime_provider.deinit();
    const resolved_api_key = runtime_provider.primaryApiKey();

    var subagent_manager = subagent_mod.SubagentManager.init(allocator, &cfg, null, .{});
    defer subagent_manager.deinit();
    // V1.14.4 review F-1 / HI-03 — third standalone CLI dispatch site
    // (the `nullalis agent` subcommand). Same shape as main.zig:2796 +
    // 3124: SubagentManager init with bus=null was leaving subagent
    // results to vanish at subagent.zig:709's path=none branch. Wire
    // the local cliSubagentCompletionDelivery so subagent content
    // surfaces to stderr instead of being silently discarded.
    subagent_manager.attachCompletionDelivery(null, cliSubagentCompletionDelivery);

    // agent_browser backend — construct a long-lived OrchestratorClient when
    // the backend is active (CLI single-user path; allocator outlives tools).
    const ab_client_mod = @import("../browser_backend/client.zig");
    const ABClient = ab_client_mod.OrchestratorClient;
    const agent_browser_client: ?*ABClient =
        if (cfg.browser.enabled and std.mem.eql(u8, cfg.browser.backend, "agent_browser")) blk: {
            const c = allocator.create(ABClient) catch break :blk null;
            c.* = .{ .base_url = cfg.browser.agent_browser.orchestrator_url, .timeout_ms = cfg.browser.agent_browser.timeout_ms, .auth_token = ab_client_mod.resolveAuthToken(cfg.browser.agent_browser.auth_token) };
            break :blk c;
        } else null;

    // Create tools (with agents config for delegate depth enforcement)
    const tools = try tools_mod.allTools(allocator, cfg.workspace_dir, .{
        .config = &cfg,
        .http_enabled = cfg.http_request.enabled,
        .composio_api_key = if (cfg.composio.enabled) cfg.composio.api_key else null,
        .agent_browser_client = agent_browser_client,
        .mcp_tools = mcp_tools,
        .agents = cfg.agents,
        .fallback_api_key = resolved_api_key,
        .tools_config = cfg.tools,
        .allowed_paths = cfg.autonomy.allowed_paths,
        .policy = &policy,
        .subagent_manager = &subagent_manager,
    });
    defer tools_mod.deinitTools(allocator, tools);
    // agent_browser backend — single-user CLI path; bind a stable "local" user.
    tools_mod.bindBrowserSessionTools(tools, "local");

    // Create memory (optional — don't fail if it can't init)
    var mem_rt = memory_mod.initRuntimeWithOptions(allocator, &cfg.memory, cfg.workspace_dir, .{
        .providers = cfg.providers,
        .search_api_key_override = resolved_api_key,
    });
    defer if (mem_rt) |*rt| rt.deinit();
    const mem_opt: ?Memory = if (mem_rt) |rt| rt.memory else null;

    // Bind memory backend once for this tool set before creating agents.
    tools_mod.bindMemoryTools(tools, mem_opt);

    // Bind MemoryRuntime to memory tools for hybrid search and vector sync.
    if (mem_rt) |*rt| {
        tools_mod.bindMemoryRuntime(tools, rt);
    }
    // S7.10 — audit memory for shell command logging. Pre-S7.10 this was
    // only wired in `channel_loop.zig:435` (Signal/DM lanes), so shell
    // commands executed via the CLI agent silently bypassed the audit
    // trail. bindAuditMemory is a no-op when the memory handle is null
    // or the tool set has no shell tool.
    if (mem_opt) |mem_for_audit| {
        tools_mod.bindAuditMemory(tools, mem_for_audit, null);
    }
    // iter27: transcript_read SessionStore binding
    tools_mod.bindSessionStore(tools, if (mem_rt) |rt| rt.session_store else null);
    // N1: image_generate Together key (CLI path)
    tools_mod.bindImageGenerate(tools, tools_mod.lookupProviderApiKey(cfg.providers, "together"), "");

    // Provider interface from runtime bundle (includes retries/fallbacks).
    const provider_i: Provider = runtime_provider.provider();

    const supports_streaming = provider_i.supportsStreaming();

    // Single message mode: nullalis agent -m "hello"
    if (message_arg) |message| {
        try w.print("Sending to {s}...\n", .{cfg.default_provider});
        if (session_id) |sid| {
            try w.print("Session: {s}\n", .{sid});
        }
        try w.flush();

        var agent = try Agent.fromConfig(allocator, &cfg, provider_i, tools, mem_opt, obs);
        agent.policy = &policy;
        agent.session_store = if (mem_rt) |rt| rt.session_store else null;
        agent.response_cache = if (mem_rt) |*rt| rt.response_cache else null;
        agent.mem_rt = if (mem_rt) |*rt| rt else null;
        if (session_id) |sid| {
            agent.memory_session_id = sid;
        }
        defer agent.deinit();

        // Enable streaming if provider supports it
        var stream_ctx: u8 = 0;
        if (supports_streaming) {
            agent.stream_callback = cliStreamCallback;
            agent.stream_ctx = @ptrCast(&stream_ctx);
        }

        tools_mod.setTenantContext(scoped_runtime.tenantContext(agent.memory_session_id));
        defer tools_mod.clearTenantContext();

        const response = agent.turn(message) catch |err| {
            if (err == error.ProviderDoesNotSupportVision) {
                try w.print("Error: The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.\n", .{});
                try w.flush();
                return;
            }
            return err;
        };
        defer allocator.free(response);

        if (supports_streaming) {
            try w.print("\n", .{});
        } else {
            try w.print("{s}\n", .{response});
        }
        try w.flush();
        return;
    }

    // Interactive REPL mode
    cfg.printModelConfig();
    try w.print("nullalis Agent -- Interactive Mode\n", .{});
    try w.print("Provider: {s} | Model: {s}\n", .{
        cfg.default_provider,
        cfg.default_model orelse "(default)",
    });
    if (session_id) |sid| {
        try w.print("Session: {s}\n", .{sid});
    }
    if (supports_streaming) {
        try w.print("Streaming: enabled\n", .{});
    }
    try w.print("Type your message (Ctrl+D or 'exit' to quit):\n\n", .{});
    try w.flush();

    // Load command history
    const history_path = cli_mod.defaultHistoryPath(allocator) catch null;
    defer if (history_path) |hp| allocator.free(hp);

    var repl_history: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        // Save history on exit
        if (history_path) |hp| {
            cli_mod.saveHistory(repl_history.items, hp) catch {};
        }
        for (repl_history.items) |entry| allocator.free(entry);
        repl_history.deinit(allocator);
    }

    // Seed history from file
    if (history_path) |hp| {
        const loaded = cli_mod.loadHistory(allocator, hp) catch null;
        if (loaded) |entries| {
            defer allocator.free(entries);
            for (entries) |entry| {
                repl_history.append(allocator, entry) catch {
                    allocator.free(entry);
                };
            }
        }
    }

    if (repl_history.items.len > 0) {
        try w.print("[History: {d} entries loaded]\n", .{repl_history.items.len});
        try w.flush();
    }

    var agent = try Agent.fromConfig(allocator, &cfg, provider_i, tools, mem_opt, obs);
    agent.policy = &policy;
    agent.session_store = if (mem_rt) |rt| rt.session_store else null;
    agent.response_cache = if (mem_rt) |*rt| rt.response_cache else null;
    agent.mem_rt = if (mem_rt) |*rt| rt else null;
    if (session_id) |sid| {
        agent.memory_session_id = sid;
    }
    defer agent.deinit();

    // Enable streaming if provider supports it
    var stream_ctx: u8 = 0;
    if (supports_streaming) {
        agent.stream_callback = cliStreamCallback;
        agent.stream_ctx = @ptrCast(&stream_ctx);
    }

    tools_mod.setTenantContext(scoped_runtime.tenantContext(agent.memory_session_id));
    defer tools_mod.clearTenantContext();

    const stdin = std.fs.File.stdin();
    var line_buf: [4096]u8 = undefined;

    while (true) {
        try w.print("> ", .{});
        try w.flush();

        // Read a line from stdin byte-by-byte
        var pos: usize = 0;
        while (pos < line_buf.len) {
            const n = stdin.read(line_buf[pos .. pos + 1]) catch return;
            if (n == 0) return; // EOF (Ctrl+D)
            if (line_buf[pos] == '\n') break;
            pos += 1;
        }
        const line = line_buf[0..pos];

        if (line.len == 0) continue;
        if (cli_mod.CliChannel.isQuitCommand(line)) return;

        // Append to history
        repl_history.append(allocator, allocator.dupe(u8, line) catch continue) catch {};

        const response = agent.turn(line) catch |err| {
            if (err == error.ProviderDoesNotSupportVision) {
                try w.print("Error: The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.\n", .{});
            } else {
                try w.print("Error: {}\n", .{err});
            }
            try w.flush();
            continue;
        };
        defer allocator.free(response);

        if (supports_streaming) {
            try w.print("\n\n", .{});
        } else {
            try w.print("\n{s}\n\n", .{response});
        }
        try w.flush();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "cliStreamCallback handles empty delta" {
    const chunk = providers.StreamChunk.finalChunk();
    cliStreamCallback(undefined, chunk);
}

test "cliStreamCallback text delta chunk" {
    const chunk = providers.StreamChunk.textDelta("hello");
    try std.testing.expectEqualStrings("hello", chunk.delta);
    try std.testing.expect(!chunk.is_final);
    try std.testing.expectEqual(@as(u32, 2), chunk.token_count);
}
