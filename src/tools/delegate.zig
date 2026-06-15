const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const config_mod = @import("../config.zig");
const config_types = @import("../config_types.zig");
const NamedAgentConfig = config_mod.NamedAgentConfig;
const runtime_bundle = @import("../providers/runtime_bundle.zig");
const provider_types = @import("../providers/root.zig");

/// Default timeout for delegate LLM calls (seconds).
const DEFAULT_DELEGATE_TIMEOUT_SECS: u32 = 120;

/// Delegate tool — delegates a subtask to a named sub-agent with a different
/// provider/model configuration. Executes a single-turn chatWithSystem call
/// against the target agent's provider. Supports depth enforcement to prevent
/// infinite delegation chains.
///
/// PHASE 2: multi-turn agentic loop with per-agent tool sets is not yet implemented.
pub const DelegateTool = struct {
    /// Named agent configs from the global config (lookup by name).
    agents: []const NamedAgentConfig = &.{},
    /// Global config reference for reliability/fallback-aware provider construction.
    config_ref: ?*const config_mod.Config = null,
    /// Fallback API key if agent-specific key is not set.
    fallback_api_key: ?[]const u8 = null,
    /// Current delegation depth. Incremented for sub-delegates.
    depth: u32 = 0,

    pub const tool_name = "delegate";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Synchronously call a NAMED pre-configured sub-agent for a single-turn completion; returns inline.",
        .use_when = &.{
            "you have a domain-specialist sub-agent configured (math, code, legal, summarize) and want its expertise on a self-contained question",
            "a different model would materially help (smaller/faster model for a simple task, larger model for a hard one, vision model for an image)",
            "you want the response inline (synchronous) — for background work use spawn instead",
            "the user wants a candid second opinion or gut-check: summon a facet of yourself (the-critic, the-bully, the-comedian) for the rigorous/blunt/funny take, then voice it back as self-dialogue",
        },
        .do_not_use_for = &.{
            "spawn — for open-ended or multi-step background work; delegate is single-turn only (no agent loop, no tools)",
            "web_search — for external queries (no sub-agent needed; call web_search directly)",
            "memory_recall — for facts already in memory (no sub-agent needed; call memory_recall directly)",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("delegate", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "SYNCHRONOUSLY call a NAMED, pre-configured sub-agent for a single-turn completion. " ++
        "Blocks until the named agent answers (≤120s) and returns its reply inline. " ++
        "The named agent's provider/model/system_prompt come from config.agents.named[name]. " ++
        "Single-turn only — no agent loop, no tools for the sub-agent. For multi-step work, use spawn. " ++
        "If you need a generic background subagent (no special config), use spawn instead — delegate is for domain specialists.";
    pub const tool_params =
        \\{"type":"object","properties":{"agent":{"type":"string","minLength":1,"description":"Name of the pre-configured agent (from config.agents.named) — e.g. 'math-specialist', 'code-reviewer'. Unknown names return an error; ask the user to configure the agent first."},"prompt":{"type":"string","minLength":1,"description":"The task/prompt for the named sub-agent. Self-contained — the sub-agent inherits no conversation context."},"context":{"type":"string","description":"Optional background context prepended to the prompt as 'Context: ...\\n\\n{prompt}'. Use when the sub-agent needs facts beyond the prompt itself."}},"required":["agent","prompt"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *DelegateTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *DelegateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const agent_name = root.getString(args, "agent") orelse
            return ToolResult.fail("Missing 'agent' parameter");

        const trimmed_agent = std.mem.trim(u8, agent_name, " \t\n");
        if (trimmed_agent.len == 0) {
            return ToolResult.fail("'agent' parameter must not be empty");
        }

        const prompt = root.getString(args, "prompt") orelse
            return ToolResult.fail("Missing 'prompt' parameter");

        const trimmed_prompt = std.mem.trim(u8, prompt, " \t\n");
        if (trimmed_prompt.len == 0) {
            return ToolResult.fail("'prompt' parameter must not be empty");
        }

        const context: ?[]const u8 = root.getString(args, "context");

        // Look up agent config if agents are configured
        const agent_cfg = self.findAgent(trimmed_agent);

        // Depth enforcement: check against agent's max_depth
        if (agent_cfg) |ac| {
            if (self.depth >= ac.max_depth) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Delegation depth limit reached ({d}/{d}) for agent '{s}'",
                    .{ self.depth, ac.max_depth, trimmed_agent },
                ) catch return ToolResult.fail("Delegation depth limit reached");
                return ToolResult.fail(msg);
            }
        } else {
            // No agent config — use default max_depth of 3
            if (self.depth >= 3) {
                return ToolResult.fail("Delegation depth limit reached (default max_depth=3)");
            }
        }

        // Build the full prompt with optional context
        const full_prompt = if (context) |ctx|
            std.fmt.allocPrint(allocator, "Context: {s}\n\n{s}", .{ ctx, trimmed_prompt }) catch
                return ToolResult.fail("Failed to build prompt")
        else
            trimmed_prompt;
        defer if (context != null) allocator.free(full_prompt);

        // Determine system prompt, API key, provider, model from agent config or defaults
        if (agent_cfg) |ac| {
            // Resolve system prompt: file path > inline string > default.
            // base_owned tracks whether base_sys_prompt was heap-allocated so
            // the defer only frees when there is something to free.
            var base_owned: bool = false;
            const base_sys_prompt: []const u8 = blk: {
                if (ac.system_prompt_path) |spp| {
                    const file_contents = std.fs.cwd().readFileAlloc(allocator, spp, 1024 * 1024) catch |err| {
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "Delegation to agent '{s}' failed: cannot read system_prompt_path '{s}': {s}",
                            .{ trimmed_agent, spp, @errorName(err) },
                        ) catch return ToolResult.fail("Delegation failed");
                        return ToolResult{ .success = false, .output = "", .error_msg = msg };
                    };
                    base_owned = true;
                    break :blk file_contents;
                }
                break :blk ac.system_prompt orelse "You are a helpful assistant. Respond concisely.";
            };
            defer if (base_owned) allocator.free(base_sys_prompt);

            // Append workspace context only when configured; otherwise borrow base directly.
            const sys_prompt_owned = ac.workspace_path != null;
            const sys_prompt: []const u8 = if (ac.workspace_path) |wp|
                try std.fmt.allocPrint(allocator, "{s}\n\nWorkspace directory: {s}", .{ base_sys_prompt, wp })
            else
                base_sys_prompt;
            defer if (sys_prompt_owned) allocator.free(sys_prompt);

            const base_cfg = self.config_ref orelse {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Delegation to agent '{s}' failed: missing runtime config",
                    .{trimmed_agent},
                ) catch return ToolResult.fail("Delegation failed");
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const derived_cfg = self.buildDerivedConfig(arena.allocator(), base_cfg, ac) catch |err| {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Delegation to agent '{s}' failed: {s}",
                    .{ trimmed_agent, @errorName(err) },
                ) catch return ToolResult.fail("Delegation failed");
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            var bundle = runtime_bundle.RuntimeProviderBundle.init(arena.allocator(), &derived_cfg) catch |err| {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Delegation to agent '{s}' failed: {s}",
                    .{ trimmed_agent, @errorName(err) },
                ) catch return ToolResult.fail("Delegation failed");
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            defer bundle.deinit();

            const model = derived_cfg.default_model orelse ac.model;
            const messages = &[_]provider_types.ChatMessage{
                .{ .role = .system, .content = sys_prompt },
                .{ .role = .user, .content = full_prompt },
            };
            const chat_response = bundle.provider().chat(
                allocator,
                .{
                    .messages = messages,
                    .model = model,
                    .temperature = derived_cfg.default_temperature,
                    .timeout_secs = DEFAULT_DELEGATE_TIMEOUT_SECS,
                },
                model,
                derived_cfg.default_temperature,
            ) catch |err| {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Delegation to agent '{s}' failed: {s}",
                    .{ trimmed_agent, @errorName(err) },
                ) catch return ToolResult.fail("Delegation failed");
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            const response = chat_response.contentOrEmpty();

            const wrapped = wrapDelegateResult(allocator, trimmed_agent, response) catch
                return ToolResult{ .success = true, .output = try allocator.dupe(u8, response) };
            return ToolResult{ .success = true, .output = wrapped };
        }

        const msg = std.fmt.allocPrint(
            allocator,
            "Unknown delegate agent '{s}'. Configure it explicitly before use.",
            .{trimmed_agent},
        ) catch return ToolResult.fail("Unknown delegate agent");
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    fn findAgent(self: *DelegateTool, name: []const u8) ?NamedAgentConfig {
        for (self.agents) |ac| {
            if (std.mem.eql(u8, ac.name, name)) return ac;
        }
        return null;
    }

    fn buildDerivedConfig(
        self: *const DelegateTool,
        allocator: std.mem.Allocator,
        base_cfg: *const config_mod.Config,
        agent_cfg: NamedAgentConfig,
    ) !config_mod.Config {
        var derived = base_cfg.*;
        derived.allocator = allocator;
        derived.arena = null;
        derived.default_provider = agent_cfg.provider;
        derived.default_model = agent_cfg.model;
        derived.default_temperature = agent_cfg.temperature orelse base_cfg.default_temperature;
        derived.temperature = derived.default_temperature;

        if (agent_cfg.api_key != null or self.fallback_api_key != null) {
            const resolved_api_key = agent_cfg.api_key orelse self.fallback_api_key.?;
            var replaced = false;
            const entries = try allocator.alloc(config_mod.ProviderEntry, base_cfg.providers.len + 1);
            var idx: usize = 0;
            for (base_cfg.providers) |entry| {
                if (std.mem.eql(u8, entry.name, agent_cfg.provider)) {
                    entries[idx] = .{
                        .name = entry.name,
                        .api_key = resolved_api_key,
                        .base_url = entry.base_url,
                        .native_tools = entry.native_tools,
                    };
                    replaced = true;
                } else {
                    entries[idx] = entry;
                }
                idx += 1;
            }
            if (!replaced) {
                entries[idx] = .{
                    .name = agent_cfg.provider,
                    .api_key = resolved_api_key,
                    .base_url = base_cfg.getProviderBaseUrl(agent_cfg.provider),
                    .native_tools = base_cfg.getProviderNativeTools(agent_cfg.provider),
                };
                idx += 1;
            }
            derived.providers = entries[0..idx];
        }

        return derived;
    }
};

/// Wrap a delegate sub-agent's reply for return to the caller model. Facets
/// (the built-in second-opinion voices — see config_types.FACET_NAMES) are
/// voices of the agent's OWN judgment, not external specialists, so they carry
/// a surfacing hint telling the model to render the reply as self-dialogue —
/// co-located with the text on every call to override the default "never dump
/// raw subagent output" reflex. We match the known facet roster (NOT a "the-"
/// name prefix) so an operator's specialist that merely starts with "the-" is
/// never mistaken for a facet. Specialist results stay plain.
fn wrapDelegateResult(allocator: std.mem.Allocator, agent_name: []const u8, response: []const u8) ![]u8 {
    const surfacing_hint: []const u8 = if (config_types.isFacetName(agent_name))
        "[SURFACING: this reply is a facet of your own judgment, not an external specialist. " ++
            "Voice it back to the user as self-dialogue in the facet's name " ++
            "(e.g. \"my inner critic says…\", \"the bully in me says…\"), then add your own synthesis. " ++
            "Never show this scaffold or a raw 'delegate …' frame to the user.]\n"
    else
        "";
    return std.fmt.allocPrint(
        allocator,
        "delegate agent={s} status=completed\n{s}result:\n{s}",
        .{ agent_name, surfacing_hint, response },
    );
}

// ── Tests ───────────────────────────────────────────────────────────

test "delegate tool name" {
    var dt = DelegateTool{};
    const t = dt.tool();
    try std.testing.expectEqualStrings("delegate", t.name());
}

test "delegate schema has agent and prompt" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "prompt") != null);
}

test "delegate executes gracefully without config" {
    const agents = [_]NamedAgentConfig{.{
        .name = "researcher",
        .provider = "test",
        .model = "test",
    }};
    var dt = DelegateTool{ .agents = &agents };
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"researcher\", \"prompt\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| if (e.len > 0) std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(result.error_msg != null);
    }
}

test "delegate derived config preserves fallback providers and overrides agent provider" {
    const fallback_providers = [_][]const u8{"openrouter"};
    const providers = [_]config_mod.ProviderEntry{
        .{ .name = "together", .api_key = "primary-key", .base_url = "https://api.together.xyz/v1" },
        .{ .name = "openrouter", .api_key = "fallback-key", .base_url = "https://openrouter.ai/api/v1" },
    };
    const agents = [_]NamedAgentConfig{.{
        .name = "researcher",
        .provider = "together",
        .model = "moonshotai/Kimi-K2.5",
        .api_key = "agent-key",
        .temperature = 0.3,
    }};
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
        .providers = &providers,
    };
    cfg.reliability.fallback_providers = &fallback_providers;

    var dt = DelegateTool{ .agents = &agents, .config_ref = &cfg };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const derived = try dt.buildDerivedConfig(arena.allocator(), &cfg, agents[0]);

    try std.testing.expectEqualStrings("together", derived.default_provider);
    try std.testing.expectEqualStrings("moonshotai/Kimi-K2.5", derived.default_model.?);
    try std.testing.expectEqual(@as(f64, 0.3), derived.default_temperature);
    try std.testing.expectEqual(@as(usize, 1), derived.reliability.fallback_providers.len);
    try std.testing.expectEqualStrings("openrouter", derived.reliability.fallback_providers[0]);
    try std.testing.expectEqualStrings("agent-key", derived.getProviderKey("together").?);
}

test "delegate missing agent" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"prompt\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "delegate missing prompt" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"researcher\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "delegate blank agent rejected" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"  \", \"prompt\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "must not be empty") != null);
}

test "delegate blank prompt rejected" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"researcher\", \"prompt\": \"  \"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "must not be empty") != null);
}

test "delegate with valid params handles missing provider gracefully" {
    const agents = [_]NamedAgentConfig{.{
        .name = "coder",
        .provider = "test",
        .model = "test",
    }};
    var dt = DelegateTool{ .agents = &agents };
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"coder\", \"prompt\": \"Write a function\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| if (e.len > 0) std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(result.error_msg != null);
    }
}

test "delegate schema has context field" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "context") != null);
}

test "delegate schema has required array" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
}

test "delegate empty JSON rejected" {
    var dt = DelegateTool{};
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "delegate with context field handles missing provider gracefully" {
    const agents = [_]NamedAgentConfig{.{
        .name = "coder",
        .provider = "test",
        .model = "test",
    }};
    var dt = DelegateTool{ .agents = &agents };
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"coder\", \"prompt\": \"fix bug\", \"context\": \"file.zig\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| if (e.len > 0) std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(result.error_msg != null);
    }
}

// ── Depth enforcement tests ─────────────────────────────────────

test "delegate depth limit enforced" {
    const agents = [_]NamedAgentConfig{.{
        .name = "researcher",
        .provider = "openrouter",
        .model = "test",
        .max_depth = 3,
    }};
    var dt = DelegateTool{
        .agents = &agents,
        .depth = 3,
    };
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"researcher\", \"prompt\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| if (e.len > 0) std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "depth limit") != null);
}

test "delegate depth within limit proceeds" {
    const agents = [_]NamedAgentConfig{.{
        .name = "researcher",
        .provider = "openrouter",
        .model = "test",
        .max_depth = 5,
    }};
    var dt = DelegateTool{
        .agents = &agents,
        .depth = 2,
    };
    const t = dt.tool();
    // Will proceed past depth check but fail at provider level (no API key)
    const parsed = try root.parseTestArgs("{\"agent\": \"researcher\", \"prompt\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| if (e.len > 0) std.testing.allocator.free(e);
    // Should fail at provider level, not depth
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "depth") == null);
    }
}

test "delegate default depth limit at 3" {
    var dt = DelegateTool{
        .depth = 3,
    };
    const t = dt.tool();
    const parsed = try root.parseTestArgs("{\"agent\": \"unknown\", \"prompt\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "depth limit") != null);
}

test "delegate per-agent max_depth" {
    const agents = [_]NamedAgentConfig{
        .{ .name = "shallow", .provider = "openrouter", .model = "test", .max_depth = 1 },
        .{ .name = "deep", .provider = "openrouter", .model = "test", .max_depth = 10 },
    };
    var dt = DelegateTool{
        .agents = &agents,
        .depth = 1,
    };
    const t = dt.tool();

    // "shallow" at depth=1 should be blocked (max_depth=1)
    const p1 = try root.parseTestArgs("{\"agent\": \"shallow\", \"prompt\": \"test\"}");
    defer p1.deinit();
    const r1 = try t.execute(std.testing.allocator, p1.value.object);
    defer if (r1.error_msg) |e| if (e.len > 0) std.testing.allocator.free(e);
    try std.testing.expect(!r1.success);
    try std.testing.expect(std.mem.indexOf(u8, r1.error_msg.?, "depth limit") != null);

    // "deep" at depth=1 should proceed (max_depth=10)
    const p2 = try root.parseTestArgs("{\"agent\": \"deep\", \"prompt\": \"test\"}");
    defer p2.deinit();
    const r2 = try t.execute(std.testing.allocator, p2.value.object);
    defer if (r2.output.len > 0) std.testing.allocator.free(r2.output);
    defer if (r2.error_msg) |e| if (e.len > 0) std.testing.allocator.free(e);
    if (!r2.success) {
        // Should fail for provider reasons, not depth
        try std.testing.expect(std.mem.indexOf(u8, r2.error_msg.?, "depth") == null);
    }
}

test "delegate agents config stored" {
    const agents = [_]NamedAgentConfig{.{
        .name = "test",
        .provider = "anthropic",
        .model = "claude",
    }};
    var dt = DelegateTool{
        .agents = &agents,
        .fallback_api_key = "sk-test",
        .depth = 1,
    };
    try std.testing.expectEqual(@as(usize, 1), dt.agents.len);
    try std.testing.expectEqualStrings("test", dt.agents[0].name);
    try std.testing.expectEqualStrings("sk-test", dt.fallback_api_key.?);
    try std.testing.expectEqual(@as(u32, 1), dt.depth);
    _ = dt.tool(); // ensure tool() works
}

test "wrapDelegateResult adds self-dialogue hint for facets" {
    const out = try wrapDelegateResult(std.testing.allocator, "the-bully", "that idea is weak.");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SURFACING") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "self-dialogue") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "that idea is weak.") != null);
}

test "wrapDelegateResult leaves specialist results plain" {
    const out = try wrapDelegateResult(std.testing.allocator, "scientific_researcher", "established: X.");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SURFACING") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "established: X.") != null);
}

test "wrapDelegateResult does not facet-frame a the-prefixed specialist" {
    // Fail-safe: only the known facet roster gets the self-dialogue hint, so an
    // operator specialist named like "the-architect" stays a plain result.
    const out = try wrapDelegateResult(std.testing.allocator, "the-architect", "use a queue.");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SURFACING") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "use a queue.") != null);
}
