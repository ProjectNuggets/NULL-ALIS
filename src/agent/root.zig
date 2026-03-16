//! Agent core — struct definition, turn loop, tool execution.
//!
//! Sub-modules: dispatcher.zig (tool call parsing), compaction.zig (history
//! compaction/trimming), cli.zig (CLI entry point + REPL), prompt.zig
//! (system prompt), memory_loader.zig (memory enrichment).

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.agent);
const Config = @import("../config.zig").Config;
const config_types = @import("../config_types.zig");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatResponse = providers.ChatResponse;
const ToolSpec = providers.ToolSpec;
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const capabilities_mod = @import("../capabilities.zig");
const multimodal = @import("../multimodal.zig");
const platform = @import("../platform.zig");
const voice_mod = @import("../voice.zig");
const observability = @import("../observability.zig");
const tool_dispatcher = @import("../tool_dispatcher.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const SecurityPolicy = @import("../security/policy.zig").SecurityPolicy;

const cache = memory_mod.cache;
pub const dispatcher = @import("dispatcher.zig");
pub const compaction = @import("compaction.zig");
pub const context_tokens = @import("context_tokens.zig");
pub const max_tokens_resolver = @import("max_tokens.zig");
pub const prompt = @import("prompt.zig");
pub const memory_loader = @import("memory_loader.zig");
pub const commands = @import("commands.zig");
const ParsedToolCall = dispatcher.ParsedToolCall;
const ToolExecutionResult = dispatcher.ToolExecutionResult;

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum agentic tool-use iterations per user message.
const DEFAULT_MAX_TOOL_ITERATIONS: u32 = 25;

/// Maximum non-system messages before trimming.
const DEFAULT_MAX_HISTORY: u32 = 50;

// ═══════════════════════════════════════════════════════════════════════════
// Agent
// ═══════════════════════════════════════════════════════════════════════════

pub const Agent = struct {
    const TtsSynthesizeFn = *const fn (
        allocator: std.mem.Allocator,
        provider: []const u8,
        api_key: []const u8,
        text: []const u8,
        opts: voice_mod.SynthesizeOptions,
    ) voice_mod.SynthesizeError![]u8;

    const VerboseLevel = enum {
        off,
        on,
        full,

        pub fn toSlice(self: VerboseLevel) []const u8 {
            return switch (self) {
                .off => "off",
                .on => "on",
                .full => "full",
            };
        }
    };

    const ReasoningMode = enum {
        off,
        on,
        stream,

        pub fn toSlice(self: ReasoningMode) []const u8 {
            return switch (self) {
                .off => "off",
                .on => "on",
                .stream => "stream",
            };
        }
    };

    const UsageMode = enum {
        off,
        tokens,
        full,
        cost,

        pub fn toSlice(self: UsageMode) []const u8 {
            return switch (self) {
                .off => "off",
                .tokens => "tokens",
                .full => "full",
                .cost => "cost",
            };
        }
    };

    const ExecHost = enum {
        sandbox,
        gateway,
        node,

        pub fn toSlice(self: ExecHost) []const u8 {
            return switch (self) {
                .sandbox => "sandbox",
                .gateway => "gateway",
                .node => "node",
            };
        }
    };

    const ExecSecurity = enum {
        deny,
        allowlist,
        full,

        pub fn toSlice(self: ExecSecurity) []const u8 {
            return switch (self) {
                .deny => "deny",
                .allowlist => "allowlist",
                .full => "full",
            };
        }
    };

    const ExecAsk = enum {
        off,
        on_miss,
        always,

        pub fn toSlice(self: ExecAsk) []const u8 {
            return switch (self) {
                .off => "off",
                .on_miss => "on-miss",
                .always => "always",
            };
        }
    };

    const QueueMode = enum {
        off,
        serial,
        latest,
        debounce,

        pub fn toSlice(self: QueueMode) []const u8 {
            return switch (self) {
                .off => "off",
                .serial => "serial",
                .latest => "latest",
                .debounce => "debounce",
            };
        }
    };

    const QueueDrop = enum {
        summarize,
        oldest,
        newest,

        pub fn toSlice(self: QueueDrop) []const u8 {
            return switch (self) {
                .summarize => "summarize",
                .oldest => "oldest",
                .newest => "newest",
            };
        }
    };

    const TtsMode = enum {
        off,
        always,
        inbound,
        tagged,

        pub fn toSlice(self: TtsMode) []const u8 {
            return switch (self) {
                .off => "off",
                .always => "always",
                .inbound => "inbound",
                .tagged => "tagged",
            };
        }
    };

    const ActivationMode = enum {
        mention,
        always,

        pub fn toSlice(self: ActivationMode) []const u8 {
            return switch (self) {
                .mention => "mention",
                .always => "always",
            };
        }
    };

    const SendMode = enum {
        on,
        off,
        inherit,

        pub fn toSlice(self: SendMode) []const u8 {
            return switch (self) {
                .on => "on",
                .off => "off",
                .inherit => "inherit",
            };
        }
    };

    const ToolDispatcherMode = tool_dispatcher.Mode;

    allocator: std.mem.Allocator,
    provider: Provider,
    tools: []const Tool,
    tool_specs: []const ToolSpec,
    mem: ?Memory,
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*cache.ResponseCache = null,
    /// Optional MemoryRuntime pointer for diagnostics (e.g. /doctor command).
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    /// Optional session scope for memory read/write operations.
    memory_session_id: ?[]const u8 = null,
    observer: Observer,
    model_name: []const u8,
    model_name_owned: bool = false,
    default_provider: []const u8 = "openrouter",
    default_provider_owned: bool = false,
    default_model: []const u8 = "anthropic/claude-sonnet-4",
    configured_providers: []const config_types.ProviderEntry = &.{},
    fallback_providers: []const []const u8 = &.{},
    model_fallbacks: []const config_types.ModelFallbackEntry = &.{},
    temperature: f64,
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    max_tool_iterations: u32,
    max_history_messages: u32,
    parallel_tools: bool = false,
    parallel_tools_rollout_percent: u8 = 100,
    tool_dispatcher_mode: ToolDispatcherMode = .auto,
    auto_save: bool,
    token_limit: u64 = 0,
    token_limit_override: ?u64 = null,
    max_tokens: u32 = max_tokens_resolver.DEFAULT_MODEL_MAX_TOKENS,
    max_tokens_override: ?u32 = null,
    reasoning_effort: ?[]const u8 = null,
    compact_context_enabled: bool = false,
    verbose_level: VerboseLevel = .off,
    reasoning_mode: ReasoningMode = .off,
    usage_mode: UsageMode = .off,
    exec_host: ExecHost = .gateway,
    exec_security: ExecSecurity = .allowlist,
    exec_ask: ExecAsk = .on_miss,
    exec_node_id: ?[]const u8 = null,
    exec_node_id_owned: bool = false,
    queue_mode: QueueMode = .off,
    queue_debounce_ms: u32 = 0,
    queue_cap: u32 = 0,
    queue_drop: QueueDrop = .summarize,
    tts_mode: TtsMode = .off,
    tts_provider: ?[]const u8 = null,
    tts_provider_owned: bool = false,
    tts_limit_chars: u32 = 0,
    tts_summary: bool = false,
    tts_audio: bool = false,
    tts_synthesize_fn: TtsSynthesizeFn = voice_mod.synthesizeTextToTempAudio,
    pending_exec_command: ?[]const u8 = null,
    pending_exec_command_owned: bool = false,
    pending_exec_id: u64 = 0,
    session_ttl_secs: ?u64 = null,
    focus_target: ?[]const u8 = null,
    focus_target_owned: bool = false,
    dock_target: ?[]const u8 = null,
    dock_target_owned: bool = false,
    activation_mode: ActivationMode = .mention,
    send_mode: SendMode = .inherit,
    last_turn_usage: providers.TokenUsage = .{},
    message_timeout_secs: u64 = 0,
    compaction_keep_recent: u32 = compaction.DEFAULT_COMPACTION_KEEP_RECENT,
    compaction_max_summary_chars: u32 = compaction.DEFAULT_COMPACTION_MAX_SUMMARY_CHARS,
    compaction_max_source_chars: u32 = compaction.DEFAULT_COMPACTION_MAX_SOURCE_CHARS,

    /// Optional security policy for autonomy checks and rate limiting.
    policy: ?*const SecurityPolicy = null,

    /// Optional streaming callback. When set, turn() uses streamChat() for streaming providers.
    stream_callback: ?providers.StreamCallback = null,
    /// Context pointer passed to stream_callback.
    stream_ctx: ?*anyopaque = null,
    /// Conversation context for the current turn (Signal-specific for now).
    conversation_context: ?prompt.ConversationContext = null,

    /// Conversation history — owned, growable list.
    history: std.ArrayListUnmanaged(OwnedMessage) = .empty,

    /// Total tokens used across all turns.
    total_tokens: u64 = 0,

    /// Whether the system prompt has been injected.
    has_system_prompt: bool = false,
    /// Whether the currently injected system prompt contains conversation context.
    system_prompt_has_conversation_context: bool = false,
    /// Fingerprint of the conversation context baked into the active system prompt.
    system_prompt_conversation_context_fingerprint: u64 = 0,
    /// Fingerprint of workspace prompt files for the currently injected system prompt.
    workspace_prompt_fingerprint: ?u64 = null,
    /// UTC minute bucket for the currently injected system prompt timestamp.
    /// Used to refresh the prompt clock without rebuilding every turn.
    system_prompt_time_bucket_min: i64 = -1,

    /// Whether compaction was performed during the last turn.
    last_turn_compacted: bool = false,

    /// Whether context was force-compacted due to exhaustion during the current turn.
    context_was_compacted: bool = false,

    /// An owned copy of a ChatMessage, where content is heap-allocated.
    pub const OwnedMessage = struct {
        role: providers.Role,
        content: []const u8,

        pub fn deinit(self: *const OwnedMessage, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
        }

        fn toChatMessage(self: *const OwnedMessage) ChatMessage {
            return .{ .role = self.role, .content = self.content };
        }
    };

    /// Initialize agent from a loaded Config.
    pub fn fromConfig(
        allocator: std.mem.Allocator,
        cfg: *const Config,
        provider_i: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
    ) !Agent {
        const default_model = cfg.default_model orelse return error.NoDefaultModel;
        const token_limit_override = if (cfg.agent.token_limit_explicit) cfg.agent.token_limit else null;
        const resolved_token_limit = context_tokens.resolveContextTokens(token_limit_override, default_model);
        const resolved_max_tokens_raw = max_tokens_resolver.resolveMaxTokens(cfg.max_tokens, default_model);
        const token_limit_cap: u32 = @intCast(@min(resolved_token_limit, @as(u64, std.math.maxInt(u32))));
        const resolved_max_tokens = @min(resolved_max_tokens_raw, token_limit_cap);

        // Build tool specs for function-calling APIs
        const specs = try allocator.alloc(ToolSpec, tools.len);
        for (tools, 0..) |t, i| {
            specs[i] = .{
                .name = t.name(),
                .description = t.description(),
                .parameters_json = t.parametersJson(),
            };
        }

        return .{
            .allocator = allocator,
            .provider = provider_i,
            .tools = tools,
            .tool_specs = specs,
            .mem = mem,
            .observer = observer_i,
            .model_name = default_model,
            .default_provider = cfg.default_provider,
            .default_model = default_model,
            .configured_providers = cfg.providers,
            .fallback_providers = cfg.reliability.fallback_providers,
            .model_fallbacks = cfg.reliability.model_fallbacks,
            .temperature = cfg.default_temperature,
            .workspace_dir = cfg.workspace_dir,
            .allowed_paths = cfg.autonomy.allowed_paths,
            .max_tool_iterations = cfg.agent.max_tool_iterations,
            .max_history_messages = cfg.agent.max_history_messages,
            .parallel_tools = cfg.agent.parallel_tools,
            .parallel_tools_rollout_percent = cfg.agent.parallel_tools_rollout_percent,
            .tool_dispatcher_mode = tool_dispatcher.parseMode(cfg.agent.tool_dispatcher).mode,
            .auto_save = cfg.memory.auto_save,
            .token_limit = resolved_token_limit,
            .token_limit_override = token_limit_override,
            .max_tokens = resolved_max_tokens,
            .max_tokens_override = cfg.max_tokens,
            .reasoning_effort = cfg.reasoning_effort,
            .compact_context_enabled = cfg.agent.compact_context,
            .queue_mode = parseQueueModeFromConfig(cfg.agent.queue_mode),
            .queue_debounce_ms = cfg.agent.queue_debounce_ms,
            .queue_cap = cfg.agent.queue_cap,
            .queue_drop = parseQueueDropFromConfig(cfg.agent.queue_drop),
            .tts_mode = parseTtsModeFromConfig(cfg.agent.tts_mode),
            .tts_provider = cfg.agent.tts_provider,
            .tts_provider_owned = false,
            .tts_limit_chars = cfg.agent.tts_limit_chars,
            .tts_summary = cfg.agent.tts_summary,
            .tts_audio = cfg.agent.tts_audio,
            .session_ttl_secs = cfg.agent.session_ttl_secs,
            .activation_mode = parseActivationModeFromConfig(cfg.agent.activation_mode),
            .send_mode = parseSendModeFromConfig(cfg.agent.send_mode),
            .message_timeout_secs = cfg.agent.message_timeout_secs,
            .compaction_keep_recent = cfg.agent.compaction_keep_recent,
            .compaction_max_summary_chars = cfg.agent.compaction_max_summary_chars,
            .compaction_max_source_chars = cfg.agent.compaction_max_source_chars,
            .history = .empty,
            .total_tokens = 0,
            .has_system_prompt = false,
            .last_turn_compacted = false,
        };
    }

    fn parseQueueModeFromConfig(raw: []const u8) QueueMode {
        if (std.ascii.eqlIgnoreCase(raw, "serial")) return .serial;
        if (std.ascii.eqlIgnoreCase(raw, "latest")) return .latest;
        if (std.ascii.eqlIgnoreCase(raw, "debounce")) return .debounce;
        return .off;
    }

    fn parseQueueDropFromConfig(raw: []const u8) QueueDrop {
        if (std.ascii.eqlIgnoreCase(raw, "oldest")) return .oldest;
        if (std.ascii.eqlIgnoreCase(raw, "newest")) return .newest;
        return .summarize;
    }

    fn parseTtsModeFromConfig(raw: []const u8) TtsMode {
        if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(raw, "inbound")) return .inbound;
        if (std.ascii.eqlIgnoreCase(raw, "tagged")) return .tagged;
        return .off;
    }

    fn parseActivationModeFromConfig(raw: []const u8) ActivationMode {
        if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
        return .mention;
    }

    fn parseSendModeFromConfig(raw: []const u8) SendMode {
        if (std.ascii.eqlIgnoreCase(raw, "on")) return .on;
        if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
        return .inherit;
    }

    pub fn deinit(self: *Agent) void {
        if (self.model_name_owned) self.allocator.free(self.model_name);
        if (self.default_provider_owned) self.allocator.free(self.default_provider);
        if (self.exec_node_id_owned and self.exec_node_id != null) self.allocator.free(self.exec_node_id.?);
        if (self.tts_provider_owned and self.tts_provider != null) self.allocator.free(self.tts_provider.?);
        if (self.pending_exec_command_owned and self.pending_exec_command != null) self.allocator.free(self.pending_exec_command.?);
        if (self.focus_target_owned and self.focus_target != null) self.allocator.free(self.focus_target.?);
        if (self.dock_target_owned and self.dock_target != null) self.allocator.free(self.dock_target.?);
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.tool_specs);
    }

    /// Estimate total tokens in conversation history.
    pub fn tokenEstimate(self: *const Agent) u64 {
        return compaction.tokenEstimate(self.history.items);
    }

    /// Auto-compact history when it exceeds thresholds.
    pub fn autoCompactHistory(self: *Agent) !bool {
        return compaction.autoCompactHistory(self.allocator, &self.history, self.provider, self.model_name, .{
            .keep_recent = self.compaction_keep_recent,
            .max_summary_chars = self.compaction_max_summary_chars,
            .max_source_chars = self.compaction_max_source_chars,
            .token_limit = self.token_limit,
            .max_history_messages = self.max_history_messages,
            .workspace_dir = self.workspace_dir,
        });
    }

    /// Force-compress history for context exhaustion recovery.
    pub fn forceCompressHistory(self: *Agent) bool {
        return compaction.forceCompressHistory(self.allocator, &self.history);
    }

    fn appendUniqueString(
        list: *std.ArrayListUnmanaged([]const u8),
        allocator: std.mem.Allocator,
        value: []const u8,
    ) !void {
        if (value.len == 0) return;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
        }
        try list.append(allocator, value);
    }

    fn providerIsFallback(self: *const Agent, provider_name: []const u8) bool {
        for (self.fallback_providers) |fallback_name| {
            if (std.mem.eql(u8, fallback_name, provider_name)) return true;
        }
        return false;
    }

    fn providerAuthStatus(self: *const Agent, provider_name: []const u8) []const u8 {
        if (providers.classifyProvider(provider_name) == .openai_codex_provider) {
            return "oauth";
        }

        const resolved_key = providers.resolveApiKeyFromConfig(
            self.allocator,
            provider_name,
            self.configured_providers,
        ) catch null;
        defer if (resolved_key) |key| self.allocator.free(key);

        if (resolved_key) |key| {
            if (std.mem.trim(u8, key, " \t\r\n").len > 0) return "configured";
        }
        return "missing";
    }

    fn currentModelFallbacks(self: *const Agent) ?[]const []const u8 {
        for (self.model_fallbacks) |entry| {
            if (std.mem.eql(u8, entry.model, self.model_name)) return entry.fallbacks;
        }
        return null;
    }

    fn composeFinalReply(self: *const Agent, base_text: []const u8, reasoning_content: ?[]const u8, usage: providers.TokenUsage) ![]const u8 {
        return commands.composeFinalReply(self, base_text, reasoning_content, usage);
    }

    fn ttsModeEnabledForTurn(self: *const Agent, user_message: []const u8) bool {
        return switch (self.tts_mode) {
            .off => false,
            .always => true,
            .inbound => containsAsciiIgnoreCase(user_message, "[voice:") or containsAsciiIgnoreCase(user_message, "[audio:"),
            .tagged => containsAsciiIgnoreCase(user_message, "#tts") or containsAsciiIgnoreCase(user_message, "[tts]"),
        };
    }

    fn ttsProviderName(self: *const Agent) []const u8 {
        return self.tts_provider orelse self.default_provider;
    }

    fn ttsAudioChannelSupported(message_ctx: tools_mod.MessageTurnContext) bool {
        const channel = message_ctx.channel orelse return false;
        return std.ascii.eqlIgnoreCase(channel, "telegram");
    }

    fn ttsTrimUtf8Boundary(text: []const u8, max_chars: usize) []const u8 {
        if (text.len <= max_chars) return text;
        var end = max_chars;
        while (end > 0 and (text[end] & 0xC0) == 0x80) : (end -= 1) {}
        return text[0..end];
    }

    fn prepareTtsPayload(self: *const Agent, allocator: std.mem.Allocator, user_message: []const u8, final_text: []const u8) !?[]u8 {
        if (!self.ttsModeEnabledForTurn(user_message)) return null;
        if (final_text.len == 0) return null;

        var payload = final_text;
        if (self.tts_limit_chars > 0 and payload.len > self.tts_limit_chars) {
            payload = ttsTrimUtf8Boundary(payload, self.tts_limit_chars);
        }

        if (self.tts_summary and payload.len < final_text.len) {
            const summarized = try std.fmt.allocPrint(allocator, "{s}...", .{payload});
            return @as(?[]u8, summarized);
        }
        return @as(?[]u8, try allocator.dupe(u8, payload));
    }

    fn maybeBuildTtsAudioReply(
        self: *const Agent,
        allocator: std.mem.Allocator,
        tts_payload: []const u8,
        final_text: []const u8,
    ) !?[]u8 {
        if (!self.tts_audio) return null;

        const message_ctx = tools_mod.message.MessageTool.getTurnContext();
        if (!ttsAudioChannelSupported(message_ctx)) return null;

        const provider_name = self.ttsProviderName();
        const maybe_api_key = providers.resolveApiKeyFromConfig(
            allocator,
            provider_name,
            self.configured_providers,
        ) catch null;
        defer if (maybe_api_key) |key| allocator.free(key);
        const api_key = maybe_api_key orelse {
            log.warn("tts audio skipped: provider={s} reason=missing_api_key", .{provider_name});
            return null;
        };

        const synthesized_path = self.tts_synthesize_fn(
            allocator,
            provider_name,
            api_key,
            tts_payload,
            .{},
        ) catch |err| {
            log.warn("tts audio synth failed: provider={s} reason={s}", .{ provider_name, @errorName(err) });
            return null;
        };
        defer allocator.free(synthesized_path);

        return try std.fmt.allocPrint(allocator, "[AUDIO:{s}]\n{s}", .{ synthesized_path, final_text });
    }

    fn shouldForceActionFollowThrough(text: []const u8) bool {
        const ascii_patterns = [_][]const u8{
            "i'll try",
            "i will try",
            "let me try",
            "i'll check",
            "i will check",
            "let me check",
            "i'll retry",
            "i will retry",
            "let me retry",
            "i'll attempt",
            "i will attempt",
            "i'll do that now",
            "i will do that now",
            "doing that now",
        };
        inline for (ascii_patterns) |pattern| {
            if (containsAsciiIgnoreCase(text, pattern)) return true;
        }

        const exact_patterns = [_][]const u8{
            "сейчас попробую",
            "Сейчас попробую",
            "попробую снова",
            "Попробую снова",
            "сейчас проверю",
            "Сейчас проверю",
            "сейчас сделаю",
            "Сейчас сделаю",
            "попробую переснять",
            "Попробую переснять",
            "сейчас перепроверю",
            "Сейчас перепроверю",
            "попробую ещё раз",
            "Попробую ещё раз",
        };
        inline for (exact_patterns) |pattern| {
            if (std.mem.indexOf(u8, text, pattern) != null) return true;
        }
        return false;
    }

    fn startsWithToolCallMarkup(text: []const u8) bool {
        const trimmed = std.mem.trimLeft(u8, text, " \t\r\n");
        return std.mem.startsWith(u8, trimmed, "<tool_call>");
    }

    fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var matched = true;
            var j: usize = 0;
            while (j < needle.len) : (j += 1) {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    fn isExecToolName(tool_name: []const u8) bool {
        return commands.isExecToolName(tool_name);
    }

    fn execBlockMessage(self: *Agent, args: std.json.ObjectMap) ?[]const u8 {
        return commands.execBlockMessage(self, args);
    }

    const PolicyPreflightResult = union(enum) {
        allowed,
        blocked: ToolExecutionResult,
    };

    const ParallelToolWorker = struct {
        agent: *Agent,
        call: ParsedToolCall,
        turn_ctx: tools_mod.RuntimeTurnContext,
        tenant_ctx: tools_mod.ToolTenantContext,
        message_ctx: tools_mod.MessageTurnContext,
        arena: std.heap.ArenaAllocator,
        result: ToolExecutionResult,
        duration_ms: u64 = 0,

        fn init(
            agent: *Agent,
            call: ParsedToolCall,
            turn_ctx: tools_mod.RuntimeTurnContext,
            tenant_ctx: tools_mod.ToolTenantContext,
            message_ctx: tools_mod.MessageTurnContext,
        ) ParallelToolWorker {
            return .{
                .agent = agent,
                .call = call,
                .turn_ctx = turn_ctx,
                .tenant_ctx = tenant_ctx,
                .message_ctx = message_ctx,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .result = .{
                    .name = call.name,
                    .output = "Tool execution did not run",
                    .success = false,
                    .tool_call_id = call.tool_call_id,
                },
            };
        }

        fn deinit(self: *ParallelToolWorker) void {
            self.arena.deinit();
        }

        fn run(self: *ParallelToolWorker) void {
            tools_mod.setTurnContext(self.turn_ctx);
            defer tools_mod.clearTurnContext();

            tools_mod.setTenantContext(self.tenant_ctx);
            defer tools_mod.clearTenantContext();

            tools_mod.setMessageTurnContext(self.message_ctx);
            defer tools_mod.clearMessageTurnContext();

            const worker_allocator = self.arena.allocator();
            const start_ms = std.time.milliTimestamp();
            self.result = self.agent.executeToolUnchecked(worker_allocator, self.call);
            self.duration_ms = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - start_ms)));
        }
    };

    fn effectiveToolDispatcherMode(self: *const Agent) ToolDispatcherMode {
        return tool_dispatcher.effectiveMode(self.parallel_tools, self.tool_dispatcher_mode);
    }

    fn shouldParallelDispatch(self: *const Agent, parsed_calls: []const ParsedToolCall) bool {
        if (parsed_calls.len < 2) return false;
        if (self.effectiveToolDispatcherMode() != .parallel) return false;
        if (!self.parallelDispatchCanaryAllowsSession()) return false;
        for (parsed_calls) |call| {
            if (!self.isParallelSafeToolCall(call)) return false;
        }
        return true;
    }

    fn parallelDispatchCanaryAllowsSession(self: *const Agent) bool {
        if (self.parallel_tools_rollout_percent >= 100) return true;
        if (self.parallel_tools_rollout_percent == 0) return false;
        const bucket = self.parallelDispatchSessionBucket();
        return bucket < self.parallel_tools_rollout_percent;
    }

    fn parallelDispatchSessionBucket(self: *const Agent) u8 {
        const seed = self.memory_session_id orelse self.workspace_dir;
        const hash = std.hash.Wyhash.hash(0, seed);
        return @intCast(hash % 100);
    }

    fn toolCallHasAction(allocator: std.mem.Allocator, arguments_json: []const u8, expected_action: []const u8) bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch return false;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |obj| obj,
            else => return false,
        };
        const raw = switch (object.get("action") orelse return false) {
            .string => |value| value,
            else => return false,
        };
        return std.mem.eql(u8, raw, expected_action);
    }

    fn isParallelSafeToolCall(self: *const Agent, call: ParsedToolCall) bool {
        if (std.mem.eql(u8, call.name, tools_mod.runtime_info.RuntimeInfoTool.tool_name)) return true;
        if (std.mem.eql(u8, call.name, tools_mod.file_read.FileReadTool.tool_name)) return true;
        if (std.mem.eql(u8, call.name, tools_mod.web_search.WebSearchTool.tool_name)) return true;
        if (std.mem.eql(u8, call.name, tools_mod.web_fetch.WebFetchTool.tool_name)) return true;

        if (std.mem.eql(u8, call.name, tools_mod.schedule.ScheduleTool.tool_name)) {
            return toolCallHasAction(self.allocator, call.arguments_json, "list") or
                toolCallHasAction(self.allocator, call.arguments_json, "get") or
                toolCallHasAction(self.allocator, call.arguments_json, "runs");
        }

        if (std.mem.eql(u8, call.name, tools_mod.composio.ComposioTool.tool_name)) {
            return toolCallHasAction(self.allocator, call.arguments_json, "list");
        }

        return false;
    }

    fn preflightToolPolicy(self: *Agent, call: ParsedToolCall) PolicyPreflightResult {
        if (self.policy) |pol| {
            if (!pol.canAct()) {
                return .{ .blocked = .{
                    .name = call.name,
                    .output = "Action blocked: agent is in read-only mode",
                    .success = false,
                    .tool_call_id = call.tool_call_id,
                } };
            }
            const allowed = pol.recordAction() catch true;
            if (!allowed) {
                return .{ .blocked = .{
                    .name = call.name,
                    .output = "Rate limit exceeded",
                    .success = false,
                    .tool_call_id = call.tool_call_id,
                } };
            }
        }
        return .allowed;
    }

    fn executeToolCallsSerial(
        self: *Agent,
        tool_allocator: std.mem.Allocator,
        parsed_calls: []const ParsedToolCall,
        results_buf: *std.ArrayListUnmanaged(ToolExecutionResult),
    ) !void {
        for (parsed_calls) |call| {
            const tool_start_event = ObserverEvent{ .tool_call_start = .{ .tool = call.name } };
            self.observer.recordEvent(&tool_start_event);

            const tool_timer = std.time.milliTimestamp();
            const result = self.executeTool(tool_allocator, call);
            const tool_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - tool_timer)));

            const tool_event = ObserverEvent{ .tool_call = .{
                .tool = call.name,
                .duration_ms = tool_duration,
                .success = result.success,
            } };
            self.observer.recordEvent(&tool_event);

            try results_buf.append(self.allocator, result);
        }
    }

    fn executeToolCallsParallel(
        self: *Agent,
        tool_allocator: std.mem.Allocator,
        parsed_calls: []const ParsedToolCall,
        results_buf: *std.ArrayListUnmanaged(ToolExecutionResult),
    ) !void {
        var worker_initialized = try self.allocator.alloc(bool, parsed_calls.len);
        defer self.allocator.free(worker_initialized);
        @memset(worker_initialized, false);

        var workers = try self.allocator.alloc(ParallelToolWorker, parsed_calls.len);
        defer {
            for (workers, 0..) |*worker, i| {
                if (worker_initialized[i]) worker.deinit();
            }
            self.allocator.free(workers);
        }

        var spawned = try self.allocator.alloc(bool, parsed_calls.len);
        defer self.allocator.free(spawned);
        @memset(spawned, false);

        var blocked = try self.allocator.alloc(bool, parsed_calls.len);
        defer self.allocator.free(blocked);
        @memset(blocked, false);

        var ordered_results = try self.allocator.alloc(ToolExecutionResult, parsed_calls.len);
        defer self.allocator.free(ordered_results);

        var ordered_durations = try self.allocator.alloc(u64, parsed_calls.len);
        defer self.allocator.free(ordered_durations);
        @memset(ordered_durations, 0);

        var threads = try self.allocator.alloc(std.Thread, parsed_calls.len);
        defer self.allocator.free(threads);

        const turn_ctx = tools_mod.getTurnContext();
        const tenant_ctx = tools_mod.getTenantContext();
        const message_ctx = tools_mod.message.MessageTool.getTurnContext();

        var force_serial_tail = false;

        for (parsed_calls, 0..) |call, i| {
            const tool_start_event = ObserverEvent{ .tool_call_start = .{ .tool = call.name } };
            self.observer.recordEvent(&tool_start_event);

            switch (self.preflightToolPolicy(call)) {
                .blocked => |result| {
                    blocked[i] = true;
                    ordered_results[i] = result;
                    continue;
                },
                .allowed => {},
            }

            if (force_serial_tail) {
                const start_ms = std.time.milliTimestamp();
                const result = self.executeToolUnchecked(tool_allocator, call);
                ordered_results[i] = result;
                ordered_durations[i] = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - start_ms)));
                continue;
            }

            workers[i] = ParallelToolWorker.init(self, call, turn_ctx, tenant_ctx, message_ctx);
            worker_initialized[i] = true;
            threads[i] = std.Thread.spawn(.{}, ParallelToolWorker.run, .{&workers[i]}) catch {
                const start_ms = std.time.milliTimestamp();
                const result = self.executeToolUnchecked(tool_allocator, call);
                ordered_results[i] = result;
                ordered_durations[i] = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - start_ms)));
                force_serial_tail = true;
                continue;
            };
            spawned[i] = true;
        }

        for (parsed_calls, 0..) |call, i| {
            if (blocked[i]) continue;
            if (!spawned[i]) continue;

            threads[i].join();
            ordered_durations[i] = workers[i].duration_ms;
            ordered_results[i] = .{
                .name = call.name,
                .output = try tool_allocator.dupe(u8, workers[i].result.output),
                .success = workers[i].result.success,
                .tool_call_id = call.tool_call_id,
            };
        }

        for (parsed_calls, 0..) |call, i| {
            const result = ordered_results[i];
            const tool_event = ObserverEvent{ .tool_call = .{
                .tool = call.name,
                .duration_ms = ordered_durations[i],
                .success = result.success,
            } };
            self.observer.recordEvent(&tool_event);
            try results_buf.append(self.allocator, result);
        }
    }

    pub fn formatModelStatus(self: *const Agent) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);

        try w.print("Current model: {s}\n", .{self.model_name});
        try w.print("Default model: {s}\n", .{self.default_model});
        try w.print("Default provider: {s}\n", .{self.default_provider});

        var provider_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer provider_names.deinit(self.allocator);
        try appendUniqueString(&provider_names, self.allocator, self.default_provider);
        for (self.configured_providers) |entry| {
            try appendUniqueString(&provider_names, self.allocator, entry.name);
        }
        for (self.fallback_providers) |fallback_name| {
            try appendUniqueString(&provider_names, self.allocator, fallback_name);
        }

        if (provider_names.items.len > 0) {
            try w.writeAll("\nProviders:\n");
            for (provider_names.items) |provider_name| {
                const is_default = std.mem.eql(u8, provider_name, self.default_provider);
                const is_fallback = self.providerIsFallback(provider_name);
                const role_label = if (is_default and is_fallback)
                    " [default,fallback]"
                else if (is_default)
                    " [default]"
                else if (is_fallback)
                    " [fallback]"
                else
                    "";
                try w.print("  - {s}{s} (auth: {s})\n", .{
                    provider_name,
                    role_label,
                    self.providerAuthStatus(provider_name),
                });
            }
        }

        var model_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer model_names.deinit(self.allocator);
        try appendUniqueString(&model_names, self.allocator, self.model_name);
        try appendUniqueString(&model_names, self.allocator, self.default_model);
        for (self.model_fallbacks) |entry| {
            try appendUniqueString(&model_names, self.allocator, entry.model);
            for (entry.fallbacks) |fallback_model| {
                try appendUniqueString(&model_names, self.allocator, fallback_model);
            }
        }

        if (model_names.items.len > 0) {
            try w.writeAll("\nModels:\n");
            for (model_names.items) |model_name| {
                const is_current = std.mem.eql(u8, model_name, self.model_name);
                const is_default = std.mem.eql(u8, model_name, self.default_model);
                const role_label = if (is_current and is_default)
                    " [current,default]"
                else if (is_current)
                    " [current]"
                else if (is_default)
                    " [default]"
                else
                    "";
                try w.print("  - {s}{s}\n", .{ model_name, role_label });
            }
        }

        try w.writeAll("\nProvider chain: ");
        try w.writeAll(self.default_provider);
        if (self.fallback_providers.len == 0) {
            try w.writeAll(" (no fallback providers)");
        } else {
            for (self.fallback_providers) |fallback_provider| {
                try w.print(" -> {s}", .{fallback_provider});
            }
        }

        try w.writeAll("\nModel chain: ");
        try w.writeAll(self.model_name);
        if (self.currentModelFallbacks()) |fallbacks| {
            for (fallbacks) |fallback_model| {
                try w.print(" -> {s}", .{fallback_model});
            }
        } else {
            try w.writeAll(" (no configured fallbacks)");
        }

        try w.writeAll("\nSwitch: /model <name>");
        return try out.toOwnedSlice(self.allocator);
    }

    /// Handle slash commands that don't require LLM.
    /// Returns an owned response string, or null if not a slash command.
    pub fn handleSlashCommand(self: *Agent, message: []const u8) !?[]const u8 {
        return commands.handleSlashCommand(self, message);
    }

    /// Execute a single conversation turn: send messages to LLM, parse tool calls,
    /// execute tools, and loop until a final text response is produced.
    pub fn turn(self: *Agent, user_message: []const u8) ![]const u8 {
        const turn_start_ms = std.time.milliTimestamp();
        self.context_was_compacted = false;
        commands.refreshSubagentToolContext(self);

        // Handle slash commands before sending to LLM (saves tokens)
        if (try self.handleSlashCommand(user_message)) |response| {
            return response;
        }

        // Inject system prompt on first turn (or when tracked workspace files changed).
        const current_time_bucket_min = @divFloor(std.time.timestamp(), 60);
        const workspace_fp = prompt.workspacePromptFingerprint(self.allocator, self.workspace_dir) catch null;
        if (self.has_system_prompt and workspace_fp != null and self.workspace_prompt_fingerprint != workspace_fp) {
            self.has_system_prompt = false;
        }
        if (self.has_system_prompt and self.system_prompt_time_bucket_min != current_time_bucket_min) {
            self.has_system_prompt = false;
        }

        const turn_has_conversation_context = self.conversation_context != null;
        const conversation_context_fingerprint = conversationContextFingerprint(self.conversation_context);
        const conversation_context_changed = self.has_system_prompt and
            self.system_prompt_conversation_context_fingerprint != conversation_context_fingerprint;

        if (!self.has_system_prompt or conversation_context_changed) {
            var cfg_for_caps_opt: ?Config = Config.load(self.allocator) catch null;
            defer if (cfg_for_caps_opt) |*cfg_loaded| cfg_loaded.deinit();
            const cfg_for_caps_ptr: ?*const Config = if (cfg_for_caps_opt) |*cfg_loaded| cfg_loaded else null;

            const capabilities_section = capabilities_mod.buildPromptSection(
                self.allocator,
                cfg_for_caps_ptr,
                self.tools,
            ) catch null;
            defer if (capabilities_section) |section| self.allocator.free(section);

            const system_prompt = try prompt.buildSystemPrompt(self.allocator, .{
                .workspace_dir = self.workspace_dir,
                .model_name = self.model_name,
                .tools = self.tools,
                .capabilities_section = capabilities_section,
                .conversation_context = self.conversation_context,
            });
            defer self.allocator.free(system_prompt);

            // Append tool instructions
            const tool_instructions = try dispatcher.buildToolInstructions(self.allocator, self.tools);
            defer self.allocator.free(tool_instructions);

            const full_system = try self.allocator.alloc(u8, system_prompt.len + tool_instructions.len);
            @memcpy(full_system[0..system_prompt.len], system_prompt);
            @memcpy(full_system[system_prompt.len..], tool_instructions);

            // Keep exactly one canonical system prompt at history[0].
            // This allows /model to invalidate and refresh the prompt in place.
            if (self.history.items.len > 0 and self.history.items[0].role == .system) {
                self.history.items[0].deinit(self.allocator);
                self.history.items[0] = .{
                    .role = .system,
                    .content = full_system,
                };
            } else if (self.history.items.len > 0) {
                try self.history.insert(self.allocator, 0, .{
                    .role = .system,
                    .content = full_system,
                });
            } else {
                try self.history.append(self.allocator, .{
                    .role = .system,
                    .content = full_system,
                });
            }
            self.has_system_prompt = true;
            self.system_prompt_has_conversation_context = turn_has_conversation_context;
            self.system_prompt_conversation_context_fingerprint = conversation_context_fingerprint;
            self.workspace_prompt_fingerprint = workspace_fp;
            self.system_prompt_time_bucket_min = current_time_bucket_min;
        }

        // Auto-save user message to memory (nanoTimestamp key to avoid collisions within the same second)
        if (self.auto_save) {
            if (self.mem) |mem| {
                const ts: u128 = @bitCast(std.time.nanoTimestamp());
                const save_key = std.fmt.allocPrint(self.allocator, "autosave_user_{d}", .{ts}) catch null;
                if (save_key) |key| {
                    defer self.allocator.free(key);
                    if (mem.store(key, user_message, .conversation, self.memory_session_id)) |_| {
                        // Vector sync after auto-save
                        if (self.mem_rt) |rt| {
                            rt.syncVectorAfterStore(self.allocator, key, user_message);
                        }
                    } else |_| {}
                }
            }
        }

        // Enrich message with memory context (always returns owned slice; ownership → history)
        // Uses retrieval pipeline (hybrid search, RRF, temporal decay, MMR) when MemoryRuntime is available.
        const enrich_start_ms = std.time.milliTimestamp();
        const enriched = if (self.mem) |mem|
            try memory_loader.enrichMessageWithRuntime(self.allocator, mem, self.mem_rt, user_message, self.memory_session_id)
        else
            try self.allocator.dupe(u8, user_message);
        const enrich_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - enrich_start_ms));
        log.info("turn.stage stage=memory_enrich duration_ms={d}", .{enrich_duration_ms});
        const memory_stage_event = ObserverEvent{ .turn_stage = .{
            .stage = "memory_enrich",
            .duration_ms = enrich_duration_ms,
        } };
        self.observer.recordEvent(&memory_stage_event);
        errdefer self.allocator.free(enriched);

        try self.history.append(self.allocator, .{
            .role = .user,
            .content = enriched,
        });

        if (self.compact_context_enabled) {
            const compact_start_ms = std.time.milliTimestamp();
            _ = self.autoCompactHistory() catch false;
            const compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - compact_start_ms));
            log.info("turn.stage stage=compact_pre_provider duration_ms={d}", .{compact_duration_ms});
            const compact_stage_event = ObserverEvent{ .turn_stage = .{
                .stage = "compact_pre_provider",
                .duration_ms = compact_duration_ms,
            } };
            self.observer.recordEvent(&compact_stage_event);
        }

        // ── Response/Semantic cache check ──
        var key_buf: [16]u8 = undefined;
        const system_prompt = if (self.history.items.len > 0 and self.history.items[0].role == .system)
            self.history.items[0].content
        else
            null;
        const key_hex = cache.ResponseCache.cacheKeyHex(&key_buf, self.model_name, system_prompt, user_message);

        if (self.mem_rt) |rt| {
            if (rt.semanticCache()) |sc| {
                if (sc.get(self.allocator, key_hex, user_message) catch null) |cached_hit| {
                    errdefer self.allocator.free(cached_hit.response);
                    const history_copy = try self.allocator.dupe(u8, cached_hit.response);
                    errdefer self.allocator.free(history_copy);
                    try self.history.append(self.allocator, .{
                        .role = .assistant,
                        .content = history_copy,
                    });
                    // Keep cache-hit turns bounded too; otherwise history can grow
                    // unbounded when many turns short-circuit before finalize.
                    self.last_turn_compacted = false;
                    self.trimHistory();
                    return cached_hit.response;
                }
            }
        }

        if (self.response_cache) |rc| {
            if (rc.get(self.allocator, key_hex) catch null) |cached_response| {
                errdefer self.allocator.free(cached_response);
                const history_copy = try self.allocator.dupe(u8, cached_response);
                errdefer self.allocator.free(history_copy);
                try self.history.append(self.allocator, .{
                    .role = .assistant,
                    .content = history_copy,
                });
                // Keep cache-hit turns bounded too; otherwise history can grow
                // unbounded when many turns short-circuit before finalize.
                self.last_turn_compacted = false;
                self.trimHistory();
                return cached_response;
            }
        }

        // Record agent event
        const start_event = ObserverEvent{ .llm_request = .{
            .provider = self.provider.getName(),
            .model = self.model_name,
            .messages_count = self.history.items.len,
        } };
        self.observer.recordEvent(&start_event);

        // Tool call loop — reuse a single arena across iterations (retains pages)
        var iter_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer iter_arena.deinit();

        var iteration: u32 = 0;
        var forced_follow_through_count: u32 = 0;
        while (iteration < self.max_tool_iterations) : (iteration += 1) {
            _ = iter_arena.reset(.retain_capacity);
            const arena = iter_arena.allocator();

            // Build messages slice for provider (arena-owned; freed at end of iteration)
            const build_messages_start_ms = std.time.milliTimestamp();
            const messages = try self.buildProviderMessages(arena);
            const build_messages_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - build_messages_start_ms));
            log.info("turn.stage stage=build_provider_messages iteration={d} duration_ms={d} history_messages={d}", .{
                iteration,
                build_messages_duration_ms,
                self.history.items.len,
            });
            const build_stage_event = ObserverEvent{ .turn_stage = .{
                .stage = "build_provider_messages",
                .iteration = iteration,
                .duration_ms = build_messages_duration_ms,
                .count = @intCast(@min(self.history.items.len, std.math.maxInt(u32))),
            } };
            self.observer.recordEvent(&build_stage_event);

            const timer_start = std.time.milliTimestamp();
            const is_streaming = self.stream_callback != null and self.provider.supportsStreaming();

            // Call provider: streaming (no retries, no native tools) or blocking with retry
            var response: ChatResponse = undefined;
            if (is_streaming) {
                const stream_result = self.provider.streamChat(
                    self.allocator,
                    .{
                        .messages = messages,
                        .model = self.model_name,
                        .temperature = self.temperature,
                        .max_tokens = self.max_tokens,
                        .tools = null,
                        .timeout_secs = self.message_timeout_secs,
                        .reasoning_effort = self.reasoning_effort,
                    },
                    self.model_name,
                    self.temperature,
                    self.stream_callback.?,
                    self.stream_ctx.?,
                ) catch |err| {
                    log.warn("llm.call failed provider={s} model={s} error={s}", .{
                        self.provider.getName(),
                        self.model_name,
                        @errorName(err),
                    });
                    const fail_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
                    const fail_event = ObserverEvent{ .llm_response = .{
                        .provider = self.provider.getName(),
                        .model = self.model_name,
                        .duration_ms = fail_duration,
                        .success = false,
                        .error_message = @errorName(err),
                    } };
                    self.observer.recordEvent(&fail_event);
                    return err;
                };
                response = ChatResponse{
                    .content = stream_result.content,
                    .tool_calls = &.{},
                    .usage = stream_result.usage,
                    .model = stream_result.model,
                };
            } else {
                response = self.provider.chat(
                    self.allocator,
                    .{
                        .messages = messages,
                        .model = self.model_name,
                        .temperature = self.temperature,
                        .max_tokens = self.max_tokens,
                        .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                        .timeout_secs = self.message_timeout_secs,
                        .reasoning_effort = self.reasoning_effort,
                    },
                    self.model_name,
                    self.temperature,
                ) catch |err| retry_blk: {
                    log.warn("llm.call failed provider={s} model={s} error={s}", .{
                        self.provider.getName(),
                        self.model_name,
                        @errorName(err),
                    });
                    // Record the failed attempt
                    const fail_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
                    const fail_event = ObserverEvent{ .llm_response = .{
                        .provider = self.provider.getName(),
                        .model = self.model_name,
                        .duration_ms = fail_duration,
                        .success = false,
                        .error_message = @errorName(err),
                    } };
                    self.observer.recordEvent(&fail_event);

                    // Context exhaustion: compact immediately before first retry
                    const err_name = @errorName(err);
                    if (providers.reliable.isContextExhausted(err_name) and
                        self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and
                        self.forceCompressHistory())
                    {
                        self.context_was_compacted = true;
                        const recovery_msgs = self.buildProviderMessages(arena) catch |prep_err| return prep_err;
                        break :retry_blk self.provider.chat(
                            self.allocator,
                            .{
                                .messages = recovery_msgs,
                                .model = self.model_name,
                                .temperature = self.temperature,
                                .max_tokens = self.max_tokens,
                                .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                                .timeout_secs = self.message_timeout_secs,
                                .reasoning_effort = self.reasoning_effort,
                            },
                            self.model_name,
                            self.temperature,
                        ) catch return err;
                    }

                    // Retry once
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    break :retry_blk self.provider.chat(
                        self.allocator,
                        .{
                            .messages = messages,
                            .model = self.model_name,
                            .temperature = self.temperature,
                            .max_tokens = self.max_tokens,
                            .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                            .timeout_secs = self.message_timeout_secs,
                            .reasoning_effort = self.reasoning_effort,
                        },
                        self.model_name,
                        self.temperature,
                    ) catch |retry_err| {
                        // Context exhaustion recovery: if we have enough history,
                        // force-compress and retry once more
                        if (self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and self.forceCompressHistory()) {
                            self.context_was_compacted = true;
                            const recovery_msgs = self.buildProviderMessages(arena) catch |prep_err| return prep_err;
                            break :retry_blk self.provider.chat(
                                self.allocator,
                                .{
                                    .messages = recovery_msgs,
                                    .model = self.model_name,
                                    .temperature = self.temperature,
                                    .max_tokens = self.max_tokens,
                                    .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                                    .timeout_secs = self.message_timeout_secs,
                                    .reasoning_effort = self.reasoning_effort,
                                },
                                self.model_name,
                                self.temperature,
                            ) catch return retry_err;
                        }
                        return retry_err;
                    };
                };
            }

            const duration_ms: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
            const resp_event = ObserverEvent{ .llm_response = .{
                .provider = self.provider.getName(),
                .model = self.model_name,
                .duration_ms = duration_ms,
                .success = true,
                .error_message = null,
            } };
            self.observer.recordEvent(&resp_event);

            // Track tokens
            self.total_tokens += response.usage.total_tokens;
            self.last_turn_usage = response.usage;

            const response_text = response.contentOrEmpty();
            const use_native = response.hasToolCalls();

            // Determine tool calls: structured (native) first, then XML fallback.
            // Keep the same loop semantics used by the reference runtime.
            var parsed_calls: []ParsedToolCall = &.{};
            var parsed_text: []const u8 = "";
            var assistant_history_content: []const u8 = "";

            // Track what we need to free
            var free_parsed_calls = false;
            var free_parsed_text = false;
            var free_assistant_history = false;

            defer {
                if (free_parsed_calls) {
                    for (parsed_calls) |call| {
                        self.allocator.free(call.name);
                        self.allocator.free(call.arguments_json);
                        if (call.tool_call_id) |id| self.allocator.free(id);
                    }
                    self.allocator.free(parsed_calls);
                }
                if (free_parsed_text and parsed_text.len > 0) self.allocator.free(parsed_text);
                if (free_assistant_history and assistant_history_content.len > 0) self.allocator.free(assistant_history_content);
            }

            if (use_native) {
                const parse_start_ms = std.time.milliTimestamp();
                // Provider returned structured tool_calls — convert them
                parsed_calls = try dispatcher.parseStructuredToolCalls(self.allocator, response.tool_calls);
                free_parsed_calls = true;

                if (parsed_calls.len == 0) {
                    // Structured calls were empty (e.g. all had empty names) — try XML fallback
                    self.allocator.free(parsed_calls);
                    free_parsed_calls = false;

                    const xml_parsed = try dispatcher.parseToolCalls(self.allocator, response_text);
                    parsed_calls = xml_parsed.calls;
                    free_parsed_calls = true;
                    parsed_text = xml_parsed.text;
                    free_parsed_text = true;
                }

                // Build history content with serialized tool calls
                assistant_history_content = try dispatcher.buildAssistantHistoryWithToolCalls(
                    self.allocator,
                    response_text,
                    parsed_calls,
                );
                free_assistant_history = true;
                const parse_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - parse_start_ms));
                log.info("turn.stage stage=parse_provider_response iteration={d} duration_ms={d} tool_calls={d}", .{
                    iteration,
                    parse_duration_ms,
                    parsed_calls.len,
                });
                const parse_stage_event = ObserverEvent{ .turn_stage = .{
                    .stage = "parse_provider_response",
                    .iteration = iteration,
                    .duration_ms = parse_duration_ms,
                    .count = @intCast(@min(parsed_calls.len, std.math.maxInt(u32))),
                } };
                self.observer.recordEvent(&parse_stage_event);
            } else {
                const parse_start_ms = std.time.milliTimestamp();
                // No native tool calls — parse response text for XML tool calls
                const xml_parsed = try dispatcher.parseToolCalls(self.allocator, response_text);
                parsed_calls = xml_parsed.calls;
                free_parsed_calls = true;
                parsed_text = xml_parsed.text;
                free_parsed_text = true;
                // For XML path, store the raw response text as history
                assistant_history_content = response_text;
                const parse_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - parse_start_ms));
                log.info("turn.stage stage=parse_provider_response iteration={d} duration_ms={d} tool_calls={d}", .{
                    iteration,
                    parse_duration_ms,
                    parsed_calls.len,
                });
                const parse_stage_event = ObserverEvent{ .turn_stage = .{
                    .stage = "parse_provider_response",
                    .iteration = iteration,
                    .duration_ms = parse_duration_ms,
                    .count = @intCast(@min(parsed_calls.len, std.math.maxInt(u32))),
                } };
                self.observer.recordEvent(&parse_stage_event);
            }

            // Determine display text
            const display_text = if (parsed_text.len > 0) parsed_text else response_text;

            if (parsed_calls.len == 0) {
                const malformed_tool_markup = startsWithToolCallMarkup(display_text);
                // Guardrail: if the model promises "I'll try/check now" but emits no
                // tool call, force one follow-up completion to either act now or
                // explicitly state the limitation without deferred promises.
                if (!is_streaming and
                    forced_follow_through_count < 2 and
                    iteration + 1 < self.max_tool_iterations and
                    (shouldForceActionFollowThrough(display_text) or malformed_tool_markup))
                {
                    const follow_up_instruction = if (malformed_tool_markup)
                        "SYSTEM: Your previous response started with <tool_call> markup but no valid tool call was executed. " ++
                            "Emit valid, closed <tool_call>...</tool_call> tags now for each tool action. " ++
                            "If no tool is needed, answer in plain text with no <tool_call> tags."
                    else
                        "SYSTEM: You just promised to take action now (for example: \"I'll try/check now\"). " ++
                            "Do it in this turn by issuing the appropriate tool call(s). " ++
                            "If no tool can perform it, respond with a clear limitation now and do not promise another future attempt.";
                    try self.history.append(self.allocator, .{
                        .role = .assistant,
                        .content = try self.allocator.dupe(u8, display_text),
                    });
                    try self.history.append(self.allocator, .{
                        .role = .user,
                        .content = try self.allocator.dupe(u8, follow_up_instruction),
                    });
                    self.trimHistory();
                    self.freeResponseFields(&response);
                    forced_follow_through_count += 1;
                    continue;
                }

                // No tool calls — final response
                const safe_display_text = if (malformed_tool_markup)
                    "I hit an internal tool-call formatting error before execution. Please retry."
                else
                    display_text;
                const finalize_start_ms = std.time.milliTimestamp();
                const base_text = if (self.context_was_compacted) blk: {
                    self.context_was_compacted = false;
                    break :blk try std.fmt.allocPrint(self.allocator, "[Context compacted]\n\n{s}", .{safe_display_text});
                } else try self.allocator.dupe(u8, safe_display_text);
                errdefer self.allocator.free(base_text);

                const compose_start_ms = std.time.milliTimestamp();
                const final_text = try self.composeFinalReply(base_text, response.reasoning_content, response.usage);
                const compose_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - compose_start_ms));
                log.info("turn.stage stage=compose_final_reply iteration={d} duration_ms={d}", .{ iteration, compose_duration_ms });
                const compose_stage_event = ObserverEvent{ .turn_stage = .{
                    .stage = "compose_final_reply",
                    .iteration = iteration,
                    .duration_ms = compose_duration_ms,
                } };
                self.observer.recordEvent(&compose_stage_event);
                errdefer self.allocator.free(final_text);

                var tts_audio_reply_text: ?[]u8 = null;
                errdefer if (tts_audio_reply_text) |value| self.allocator.free(value);
                const tts_start_ms = std.time.milliTimestamp();
                if (try self.prepareTtsPayload(self.allocator, user_message, final_text)) |tts_payload| {
                    defer self.allocator.free(tts_payload);
                    const tts_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - tts_start_ms));
                    log.info("turn.stage stage=tts_prepare iteration={d} duration_ms={d} chars={d} provider={s} audio={s}", .{
                        iteration,
                        tts_duration_ms,
                        tts_payload.len,
                        self.ttsProviderName(),
                        if (self.tts_audio) "on" else "off",
                    });
                    const tts_stage_event = ObserverEvent{ .turn_stage = .{
                        .stage = "tts_prepare",
                        .iteration = iteration,
                        .duration_ms = tts_duration_ms,
                        .count = @intCast(@min(tts_payload.len, std.math.maxInt(u32))),
                    } };
                    self.observer.recordEvent(&tts_stage_event);

                    if (try self.maybeBuildTtsAudioReply(self.allocator, tts_payload, final_text)) |audio_reply| {
                        tts_audio_reply_text = audio_reply;
                    }
                } else {
                    const tts_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - tts_start_ms));
                    log.info("turn.stage stage=tts_prepare iteration={d} duration_ms={d} chars=0 provider={s} audio={s}", .{
                        iteration,
                        tts_duration_ms,
                        self.ttsProviderName(),
                        if (self.tts_audio) "on" else "off",
                    });
                }

                // Dupe from display_text directly (not from final_text) to avoid double-dupe
                try self.history.append(self.allocator, .{
                    .role = .assistant,
                    .content = try self.allocator.dupe(u8, safe_display_text),
                });

                // Keep interactive turns fast: trim history here, but defer
                // expensive provider-backed compaction to explicit/overflow paths.
                const compact_start_ms = std.time.milliTimestamp();
                self.last_turn_compacted = false;
                self.trimHistory();
                const compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - compact_start_ms));
                log.info("turn.stage stage=compact_trim iteration={d} duration_ms={d} compacted={}", .{
                    iteration,
                    compact_duration_ms,
                    self.last_turn_compacted,
                });

                // Auto-save assistant response
                const autosave_start_ms = std.time.milliTimestamp();
                if (self.auto_save) {
                    if (self.mem) |mem| {
                        // Truncate to ~100 bytes on a valid UTF-8 boundary
                        const summary = if (base_text.len > 100) blk: {
                            var end: usize = 100;
                            while (end > 0 and base_text[end] & 0xC0 == 0x80) end -= 1;
                            break :blk base_text[0..end];
                        } else base_text;
                        const ts: u128 = @bitCast(std.time.nanoTimestamp());
                        const save_key = std.fmt.allocPrint(self.allocator, "autosave_assistant_{d}", .{ts}) catch null;
                        if (save_key) |key| {
                            defer self.allocator.free(key);
                            if (mem.store(key, summary, .conversation, self.memory_session_id)) |_| {
                                // Vector sync after auto-save
                                if (self.mem_rt) |rt| {
                                    rt.syncVectorAfterStore(self.allocator, key, summary);
                                }
                            } else |_| {}
                        }
                    }
                }
                const autosave_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - autosave_start_ms));
                log.info("turn.stage stage=autosave_assistant iteration={d} duration_ms={d}", .{ iteration, autosave_duration_ms });

                // Drain durable outbox after turn completion (best-effort)
                const outbox_start_ms = std.time.milliTimestamp();
                if (self.mem_rt) |rt| {
                    _ = rt.drainOutbox(self.allocator);
                }
                const outbox_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - outbox_start_ms));
                log.info("turn.stage stage=drain_outbox iteration={d} duration_ms={d}", .{ iteration, outbox_duration_ms });

                const complete_event = ObserverEvent{ .turn_complete = {} };
                self.observer.recordEvent(&complete_event);

                // Free provider response fields (content, tool_calls, model)
                // All borrows have been duped into final_text and history at this point.
                self.freeResponseFields(&response);
                self.allocator.free(base_text);

                // ── Cache store (only for direct responses, no tool calls) ──
                const cache_start_ms = std.time.milliTimestamp();
                var cached = false;
                var store_key_buf: [16]u8 = undefined;
                const sys_prompt = if (self.history.items.len > 0 and self.history.items[0].role == .system)
                    self.history.items[0].content
                else
                    null;
                const store_key_hex = cache.ResponseCache.cacheKeyHex(&store_key_buf, self.model_name, sys_prompt, user_message);
                const token_count: u32 = @intCast(@min(self.last_turn_usage.total_tokens, std.math.maxInt(u32)));

                if (self.mem_rt) |rt| {
                    if (rt.semanticCache()) |sc| {
                        sc.put(
                            self.allocator,
                            store_key_hex,
                            self.model_name,
                            final_text,
                            token_count,
                            user_message,
                        ) catch {};
                        cached = true;
                    }
                }

                if (self.response_cache) |rc| {
                    rc.put(self.allocator, store_key_hex, self.model_name, final_text, token_count) catch {};
                    cached = true;
                }

                if (cached) {
                    const cache_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - cache_start_ms));
                    log.info("turn.stage stage=response_cache_put iteration={d} duration_ms={d}", .{ iteration, cache_duration_ms });
                }

                const finalize_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - finalize_start_ms));
                const total_turn_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - turn_start_ms));
                log.info("turn.stage stage=finalize_no_tools iteration={d} duration_ms={d} total_turn_ms={d}", .{
                    iteration,
                    finalize_duration_ms,
                    total_turn_ms,
                });
                const finalize_stage_event = ObserverEvent{ .turn_stage = .{
                    .stage = "finalize_no_tools",
                    .iteration = iteration,
                    .duration_ms = finalize_duration_ms,
                } };
                self.observer.recordEvent(&finalize_stage_event);

                if (tts_audio_reply_text) |audio_reply| {
                    self.allocator.free(final_text);
                    return audio_reply;
                }
                return final_text;
            }

            // There are tool calls — print intermediary text.
            // In tests, stdout is used by Zig's test runner protocol (`--listen`),
            // so avoid writing arbitrary text that can corrupt the control channel.
            if (!builtin.is_test and display_text.len > 0 and parsed_calls.len > 0 and !is_streaming) {
                var out_buf: [4096]u8 = undefined;
                var bw = std.fs.File.stdout().writer(&out_buf);
                const w = &bw.interface;
                w.print("{s}", .{display_text}) catch {};
                w.flush() catch {};
            }

            // Record assistant message with tool calls in history.
            // Native path (free_assistant_history=true): transfer ownership directly to avoid
            // a redundant allocation; clear the flag so the outer defer does not double-free.
            // XML path (free_assistant_history=false): response_text is not owned, must dupe.
            const assistant_content: []const u8 = if (free_assistant_history) blk: {
                free_assistant_history = false;
                break :blk assistant_history_content;
            } else try self.allocator.dupe(u8, assistant_history_content);
            errdefer self.allocator.free(assistant_content);

            try self.history.append(self.allocator, .{
                .role = .assistant,
                .content = assistant_content,
            });

            // Execute tool calls (serial by default, optional parallel dispatcher)
            var results_buf: std.ArrayListUnmanaged(ToolExecutionResult) = .empty;
            defer results_buf.deinit(self.allocator);
            try results_buf.ensureTotalCapacity(self.allocator, parsed_calls.len);
            const dispatch_start_ms = std.time.milliTimestamp();
            const used_parallel_dispatch = self.shouldParallelDispatch(parsed_calls);
            if (used_parallel_dispatch) {
                try self.executeToolCallsParallel(arena, parsed_calls, &results_buf);
            } else {
                try self.executeToolCallsSerial(arena, parsed_calls, &results_buf);
            }
            const dispatch_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - dispatch_start_ms));
            log.info("turn.stage stage=dispatch_tools iteration={d} duration_ms={d} mode={s} calls={d}", .{
                iteration,
                dispatch_duration_ms,
                if (used_parallel_dispatch) "parallel" else "serial",
                parsed_calls.len,
            });

            // Format tool results, scrub credentials, add reflection prompt, and add to history
            const reflect_start_ms = std.time.milliTimestamp();
            const formatted_results = try dispatcher.formatToolResults(arena, results_buf.items);
            const scrubbed_results = try providers.scrubToolOutput(arena, formatted_results);
            const with_reflection = try std.fmt.allocPrint(
                arena,
                "{s}\n\nReflect on the tool results above and decide your next steps. " ++
                    "If a tool failed due to policy/permissions, do not repeat the same blocked call; explain the limitation and choose a different available tool or ask the user for permission/config change. " ++
                    "If a tool failed due to a transient issue (timeout/network/rate-limit), proactively retry up to 2 times with adjusted parameters before giving up. " ++
                    "If a tool reports queued/async delivery, state it as queued (not confirmed delivered) unless a later tool confirms delivery.",
                .{scrubbed_results},
            );
            try self.history.append(self.allocator, .{
                .role = .user,
                .content = try self.allocator.dupe(u8, with_reflection),
            });
            const reflect_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - reflect_start_ms));
            log.info("turn.stage stage=tool_reflection iteration={d} duration_ms={d} results={d}", .{
                iteration,
                reflect_duration_ms,
                results_buf.items.len,
            });
            const reflect_stage_event = ObserverEvent{ .turn_stage = .{
                .stage = "tool_reflection",
                .iteration = iteration,
                .duration_ms = reflect_duration_ms,
                .count = @intCast(@min(results_buf.items.len, std.math.maxInt(u32))),
            } };
            self.observer.recordEvent(&reflect_stage_event);

            const trim_start_ms = std.time.milliTimestamp();
            self.trimHistory();
            const trim_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - trim_start_ms));
            log.info("turn.stage stage=trim_history_after_tools iteration={d} duration_ms={d}", .{ iteration, trim_duration_ms });

            // Free provider response fields now that all borrows are consumed.
            self.freeResponseFields(&response);
        }

        // ── Graceful degradation: tool iterations exhausted ──────────
        // Instead of returning an error, ask the LLM to summarize what it
        // has accomplished so far and return that as the final response.
        const exhausted_event = ObserverEvent{ .tool_iterations_exhausted = .{ .iterations = self.max_tool_iterations } };
        self.observer.recordEvent(&exhausted_event);
        log.warn("Tool iterations exhausted ({d}/{d}), requesting summary", .{ self.max_tool_iterations, self.max_tool_iterations });

        // Append a pseudo-user message forcing a text-only summary
        try self.history.append(self.allocator, .{
            .role = .user,
            .content = try self.allocator.dupe(u8, "SYSTEM: You have reached the maximum number of tool iterations. " ++
                "You MUST NOT call any more tools. Summarize what you have accomplished " ++
                "so far and what remains to be done. Respond in the same language the user used."),
        });

        // Build messages for the summary call
        const summary_messages = self.buildMessageSlice() catch {
            const fallback = try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ self.max_tool_iterations, self.max_tool_iterations });
            const complete_event = ObserverEvent{ .turn_complete = {} };
            self.observer.recordEvent(&complete_event);
            return fallback;
        };
        defer self.allocator.free(summary_messages);

        var summary_response = self.provider.chat(
            self.allocator,
            .{
                .messages = summary_messages,
                .model = self.model_name,
                .temperature = self.temperature,
                .max_tokens = self.max_tokens,
                .tools = null, // force text-only
                .timeout_secs = self.message_timeout_secs,
                .reasoning_effort = self.reasoning_effort,
            },
            self.model_name,
            self.temperature,
        ) catch {
            const fallback = try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ self.max_tool_iterations, self.max_tool_iterations });
            const complete_event = ObserverEvent{ .turn_complete = {} };
            self.observer.recordEvent(&complete_event);
            return fallback;
        };
        defer self.freeResponseFields(&summary_response);

        const summary_text = summary_response.contentOrEmpty();
        const prefixed = try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}]\n\n{s}", .{ self.max_tool_iterations, self.max_tool_iterations, summary_text });
        errdefer self.allocator.free(prefixed);

        // Store in history (dupe the raw summary, not the prefixed version)
        try self.history.append(self.allocator, .{
            .role = .assistant,
            .content = try self.allocator.dupe(u8, summary_text),
        });

        // Compact/trim history so the next turn doesn't start with bloated context
        self.last_turn_compacted = self.autoCompactHistory() catch false;
        self.trimHistory();

        const complete_event = ObserverEvent{ .turn_complete = {} };
        self.observer.recordEvent(&complete_event);

        return prefixed;
    }

    /// Execute a tool by name lookup.
    /// Parses arguments_json once into a std.json.ObjectMap and passes it to the tool.
    fn executeTool(self: *Agent, tool_allocator: std.mem.Allocator, call: ParsedToolCall) ToolExecutionResult {
        return switch (self.preflightToolPolicy(call)) {
            .allowed => self.executeToolUnchecked(tool_allocator, call),
            .blocked => |result| result,
        };
    }

    fn executeToolUnchecked(self: *Agent, tool_allocator: std.mem.Allocator, call: ParsedToolCall) ToolExecutionResult {
        if (std.mem.eql(u8, call.name, tools_mod.message.MessageTool.tool_name)) {
            const turn_ctx = tools_mod.getTurnContext();
            if (tools_mod.isBackgroundTurnOrigin(turn_ctx.origin) and self.send_mode == .off) {
                return .{
                    .name = call.name,
                    .output = "Proactive sends are disabled (send_mode=off)",
                    .success = false,
                    .tool_call_id = call.tool_call_id,
                };
            }
        }

        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name(), call.name)) {
                // Parse arguments JSON to ObjectMap ONCE
                const parsed = std.json.parseFromSlice(
                    std.json.Value,
                    tool_allocator,
                    call.arguments_json,
                    .{},
                ) catch {
                    return .{
                        .name = call.name,
                        .output = "Invalid arguments JSON",
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                };
                defer parsed.deinit();

                const args: std.json.ObjectMap = switch (parsed.value) {
                    .object => |o| o,
                    else => {
                        return .{
                            .name = call.name,
                            .output = "Arguments must be a JSON object",
                            .success = false,
                            .tool_call_id = call.tool_call_id,
                        };
                    },
                };

                if (isExecToolName(call.name)) {
                    if (self.execBlockMessage(args)) |msg| {
                        return .{
                            .name = call.name,
                            .output = msg,
                            .success = false,
                            .tool_call_id = call.tool_call_id,
                        };
                    }
                }

                if (tools_mod.toolBlockedForCurrentTurn(call.name, args)) |msg| {
                    return .{
                        .name = call.name,
                        .output = msg,
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                }

                const result = t.execute(tool_allocator, args) catch |err| {
                    return .{
                        .name = call.name,
                        .output = @errorName(err),
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                };
                return .{
                    .name = call.name,
                    .output = if (result.success) result.output else (result.error_msg orelse result.output),
                    .success = result.success,
                    .tool_call_id = call.tool_call_id,
                };
            }
        }

        return .{
            .name = call.name,
            .output = "Unknown tool",
            .success = false,
            .tool_call_id = call.tool_call_id,
        };
    }

    /// Build provider-ready ChatMessage slice from owned history.
    /// Applies multimodal preprocessing.
    fn buildProviderMessages(self: *Agent, arena: std.mem.Allocator) ![]ChatMessage {
        const m = try arena.alloc(ChatMessage, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            m[i] = msg.toChatMessage();
        }

        // Allow local multimodal reads from:
        // - workspace (e.g. screenshot tool output),
        // - autonomy.allowed_paths,
        // - platform temp dir (e.g. Telegram downloaded files).
        var allowed_dirs_list: std.ArrayListUnmanaged([]const u8) = .empty;
        try appendMultimodalAllowedDir(arena, &allowed_dirs_list, self.workspace_dir);
        for (self.allowed_paths) |dir| {
            try appendMultimodalAllowedDir(arena, &allowed_dirs_list, dir);
        }
        if (platform.getTempDir(arena) catch null) |tmp_dir| {
            try appendMultimodalAllowedDir(arena, &allowed_dirs_list, tmp_dir);
        }
        const allowed = try allowed_dirs_list.toOwnedSlice(arena);

        return multimodal.prepareMessagesForProvider(arena, m, .{
            .allowed_dirs = allowed,
        });
    }

    fn appendMultimodalAllowedDir(
        arena: std.mem.Allocator,
        dirs: *std.ArrayListUnmanaged([]const u8),
        raw_dir: []const u8,
    ) !void {
        const trimmed = std.mem.trimRight(u8, raw_dir, "/\\");
        if (trimmed.len == 0) return;

        if (!containsMultimodalDir(dirs.items, trimmed)) {
            try dirs.append(arena, trimmed);
        }

        // Add canonical path variant too (/var <-> /private/var on macOS).
        const canonical = std.fs.realpathAlloc(arena, trimmed) catch return;
        if (!containsMultimodalDir(dirs.items, canonical)) {
            try dirs.append(arena, canonical);
        }
    }

    fn containsMultimodalDir(dirs: []const []const u8, target: []const u8) bool {
        for (dirs) |dir| {
            if (std.mem.eql(u8, dir, target)) return true;
        }
        return false;
    }

    /// Build a flat ChatMessage slice from owned history.
    fn buildMessageSlice(self: *Agent) ![]ChatMessage {
        const messages = try self.allocator.alloc(ChatMessage, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            messages[i] = msg.toChatMessage();
        }
        return messages;
    }

    /// Free heap-allocated fields of a ChatResponse.
    /// Providers allocate content, tool_calls, and model on the heap.
    /// After extracting/duping what we need, call this to prevent leaks.
    fn freeResponseFields(self: *Agent, resp: *ChatResponse) void {
        if (resp.content) |c| {
            if (c.len > 0) self.allocator.free(c);
        }
        for (resp.tool_calls) |tc| {
            if (tc.id.len > 0) self.allocator.free(tc.id);
            if (tc.name.len > 0) self.allocator.free(tc.name);
            if (tc.arguments.len > 0) self.allocator.free(tc.arguments);
        }
        if (resp.tool_calls.len > 0) self.allocator.free(resp.tool_calls);
        if (resp.model.len > 0) self.allocator.free(resp.model);
        if (resp.reasoning_content) |rc| {
            if (rc.len > 0) self.allocator.free(rc);
        }
        // Mark as consumed to prevent double-free
        resp.content = null;
        resp.tool_calls = &.{};
        resp.model = "";
        resp.reasoning_content = null;
    }

    /// Trim history to prevent unbounded growth.
    fn trimHistory(self: *Agent) void {
        compaction.trimHistory(self.allocator, &self.history, self.max_history_messages);
    }

    /// Run a single message through the agent and return the response.
    pub fn runSingle(self: *Agent, message: []const u8) ![]const u8 {
        return self.turn(message);
    }

    /// Clear conversation history (for starting a new session).
    pub fn clearHistory(self: *Agent) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.items.len = 0;
        self.has_system_prompt = false;
        self.system_prompt_has_conversation_context = false;
        self.system_prompt_conversation_context_fingerprint = 0;
        self.workspace_prompt_fingerprint = null;
        self.system_prompt_time_bucket_min = -1;
    }

    /// Persist a compact session checkpoint and refresh context anchor.
    /// Used by slash resets and session lifecycle hooks (TTL/eviction).
    pub fn persistSessionCheckpoint(self: *Agent, reason: []const u8) void {
        commands.persistSessionCheckpoint(self, reason);
    }

    fn conversationContextFingerprint(ctx: ?prompt.ConversationContext) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        if (ctx) |cc| {
            hasher.update("present");
            if (cc.channel) |channel| {
                hasher.update("channel:");
                hasher.update(channel);
            }
            if (cc.sender_number) |sender_number| {
                hasher.update("sender_number:");
                hasher.update(sender_number);
            }
            if (cc.sender_uuid) |sender_uuid| {
                hasher.update("sender_uuid:");
                hasher.update(sender_uuid);
            }
            if (cc.group_id) |group_id| {
                hasher.update("group_id:");
                hasher.update(group_id);
            }
            if (cc.is_group) |is_group| {
                hasher.update("is_group:");
                const b: u8 = if (is_group) 1 else 0;
                hasher.update(&[_]u8{b});
            }
        } else {
            hasher.update("absent");
        }
        return hasher.final();
    }

    /// Get total tokens used.
    pub fn tokensUsed(self: *const Agent) u64 {
        return self.total_tokens;
    }

    /// Get current history length.
    pub fn historyLen(self: *const Agent) usize {
        return self.history.items.len;
    }

    /// Enforce configured history bounds (used by restore/maintenance paths).
    pub fn enforceHistoryBounds(self: *Agent) void {
        self.trimHistory();
    }

    /// Load persisted messages into history (for session restore).
    /// Each entry has .role ("user"/"assistant") and .content.
    /// The agent takes ownership of the content strings.
    pub fn loadHistory(self: *Agent, entries: anytype) !void {
        for (entries) |entry| {
            const role: providers.Role = if (std.mem.eql(u8, entry.role, "assistant"))
                .assistant
            else if (std.mem.eql(u8, entry.role, "system"))
                .system
            else
                .user;
            const content_copy = try dupeHistoryBytes(self.allocator, entry.content);
            errdefer self.allocator.free(content_copy);
            try self.history.append(self.allocator, .{
                .role = role,
                .content = content_copy,
            });
        }
    }

    /// Get history entries as role-string + content pairs (for persistence).
    /// Caller owns the returned slice but NOT the inner strings (borrows from history).
    pub fn getHistory(self: *const Agent, allocator: std.mem.Allocator) ![]struct { role: []const u8, content: []const u8 } {
        const Pair = struct { role: []const u8, content: []const u8 };
        const result = try allocator.alloc(Pair, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            result[i] = .{
                .role = switch (msg.role) {
                    .system => "system",
                    .user => "user",
                    .assistant => "assistant",
                    .tool => "tool",
                },
                .content = msg.content,
            };
        }
        return result;
    }
};

fn dupeHistoryBytes(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len == 0) return allocator.alloc(u8, 0);
    const out = try allocator.alloc(u8, source.len);
    const src: [*]align(1) const u8 = @ptrCast(source.ptr);
    std.mem.copyForwards(u8, out, src[0..source.len]);
    return out;
}

pub const cli = @import("cli.zig");

/// CLI entry point — re-exported for backward compatibility.
pub const run = cli.run;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Agent.OwnedMessage toChatMessage" {
    const msg = Agent.OwnedMessage{
        .role = .user,
        .content = "hello",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .user);
    try std.testing.expectEqualStrings("hello", chat.content);
}

test "Agent trim history preserves system prompt" {
    const allocator = std.testing.allocator;

    // Create a minimal agent config
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = allocator,
    };

    var noop = observability.NoopObserver{};

    // We can't create a real provider in tests, but we can test trimHistory
    // by creating an Agent with minimal fields
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = cfg.default_model orelse "test",
        .temperature = 0.7,
        .workspace_dir = cfg.workspace_dir,
        .max_tool_iterations = 10,
        .max_history_messages = 5,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add system prompt
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });

    // Add more messages than max
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg {d}", .{i}),
        });
    }

    try std.testing.expect(agent.history.items.len == 11); // 1 system + 10 user

    agent.trimHistory();

    // System prompt should be preserved
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expectEqualStrings("system prompt", agent.history.items[0].content);

    // Should be trimmed to max + 1 (system)
    try std.testing.expect(agent.history.items.len <= 6); // 1 system + 5 messages

    // Most recent message should be the last one added
    const last = agent.history.items[agent.history.items.len - 1];
    try std.testing.expectEqualStrings("msg 9", last.content);
}

test "Agent clear history" {
    const allocator = std.testing.allocator;

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
        .workspace_prompt_fingerprint = 1234,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());

    agent.clearHistory();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
    try std.testing.expect(agent.workspace_prompt_fingerprint == null);
}

test "Agent loadHistory handles zero-length content safely" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const user_role = try allocator.dupe(u8, "user");
    defer allocator.free(user_role);
    const empty_content = try allocator.alloc(u8, 0);
    defer allocator.free(empty_content);
    const assistant_role = try allocator.dupe(u8, "assistant");
    defer allocator.free(assistant_role);
    const assistant_content = try allocator.dupe(u8, "persisted reply");
    defer allocator.free(assistant_content);

    const Entry = struct {
        role: []const u8,
        content: []const u8,
    };
    const entries = [_]Entry{
        .{ .role = user_role, .content = empty_content },
        .{ .role = assistant_role, .content = assistant_content },
    };

    try agent.loadHistory(entries[0..]);
    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());
    try std.testing.expect(agent.history.items[0].role == .user);
    try std.testing.expectEqual(@as(usize, 0), agent.history.items[0].content.len);
    try std.testing.expect(agent.history.items[1].role == .assistant);
    try std.testing.expectEqualStrings("persisted reply", agent.history.items[1].content);
}

test "dispatcher module reexport" {
    _ = dispatcher.ParsedToolCall;
    _ = dispatcher.ToolExecutionResult;
    _ = dispatcher.parseToolCalls;
    _ = dispatcher.formatToolResults;
    _ = dispatcher.buildToolInstructions;
    _ = dispatcher.buildAssistantHistoryWithToolCalls;
}

test "compaction module reexport" {
    _ = compaction.tokenEstimate;
    _ = compaction.autoCompactHistory;
    _ = compaction.forceCompressHistory;
    _ = compaction.trimHistory;
    _ = compaction.CompactionConfig;
}

test "cli module reexport" {
    _ = cli.run;
}

test "prompt module reexport" {
    _ = prompt.buildSystemPrompt;
    _ = prompt.PromptContext;
}

test "memory_loader module reexport" {
    _ = memory_loader.loadContext;
    _ = memory_loader.enrichMessage;
}

test {
    _ = dispatcher;
    _ = compaction;
    _ = cli;
    _ = prompt;
    _ = memory_loader;
}

// ── Additional agent tests ──────────────────────────────────────

test "Agent.OwnedMessage system role" {
    const msg = Agent.OwnedMessage{
        .role = .system,
        .content = "system prompt",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .system);
    try std.testing.expectEqualStrings("system prompt", chat.content);
}

test "Agent.OwnedMessage assistant role" {
    const msg = Agent.OwnedMessage{
        .role = .assistant,
        .content = "I can help with that.",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .assistant);
    try std.testing.expectEqualStrings("I can help with that.", chat.content);
}

test "Agent initial state" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.5,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expectEqual(@as(u64, 0), agent.tokensUsed());
    try std.testing.expect(!agent.has_system_prompt);
}

test "Agent tokens tracking" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    agent.total_tokens = 100;
    try std.testing.expectEqual(@as(u64, 100), agent.tokensUsed());
    agent.total_tokens += 50;
    try std.testing.expectEqual(@as(u64, 150), agent.tokensUsed());
}

test "Agent trimHistory no-op when under limit" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    agent.trimHistory();
    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());
}

test "Agent trimHistory without system prompt" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 3,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add 6 user messages (no system prompt)
    for (0..6) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg {d}", .{i}),
        });
    }

    agent.trimHistory();
    // Should trim to max_history_messages (3) + 1 for system = 4, but no system
    try std.testing.expect(agent.history.items.len <= 4);
}

test "Agent clearHistory resets all state" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "hi"),
    });

    try std.testing.expectEqual(@as(usize, 3), agent.historyLen());
    try std.testing.expect(agent.has_system_prompt);

    agent.clearHistory();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
}

test "Agent buildMessageSlice" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const messages = try agent.buildMessageSlice();
    defer allocator.free(messages);

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(messages[0].role == .system);
    try std.testing.expect(messages[1].role == .user);
    try std.testing.expectEqualStrings("sys", messages[0].content);
    try std.testing.expectEqualStrings("hello", messages[1].content);
}

test "Agent buildProviderMessages does not pre-gate non-vision models" {
    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{};
        }
        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn supportsVision(_: *anyopaque) bool {
            return true;
        }
        fn supportsVisionForModel(_: *anyopaque, model: []const u8) bool {
            return std.mem.eql(u8, model, "vision-model");
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    var dummy: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supportsNativeTools,
        .supports_vision = DummyProvider.supportsVision,
        .supports_vision_for_model = DummyProvider.supportsVisionForModel,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const prov = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = prov,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "text-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Check [IMAGE:https://example.com/a.jpg]"),
    });

    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const before_metrics = multimodal.imageFlowMetricsSnapshot();
    const messages = try agent.buildProviderMessages(arena);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0].content_parts != null);
    const after_metrics = multimodal.imageFlowMetricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), after_metrics.messages_with_image_markers - before_metrics.messages_with_image_markers);

    agent.model_name = "vision-model";
    const vision_messages = try agent.buildProviderMessages(arena);
    try std.testing.expectEqual(@as(usize, 1), vision_messages.len);
    try std.testing.expect(vision_messages[0].content_parts != null);
}

test "Agent buildProviderMessages allows workspace image paths" {
    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{};
        }
        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn supportsVision(_: *anyopaque) bool {
            return true;
        }
        fn supportsVisionForModel(_: *anyopaque, _: []const u8) bool {
            return true;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{
        .sub_path = "screen.png",
        .data = "\x89PNG\x0d\x0a\x1a\x0a",
    });

    const allocator = std.testing.allocator;
    const workspace_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_path);
    const image_path = try std.fs.path.join(allocator, &.{ workspace_path, "screen.png" });
    defer allocator.free(image_path);

    var dummy: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supportsNativeTools,
        .supports_vision = DummyProvider.supportsVision,
        .supports_vision_for_model = DummyProvider.supportsVisionForModel,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const prov = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = prov,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "vision-model",
        .temperature = 0.7,
        .workspace_dir = workspace_path,
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try std.fmt.allocPrint(allocator, "Inspect [IMAGE:{s}]", .{image_path}),
    });

    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const messages = try agent.buildProviderMessages(arena);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0].content_parts != null);
    const parts = messages[0].content_parts.?;
    var has_image_part = false;
    for (parts) |part| {
        if (part == .image_base64) {
            has_image_part = true;
            break;
        }
    }
    try std.testing.expect(has_image_part);
}

test "Agent max_tool_iterations default" {
    try std.testing.expectEqual(@as(u32, 25), DEFAULT_MAX_TOOL_ITERATIONS);
}

test "Agent max_history default" {
    try std.testing.expectEqual(@as(u32, 50), DEFAULT_MAX_HISTORY);
}

test "Agent trimHistory keeps most recent messages" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 3,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add system + 5 messages
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    for (0..5) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    agent.trimHistory();

    // Should keep system + last 3 messages
    try std.testing.expectEqual(@as(usize, 4), agent.historyLen());
    try std.testing.expect(agent.history.items[0].role == .system);
    // Last message should be msg-4
    try std.testing.expectEqualStrings("msg-4", agent.history.items[3].content);
}

test "Agent clearHistory then add messages" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "old"),
    });
    agent.clearHistory();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "new"),
    });
    try std.testing.expectEqual(@as(usize, 1), agent.historyLen());
    try std.testing.expectEqualStrings("new", agent.history.items[0].content);
}

// ── Slash Command Tests ──────────────────────────────────────────

fn makeTestAgent(allocator: std.mem.Allocator) !Agent {
    var noop = observability.NoopObserver{};
    return Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
}

fn find_tool_by_name(tools: []const Tool, name: []const u8) ?Tool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), name)) return t;
    }
    return null;
}

test "Agent.fromConfig resolves token limit from model lookup when unset" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "openai/gpt-4.1-mini",
        .allocator = allocator,
    };
    cfg.agent.token_limit = config_types.DEFAULT_AGENT_TOKEN_LIMIT;
    cfg.agent.token_limit_explicit = false;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer());
    defer agent.deinit();

    try std.testing.expectEqual(@as(u64, 128_000), agent.token_limit);
    try std.testing.expect(agent.token_limit_override == null);
    try std.testing.expectEqual(@as(u32, max_tokens_resolver.DEFAULT_MODEL_MAX_TOKENS), agent.max_tokens);
    try std.testing.expect(agent.max_tokens_override == null);
}

test "Agent.fromConfig keeps explicit token_limit override" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "openai/gpt-4.1-mini",
        .allocator = allocator,
    };
    cfg.agent.token_limit = 64_000;
    cfg.agent.token_limit_explicit = true;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer());
    defer agent.deinit();

    try std.testing.expectEqual(@as(u64, 64_000), agent.token_limit);
    try std.testing.expectEqual(@as(?u64, 64_000), agent.token_limit_override);
}

test "Agent.fromConfig resolves max_tokens from provider lookup when unset" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "qianfan/custom-model",
        .allocator = allocator,
    };
    cfg.max_tokens = null;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer());
    defer agent.deinit();

    try std.testing.expectEqual(@as(u32, 32_768), agent.max_tokens);
    try std.testing.expect(agent.max_tokens_override == null);
}

test "Agent.fromConfig keeps explicit max_tokens override" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "qianfan/custom-model",
        .allocator = allocator,
    };
    cfg.max_tokens = 1536;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer());
    defer agent.deinit();

    try std.testing.expectEqual(@as(u32, 1536), agent.max_tokens);
    try std.testing.expectEqual(@as(?u32, 1536), agent.max_tokens_override);
}

test "Agent.fromConfig clamps max_tokens to token_limit" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "openai/gpt-4.1-mini",
        .allocator = allocator,
    };
    cfg.agent.token_limit = 4096;
    cfg.agent.token_limit_explicit = true;
    cfg.max_tokens = 8192;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer());
    defer agent.deinit();

    try std.testing.expectEqual(@as(u64, 4096), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 4096), agent.max_tokens);
}

test "Agent.fromConfig applies queue ttl activation send and tts knobs" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "openai/gpt-4.1-mini",
        .allocator = allocator,
    };
    cfg.agent.queue_mode = "debounce";
    cfg.agent.queue_debounce_ms = 250;
    cfg.agent.queue_cap = 9;
    cfg.agent.queue_drop = "newest";
    cfg.agent.session_ttl_secs = 3600;
    cfg.agent.activation_mode = "always";
    cfg.agent.send_mode = "off";
    cfg.agent.tts_mode = "always";
    cfg.agent.tts_provider = "openai";
    cfg.agent.tts_limit_chars = 777;
    cfg.agent.tts_summary = true;
    cfg.agent.tts_audio = true;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer());
    defer agent.deinit();

    try std.testing.expect(agent.queue_mode == .debounce);
    try std.testing.expectEqual(@as(u32, 250), agent.queue_debounce_ms);
    try std.testing.expectEqual(@as(u32, 9), agent.queue_cap);
    try std.testing.expect(agent.queue_drop == .newest);
    try std.testing.expectEqual(@as(?u64, 3600), agent.session_ttl_secs);
    try std.testing.expect(agent.activation_mode == .always);
    try std.testing.expect(agent.send_mode == .off);
    try std.testing.expect(agent.tts_mode == .always);
    try std.testing.expect(agent.tts_provider != null);
    try std.testing.expectEqualStrings("openai", agent.tts_provider.?);
    try std.testing.expectEqual(@as(u32, 777), agent.tts_limit_chars);
    try std.testing.expect(agent.tts_summary);
    try std.testing.expect(agent.tts_audio);
}

test "slash /new clears history" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add some history
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    agent.has_system_prompt = true;

    const response = (try agent.handleSlashCommand("/new")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Session cleared.", response);
    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
}

test "slash /new writes session checkpoint and context anchor" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";
    agent.auto_save = true;

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "[Memory context]\n- pref: concise\n\nactual user request"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "Working on it."),
    });

    const response = (try agent.handleSlashCommand("/new")).?;
    defer allocator.free(response);
    try std.testing.expectEqualStrings("Session cleared.", response);

    const daily_entries = try mem.list(allocator, .daily, null);
    defer memory_mod.freeEntries(allocator, daily_entries);

    var checkpoint_found = false;
    for (daily_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "session_checkpoint_")) continue;
        checkpoint_found = true;
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "reason=new") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "actual user request") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "[Memory context]") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "Working on it.") != null);
        break;
    }
    try std.testing.expect(checkpoint_found);

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_session=agent:zaki-bot:user:1:main") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=new") != null);
}

test "slash /new with empty session does not write checkpoint" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";

    const response = (try agent.handleSlashCommand("/new")).?;
    defer allocator.free(response);
    try std.testing.expectEqualStrings("Session cleared.", response);

    const daily_entries = try mem.list(allocator, .daily, null);
    defer memory_mod.freeEntries(allocator, daily_entries);
    try std.testing.expectEqual(@as(usize, 0), daily_entries.len);

    const anchor = try mem.get(allocator, "context_anchor_current");
    if (anchor) |entry| {
        defer entry.deinit(allocator);
        return error.TestUnexpectedResult;
    }
}

test "slash /reset clears history and switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const response = (try agent.handleSlashCommand("/reset gpt-4o-mini")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Session cleared.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4o-mini") != null);
    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expectEqualStrings("gpt-4o-mini", agent.model_name);
}

test "slash /help returns help text" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/help")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/status") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/model") != null);
}

test "slash /commands aliases to help" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/commands")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/commands") != null);
}

test "slash /status returns agent info" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.total_tokens = 42;
    const response = (try agent.handleSlashCommand("/status")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "42") != null);
}

test "slash /whoami returns current session id" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.memory_session_id = "telegram:chat123";

    const response = (try agent.handleSlashCommand("/whoami")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "telegram:chat123") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
}

test "slash /model switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;
    agent.has_system_prompt = true;

    const response = (try agent.handleSlashCommand("/model gpt-4o")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4o") != null);
    try std.testing.expectEqualStrings("gpt-4o", agent.model_name);
    try std.testing.expectEqualStrings("gpt-4o", agent.default_model);
    try std.testing.expectEqual(@as(u64, 128_000), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 8192), agent.max_tokens);
    try std.testing.expect(!agent.has_system_prompt);
}

test "slash /model with colon switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;

    const response = (try agent.handleSlashCommand("/model: gpt-4.1-mini")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4.1-mini") != null);
    try std.testing.expectEqualStrings("gpt-4.1-mini", agent.model_name);
    try std.testing.expectEqual(@as(u64, 128_000), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 8192), agent.max_tokens);
}

test "slash /model with telegram bot mention switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;

    const response = (try agent.handleSlashCommand("/model@nullalis_bot qianfan/custom-model")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "qianfan/custom-model") != null);
    try std.testing.expectEqualStrings("qianfan/custom-model", agent.model_name);
    try std.testing.expectEqualStrings("qianfan/custom-model", agent.default_model);
    try std.testing.expectEqual(@as(u32, 32_768), agent.max_tokens);
}

test "slash /model resolves provider max_tokens fallback" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;

    const response = (try agent.handleSlashCommand("/model qianfan/custom-model")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "qianfan/custom-model") != null);
    try std.testing.expectEqualStrings("qianfan/custom-model", agent.model_name);
    try std.testing.expectEqual(@as(u32, 32_768), agent.max_tokens);
}

test "slash /model keeps explicit token_limit override" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.token_limit_override = 64_000;
    agent.token_limit = 64_000;
    agent.max_tokens_override = 1024;
    agent.max_tokens = 1024;

    const response = (try agent.handleSlashCommand("/model claude-opus-4-6")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "claude-opus-4-6") != null);
    try std.testing.expectEqual(@as(u64, 64_000), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 1024), agent.max_tokens);
}

test "slash /model without name shows current" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/model ")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
}

test "slash /models aliases to /model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/models list")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Current model: test-model") != null);
}

test "slash /model list aliases to model status" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/model list")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Current model: test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Switch: /model <name>") != null);
}

test "slash /memory list hides internal autosave and hygiene entries by default" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);
    try mem.store("MEMORY:99", "**last_hygiene_at**: 1772051691", .core, null);
    try mem.store("user_language", "ru", .core, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };
    agent.mem_rt = &rt;

    const response = (try agent.handleSlashCommand("/memory list --limit 10")).?;
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "user_language") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "autosave_user_") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "last_hygiene_at") == null);
}

test "slash /memory list includes internal entries when requested" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };
    agent.mem_rt = &rt;

    const response = (try agent.handleSlashCommand("/memory list --limit 10 --include-internal")).?;
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "autosave_user_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "last_hygiene_at") != null);
}

test "slash /model shows provider and model fallback chains" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const configured_providers = [_]config_types.ProviderEntry{
        .{ .name = "openai-codex" },
        .{ .name = "openrouter", .api_key = "sk-or-test" },
    };
    const model_fallbacks = [_]config_types.ModelFallbackEntry{
        .{
            .model = "gpt-5.3-codex",
            .fallbacks = &.{"openrouter/anthropic/claude-sonnet-4"},
        },
    };

    agent.model_name = "gpt-5.3-codex";
    agent.default_model = "gpt-5.3-codex";
    agent.default_provider = "openai-codex";
    agent.configured_providers = &configured_providers;
    agent.fallback_providers = &.{"openrouter"};
    agent.model_fallbacks = &model_fallbacks;

    const response = (try agent.handleSlashCommand("/model")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Provider chain: openai-codex -> openrouter") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        response,
        "Model chain: gpt-5.3-codex -> openrouter/anthropic/claude-sonnet-4",
    ) != null);
}

test "slash /compact with short history is a no-op" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/compact")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Nothing to compact.", response);
}

test "slash /think updates reasoning effort" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const set_resp = (try agent.handleSlashCommand("/think high")).?;
    defer allocator.free(set_resp);
    try std.testing.expect(std.mem.indexOf(u8, set_resp, "high") != null);
    try std.testing.expectEqualStrings("high", agent.reasoning_effort.?);

    const off_resp = (try agent.handleSlashCommand("/think off")).?;
    defer allocator.free(off_resp);
    try std.testing.expect(agent.reasoning_effort == null);
}

test "slash /verbose updates verbose level" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/verbose full")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.verbose_level == .full);
}

test "slash /reasoning updates reasoning mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/reasoning stream")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.reasoning_mode == .stream);
}

test "slash /exec updates runtime exec settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/exec host=sandbox security=full ask=off node=node-1")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.exec_host == .sandbox);
    try std.testing.expect(agent.exec_security == .full);
    try std.testing.expect(agent.exec_ask == .off);
    try std.testing.expect(agent.exec_node_id != null);
    try std.testing.expectEqualStrings("node-1", agent.exec_node_id.?);
}

test "slash /queue updates queue settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/queue debounce debounce:2s cap:25 drop:newest")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.queue_mode == .debounce);
    try std.testing.expectEqual(@as(u32, 2000), agent.queue_debounce_ms);
    try std.testing.expectEqual(@as(u32, 25), agent.queue_cap);
    try std.testing.expect(agent.queue_drop == .newest);
}

test "slash /usage updates usage mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/usage full")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.usage_mode == .full);
}

test "slash /tts updates tts settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/tts always provider openai limit 1200 summary on audio off")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.tts_mode == .always);
    try std.testing.expect(agent.tts_provider != null);
    try std.testing.expectEqualStrings("openai", agent.tts_provider.?);
    try std.testing.expectEqual(@as(u32, 1200), agent.tts_limit_chars);
    try std.testing.expect(agent.tts_summary);
    try std.testing.expect(!agent.tts_audio);
}

test "slash /stop handled explicitly" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/stop")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "No active background task") != null);
}

test "slash /approve executes pending bash command" {
    const allocator = std.testing.allocator;

    const shell_impl = try allocator.create(tools_mod.shell.ShellTool);
    shell_impl.* = .{ .workspace_dir = "." };
    const shell_tool = shell_impl.tool();
    defer shell_tool.deinit(allocator);

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{shell_tool},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const exec_resp = (try agent.handleSlashCommand("/exec ask=always")).?;
    defer allocator.free(exec_resp);

    const pending_resp = (try agent.handleSlashCommand("/bash echo hello-approve")).?;
    defer allocator.free(pending_resp);
    try std.testing.expect(std.mem.indexOf(u8, pending_resp, "Exec approval required") != null);
    try std.testing.expect(agent.pending_exec_command != null);

    const approve_resp = (try agent.handleSlashCommand("/approve allow-once")).?;
    defer allocator.free(approve_resp);
    try std.testing.expect(std.mem.indexOf(u8, approve_resp, "Approved exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, approve_resp, "hello-approve") != null);
    try std.testing.expect(agent.pending_exec_command == null);
}

test "slash /restart clears runtime command settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const think_resp = (try agent.handleSlashCommand("/think high")).?;
    defer allocator.free(think_resp);
    const verbose_resp = (try agent.handleSlashCommand("/verbose full")).?;
    defer allocator.free(verbose_resp);
    const usage_resp = (try agent.handleSlashCommand("/usage full")).?;
    defer allocator.free(usage_resp);
    const tts_resp = (try agent.handleSlashCommand("/tts always provider test-provider")).?;
    defer allocator.free(tts_resp);

    const response = (try agent.handleSlashCommand("/restart")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Session restarted.", response);
    try std.testing.expect(agent.reasoning_effort == null);
    try std.testing.expect(agent.verbose_level == .off);
    try std.testing.expect(agent.usage_mode == .off);
    try std.testing.expect(agent.tts_mode == .off);
    try std.testing.expect(agent.tts_provider == null);
}

test "turn includes reasoning and usage footer when enabled" {
    const ProviderState = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "final answer"),
                .tool_calls = &.{},
                .usage = .{ .prompt_tokens = 4, .completion_tokens = 6, .total_tokens = 10 },
                .model = try allocator.dupe(u8, "test-model"),
                .reasoning_content = try allocator.dupe(u8, "thinking trace"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "test";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var state: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = ProviderState.chatWithSystem,
        .chat = ProviderState.chat,
        .supportsNativeTools = ProviderState.supportsNativeTools,
        .getName = ProviderState.getName,
        .deinit = ProviderState.deinitFn,
    };
    const provider = Provider{ .ptr = @ptrCast(&state), .vtable = &vtable };

    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const reasoning_cmd = (try agent.handleSlashCommand("/reasoning on")).?;
    defer allocator.free(reasoning_cmd);
    const usage_cmd = (try agent.handleSlashCommand("/usage tokens")).?;
    defer allocator.free(usage_cmd);

    const response = try agent.turn("hello");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Reasoning:\nthinking trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "[usage] total_tokens=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "final answer") != null);
}

test "turn refreshes system prompt after workspace markdown change" {
    const ReloadProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "ok"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "reload-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("SOUL.md", .{});
        defer f.close();
        try f.writeAll("SOUL-V1");
    }

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ReloadProvider.chatWithSystem,
        .chat = ReloadProvider.chat,
        .supportsNativeTools = ReloadProvider.supportsNativeTools,
        .getName = ReloadProvider.getName,
        .deinit = ReloadProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = workspace,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const first = try agent.turn("first");
    defer allocator.free(first);
    try std.testing.expect(agent.history.items.len > 0);
    try std.testing.expectEqual(providers.Role.system, agent.history.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "SOUL-V1") != null);

    {
        const f = try tmp.dir.createFile("SOUL.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll("SOUL-V2-UPDATED");
    }

    const second = try agent.turn("second");
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "SOUL-V2-UPDATED") != null);
}

test "turn uses semantic cache when runtime semantic cache is available" {
    if (!@import("build_options").enable_sqlite) return error.SkipZigTest;

    const CountingProvider = struct {
        const State = struct {
            calls: u32 = 0,
        };

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const state: *State = @ptrCast(@alignCast(ptr));
            state.calls += 1;
            return .{
                .content = try allocator.dupe(u8, "provider-answer"),
                .tool_calls = &.{},
                .usage = .{ .prompt_tokens = 4, .completion_tokens = 6, .total_tokens = 10 },
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "counting-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var provider_state = CountingProvider.State{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = CountingProvider.chatWithSystem,
        .chat = CountingProvider.chat,
        .supportsNativeTools = CountingProvider.supportsNativeTools,
        .getName = CountingProvider.getName,
        .deinit = CountingProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = workspace,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const sem_cache_path = try std.fs.path.joinZ(allocator, &.{ workspace, "semantic_cache_test.db" });
    defer allocator.free(std.mem.span(sem_cache_path.ptr));
    const sem_cache = try allocator.create(memory_mod.semantic_cache.SemanticCache);
    sem_cache.* = try memory_mod.semantic_cache.SemanticCache.init(
        sem_cache_path.ptr,
        60,
        1000,
        0.95,
        null,
    );
    defer {
        sem_cache.deinit();
        allocator.destroy(sem_cache);
    }

    var none_backend = memory_mod.none.NoneMemory.init();
    defer none_backend.deinit();
    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "none",
        .retrieval_mode = "disabled",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = true,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = none_backend.memory(),
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
        ._semantic_cache = sem_cache,
    };
    agent.mem_rt = &rt;

    const first = try agent.turn("semantic cache probe");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("provider-answer", first);
    try std.testing.expectEqual(@as(u32, 1), provider_state.calls);

    const sem_stats_after_first = try sem_cache.stats();
    try std.testing.expect(sem_stats_after_first.count >= 1);

    const second = try agent.turn("semantic cache probe");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("provider-answer", second);
    try std.testing.expectEqual(@as(u32, 1), provider_state.calls);

    const sem_stats_after_second = try sem_cache.stats();
    try std.testing.expect(sem_stats_after_second.hits >= 1);
}

test "exec security deny blocks shell tool execution" {
    const allocator = std.testing.allocator;
    const shell_impl = try allocator.create(tools_mod.shell.ShellTool);
    shell_impl.* = .{ .workspace_dir = "." };
    const shell_tool = shell_impl.tool();
    defer shell_tool.deinit(allocator);

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{shell_tool},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const cmd_resp = (try agent.handleSlashCommand("/exec security=deny")).?;
    defer allocator.free(cmd_resp);

    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hello\"}",
        .tool_call_id = null,
    };
    const result = agent.executeTool(allocator, call);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "security=deny") != null);
}

test "exec ask always registers pending approval from tool path" {
    const allocator = std.testing.allocator;
    const shell_impl = try allocator.create(tools_mod.shell.ShellTool);
    shell_impl.* = .{ .workspace_dir = "." };
    const shell_tool = shell_impl.tool();
    defer shell_tool.deinit(allocator);

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{shell_tool},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const cmd_resp = (try agent.handleSlashCommand("/exec ask=always")).?;
    defer allocator.free(cmd_resp);

    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hello\"}",
        .tool_call_id = null,
    };
    const result = agent.executeTool(allocator, call);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "approval required") != null);
    try std.testing.expect(agent.pending_exec_command != null);
    try std.testing.expectEqualStrings("echo hello", agent.pending_exec_command.?);
}

test "slash additional commands are handled" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const cmd_list = [_][]const u8{
        "/allowlist",
        "/elevated full",
        "/dock-telegram",
        "/bash echo hi",
        "/approve",
        "/poll",
        "/subagents",
        "/config get model",
        "/skill list",
    };

    for (cmd_list) |cmd| {
        const response_opt = try agent.handleSlashCommand(cmd);
        try std.testing.expect(response_opt != null);
        const response = response_opt.?;
        try std.testing.expect(response.len > 0);
        allocator.free(response);
    }
}

test "non-slash message returns null" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = try agent.handleSlashCommand("hello world");
    try std.testing.expect(response == null);
}

test "slash command with whitespace" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("  /help  ")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
}

test "Agent streaming fields default to null" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
    };
    defer agent.deinit();

    try std.testing.expect(agent.stream_callback == null);
    try std.testing.expect(agent.stream_ctx == null);
}

// ── Bug regression tests ─────────────────────────────────────────

// Bug 1: /model command should dupe the arg to avoid use-after-free.
// model_name must survive past the stack buffer that held the original message.
test "slash /model dupe prevents use-after-free" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Build message in a buffer that we then invalidate (simulate stack lifetime end)
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "/model new-model-xyz", .{}) catch unreachable;
    const response = (try agent.handleSlashCommand(msg)).?;
    defer allocator.free(response);

    // Overwrite the source buffer to verify model_name is an independent copy
    @memset(&msg_buf, 0);
    try std.testing.expectEqualStrings("new-model-xyz", agent.model_name);
}

// Bug 2: @intCast on negative i64 duration should not panic.
// Simulate by verifying the @max(0, ...) clamping logic.
test "milliTimestamp negative difference clamps to zero" {
    // Simulate: timer_start is in the future relative to "now" (negative diff)
    const timer_start = std.time.milliTimestamp() + 10_000;
    const diff = std.time.milliTimestamp() - timer_start;
    // diff < 0 here; @max(0, diff) must clamp to 0 without panic
    const clamped = @max(0, diff);
    const duration: u64 = @as(u64, @intCast(clamped));
    try std.testing.expectEqual(@as(u64, 0), duration);
}

test "bindMemoryTools wires memory tools to sqlite backend" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .allocator = allocator,
    };

    const tools = try tools_mod.allTools(allocator, cfg.workspace_dir, .{ .config = &cfg });
    defer tools_mod.deinitTools(allocator, tools);

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    var mem = sqlite_mem.memory();
    tools_mod.bindMemoryTools(tools, mem);

    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator_: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator_.dupe(u8, "");
        }

        fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{};
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var dummy_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supportsNativeTools,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const provider_i = Provider{
        .ptr = @ptrCast(&dummy_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(
        allocator,
        &cfg,
        provider_i,
        tools,
        mem,
        noop.observer(),
    );
    defer agent.deinit();

    tools_mod.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer tools_mod.clearTurnContext();

    const store_tool = find_tool_by_name(tools, "memory_store").?;
    const store_args = try tools_mod.parseTestArgs("{\"key\":\"preference.test\",\"content\":\"123\"}");
    defer store_args.deinit();

    const store_result = try store_tool.execute(allocator, store_args.value.object);
    defer if (store_result.output.len > 0) allocator.free(store_result.output);
    try std.testing.expect(store_result.success);
    try std.testing.expect(std.mem.indexOf(u8, store_result.output, "Stored memory") != null);

    const entry = try mem.get(allocator, "preference.test");
    try std.testing.expect(entry != null);
    if (entry) |e| {
        defer e.deinit(allocator);
        try std.testing.expectEqualStrings("123", e.content);
    }

    const recall_tool = find_tool_by_name(tools, "memory_recall").?;
    const recall_args = try tools_mod.parseTestArgs("{\"query\":\"preference.test\"}");
    defer recall_args.deinit();

    const recall_result = try recall_tool.execute(allocator, recall_args.value.object);
    defer if (recall_result.output.len > 0) allocator.free(recall_result.output);
    try std.testing.expect(recall_result.success);
    try std.testing.expect(std.mem.indexOf(u8, recall_result.output, "preference.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall_result.output, "123") != null);
}

test "Agent tool loop frees dynamic tool outputs" {
    const DynamicOutputTool = struct {
        const Self = @This();
        pub const tool_name = "leak_probe";
        pub const tool_description = "Returns dynamically allocated tool output";
        pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
        pub const vtable = tools_mod.ToolVTable(Self);

        fn tool(self: *Self) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(_: *Self, allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
            return .{
                .success = true,
                .output = try allocator.dupe(u8, "dynamic-tool-output"),
            };
        }
    };

    const StepProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            if (self.call_count == 1) {
                const tool_calls = try allocator.alloc(providers.ToolCall, 1);
                tool_calls[0] = .{
                    .id = try allocator.dupe(u8, "call-1"),
                    .name = try allocator.dupe(u8, "leak_probe"),
                    .arguments = try allocator.dupe(u8, "{}"),
                };

                return .{
                    .content = try allocator.dupe(u8, "Running tool"),
                    .tool_calls = tool_calls,
                    .usage = .{},
                    .model = try allocator.dupe(u8, "test-model"),
                };
            }

            return .{
                .content = try allocator.dupe(u8, "done"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return true;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "step-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;

    var provider_state = StepProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = StepProvider.chatWithSystem,
        .chat = StepProvider.chat,
        .supportsNativeTools = StepProvider.supportsNativeTools,
        .getName = StepProvider.getName,
        .deinit = StepProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var tool_impl = DynamicOutputTool{};
    const tool_list = [_]Tool{tool_impl.tool()};

    var specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |t, i| {
        specs[i] = .{
            .name = t.name(),
            .description = t.description(),
            .parameters_json = t.parametersJson(),
        };
    }

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &tool_list,
        .tool_specs = specs,
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("run tool");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("done", response);
    try std.testing.expectEqual(@as(usize, 2), provider_state.call_count);
}

test "Agent parallel dispatcher runs safe tool calls concurrently when enabled" {
    const ParallelProbeState = struct {
        mutex: std.Thread.Mutex = .{},
        active: u32 = 0,
        max_active: u32 = 0,
    };

    const SlowReadTool = struct {
        const Self = @This();
        pub const tool_name = "web_search";
        pub const tool_description = "Synthetic read tool for parallel dispatcher testing";
        pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
        pub const vtable = tools_mod.ToolVTable(Self);

        state: *ParallelProbeState,

        fn tool(self: *Self) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(self: *Self, allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
            self.state.mutex.lock();
            self.state.active += 1;
            if (self.state.active > self.state.max_active) self.state.max_active = self.state.active;
            self.state.mutex.unlock();
            defer {
                self.state.mutex.lock();
                self.state.active -= 1;
                self.state.mutex.unlock();
            }

            std.Thread.sleep(60 * std.time.ns_per_ms);
            return .{
                .success = true,
                .output = try allocator.dupe(u8, "ok"),
            };
        }
    };

    const TwoCallProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            if (self.call_count == 1) {
                const tool_calls = try allocator.alloc(providers.ToolCall, 2);
                tool_calls[0] = .{
                    .id = try allocator.dupe(u8, "call-1"),
                    .name = try allocator.dupe(u8, "web_search"),
                    .arguments = try allocator.dupe(u8, "{\"query\":\"one\"}"),
                };
                tool_calls[1] = .{
                    .id = try allocator.dupe(u8, "call-2"),
                    .name = try allocator.dupe(u8, "web_search"),
                    .arguments = try allocator.dupe(u8, "{\"query\":\"two\"}"),
                };
                return .{
                    .content = try allocator.dupe(u8, "running"),
                    .tool_calls = tool_calls,
                    .usage = .{},
                    .model = try allocator.dupe(u8, "test-model"),
                };
            }

            return .{
                .content = try allocator.dupe(u8, "done"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return true;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "two-call-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var provider_state = TwoCallProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = TwoCallProvider.chatWithSystem,
        .chat = TwoCallProvider.chat,
        .supportsNativeTools = TwoCallProvider.supportsNativeTools,
        .getName = TwoCallProvider.getName,
        .deinit = TwoCallProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var probe_state = ParallelProbeState{};
    var tool_impl = SlowReadTool{ .state = &probe_state };
    const tool_list = [_]Tool{tool_impl.tool()};

    const specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |t, i| {
        specs[i] = .{
            .name = t.name(),
            .description = t.description(),
            .parameters_json = t.parametersJson(),
        };
    }

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &tool_list,
        .tool_specs = specs,
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .parallel_tools = true,
        .tool_dispatcher_mode = .parallel,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("run tools");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("done", response);
    try std.testing.expect(probe_state.max_active >= 2);
}

test "Agent dispatcher stays serial when parallel tools are disabled" {
    const ParallelProbeState = struct {
        mutex: std.Thread.Mutex = .{},
        active: u32 = 0,
        max_active: u32 = 0,
    };

    const SlowReadTool = struct {
        const Self = @This();
        pub const tool_name = "web_search";
        pub const tool_description = "Synthetic read tool for serial dispatcher testing";
        pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
        pub const vtable = tools_mod.ToolVTable(Self);

        state: *ParallelProbeState,

        fn tool(self: *Self) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(self: *Self, allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
            self.state.mutex.lock();
            self.state.active += 1;
            if (self.state.active > self.state.max_active) self.state.max_active = self.state.active;
            self.state.mutex.unlock();
            defer {
                self.state.mutex.lock();
                self.state.active -= 1;
                self.state.mutex.unlock();
            }

            std.Thread.sleep(40 * std.time.ns_per_ms);
            return .{
                .success = true,
                .output = try allocator.dupe(u8, "ok"),
            };
        }
    };

    const TwoCallProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            if (self.call_count == 1) {
                const tool_calls = try allocator.alloc(providers.ToolCall, 2);
                tool_calls[0] = .{
                    .id = try allocator.dupe(u8, "call-1"),
                    .name = try allocator.dupe(u8, "web_search"),
                    .arguments = try allocator.dupe(u8, "{\"query\":\"one\"}"),
                };
                tool_calls[1] = .{
                    .id = try allocator.dupe(u8, "call-2"),
                    .name = try allocator.dupe(u8, "web_search"),
                    .arguments = try allocator.dupe(u8, "{\"query\":\"two\"}"),
                };
                return .{
                    .content = try allocator.dupe(u8, "running"),
                    .tool_calls = tool_calls,
                    .usage = .{},
                    .model = try allocator.dupe(u8, "test-model"),
                };
            }

            return .{
                .content = try allocator.dupe(u8, "done"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return true;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "two-call-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var provider_state = TwoCallProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = TwoCallProvider.chatWithSystem,
        .chat = TwoCallProvider.chat,
        .supportsNativeTools = TwoCallProvider.supportsNativeTools,
        .getName = TwoCallProvider.getName,
        .deinit = TwoCallProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var probe_state = ParallelProbeState{};
    var tool_impl = SlowReadTool{ .state = &probe_state };
    const tool_list = [_]Tool{tool_impl.tool()};

    const specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |t, i| {
        specs[i] = .{
            .name = t.name(),
            .description = t.description(),
            .parameters_json = t.parametersJson(),
        };
    }

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &tool_list,
        .tool_specs = specs,
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .parallel_tools = false,
        .tool_dispatcher_mode = .auto,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("run tools");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("done", response);
    try std.testing.expectEqual(@as(u32, 1), probe_state.max_active);
}

test "Agent parallel dispatcher rollout canary gates by session bucket" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .parallel_tools = true,
        .parallel_tools_rollout_percent = 0,
        .tool_dispatcher_mode = .parallel,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
        .memory_session_id = "agent:zaki-bot:user:1:thread:rollout",
    };
    defer agent.deinit();

    try std.testing.expect(!agent.parallelDispatchCanaryAllowsSession());

    agent.parallel_tools_rollout_percent = 100;
    try std.testing.expect(agent.parallelDispatchCanaryAllowsSession());

    agent.parallel_tools_rollout_percent = 1;
    const bucket = agent.parallelDispatchSessionBucket();
    try std.testing.expectEqual(bucket < 1, agent.parallelDispatchCanaryAllowsSession());
}

test "Agent streaming fields can be set" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
    };
    defer agent.deinit();

    var ctx: u8 = 42;
    const test_cb: providers.StreamCallback = struct {
        fn cb(_: *anyopaque, _: providers.StreamChunk) void {}
    }.cb;
    agent.stream_callback = test_cb;
    agent.stream_ctx = @ptrCast(&ctx);

    try std.testing.expect(agent.stream_callback != null);
    try std.testing.expect(agent.stream_ctx != null);
}

test "Agent shouldForceActionFollowThrough detects english deferred promise" {
    try std.testing.expect(Agent.shouldForceActionFollowThrough("I'll try again with a different filename now."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("let me check that and get back in a moment"));
}

test "Agent shouldForceActionFollowThrough detects russian deferred promise" {
    try std.testing.expect(Agent.shouldForceActionFollowThrough("Сейчас попробую переснять и отправить файл."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("сейчас проверю и вернусь с результатом"));
}

test "Agent shouldForceActionFollowThrough ignores normal final answer" {
    try std.testing.expect(!Agent.shouldForceActionFollowThrough("Вот результат: файл успешно отправлен."));
    try std.testing.expect(!Agent.shouldForceActionFollowThrough("I cannot do that in this environment."));
}

test "Agent startsWithToolCallMarkup detects malformed tool output" {
    try std.testing.expect(Agent.startsWithToolCallMarkup("<tool_call>\n{\"name\":\"shell\",\"arguments\":{}}"));
    try std.testing.expect(Agent.startsWithToolCallMarkup(" \n\t<tool_call>\n{\"name\":\"shell\",\"arguments\":{}}"));
}

test "Agent startsWithToolCallMarkup ignores normal text" {
    try std.testing.expect(!Agent.startsWithToolCallMarkup("Here is the result."));
    try std.testing.expect(!Agent.startsWithToolCallMarkup("Use <tool_call> tags like this in docs."));
}

test "tts_audio_enabled_does_not_mutate_assistant_text" {
    const allocator = std.testing.allocator;
    const ProviderState = struct {
        fn chatWithSystem(_: *anyopaque, allocator_: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator_.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator_: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{ .content = try allocator_.dupe(u8, "plain response") };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "tts-test";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var state: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = ProviderState.chatWithSystem,
        .chat = ProviderState.chat,
        .supportsNativeTools = ProviderState.supportsNativeTools,
        .getName = ProviderState.getName,
        .deinit = ProviderState.deinitFn,
    };
    const provider = Provider{ .ptr = @ptrCast(&state), .vtable = &vtable };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
        .tts_mode = .always,
        .tts_audio = true,
        .tts_provider = "openai",
    };
    defer agent.deinit();

    const response = try agent.turn("hello");
    defer allocator.free(response);
    try std.testing.expectEqualStrings("plain response", response);
    try std.testing.expect(std.mem.indexOf(u8, response, "[TTS prepared via") == null);
}

test "tts_audio_enabled_telegram_turn_adds_audio_attachment_marker" {
    const allocator = std.testing.allocator;
    const ProviderState = struct {
        fn chatWithSystem(_: *anyopaque, allocator_: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator_.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator_: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{ .content = try allocator_.dupe(u8, "plain response") };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "tts-telegram-test";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const FakeTts = struct {
        fn synth(
            allocator_: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: []const u8,
            _: voice_mod.SynthesizeOptions,
        ) voice_mod.SynthesizeError![]u8 {
            return allocator_.dupe(u8, "/tmp/nullalis_tts_test.mp3");
        }
    };

    const configured_providers = [_]config_types.ProviderEntry{
        .{ .name = "openai", .api_key = "test-openai-key" },
    };

    var state: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = ProviderState.chatWithSystem,
        .chat = ProviderState.chat,
        .supportsNativeTools = ProviderState.supportsNativeTools,
        .getName = ProviderState.getName,
        .deinit = ProviderState.deinitFn,
    };
    const provider = Provider{ .ptr = @ptrCast(&state), .vtable = &vtable };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
        .configured_providers = &configured_providers,
        .tts_mode = .always,
        .tts_audio = true,
        .tts_provider = "openai",
        .tts_synthesize_fn = FakeTts.synth,
    };
    defer agent.deinit();

    tools_mod.setMessageTurnContext(.{
        .channel = "telegram",
        .chat_id = "12345",
        .is_group = false,
        .is_dm = true,
    });
    defer tools_mod.clearMessageTurnContext();

    const response = try agent.turn("hello");
    defer allocator.free(response);
    try std.testing.expect(std.mem.startsWith(u8, response, "[AUDIO:/tmp/nullalis_tts_test.mp3]"));
    try std.testing.expect(std.mem.indexOf(u8, response, "plain response") != null);
}

test "tts_prepare_stage_emitted_when_mode_matches" {
    const allocator = std.testing.allocator;
    const ProviderState = struct {
        fn chatWithSystem(_: *anyopaque, allocator_: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator_.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator_: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{ .content = try allocator_.dupe(u8, "stage check") };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "tts-stage-test";
        }

        fn deinitFn(_: *anyopaque) void {}
    };
    const StageObserver = struct {
        const Self = @This();
        tts_stage_count: u32 = 0,
        const vtable = Observer.VTable{
            .record_event = recordEvent,
            .record_metric = recordMetric,
            .flush = flush,
            .name = name,
        };

        fn observer(self: *Self) Observer {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        fn recordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            switch (event.*) {
                .turn_stage => |stage| {
                    if (std.mem.eql(u8, stage.stage, "tts_prepare")) self.tts_stage_count += 1;
                },
                else => {},
            }
        }

        fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
        fn flush(_: *anyopaque) void {}
        fn name(_: *anyopaque) []const u8 {
            return "tts-stage-observer";
        }
    };

    var state: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = ProviderState.chatWithSystem,
        .chat = ProviderState.chat,
        .supportsNativeTools = ProviderState.supportsNativeTools,
        .getName = ProviderState.getName,
        .deinit = ProviderState.deinitFn,
    };
    const provider = Provider{ .ptr = @ptrCast(&state), .vtable = &vtable };

    var stage_observer = StageObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = stage_observer.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
        .tts_mode = .always,
    };
    defer agent.deinit();

    const response = try agent.turn("hello");
    defer allocator.free(response);
    try std.testing.expectEqualStrings("stage check", response);
    try std.testing.expect(stage_observer.tts_stage_count > 0);
}
