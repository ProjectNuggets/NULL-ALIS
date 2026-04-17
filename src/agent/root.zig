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
const voice_mode = @import("../voice_mode.zig");
const observability = @import("../observability.zig");
const tool_dispatcher = @import("../tool_dispatcher.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const SecurityPolicy = @import("../security/policy.zig").SecurityPolicy;
const RateTracker = @import("../security/policy.zig").RateTracker;
const hooks_mod = @import("../hooks.zig");
const execution_mode_mod = @import("execution_mode.zig");
const ExecutionMode = execution_mode_mod.ExecutionMode;
const tool_metadata = @import("../tools/metadata.zig");
const abort_mod = @import("abort.zig");
const CancellationToken = abort_mod.CancellationToken;

const cache = memory_mod.cache;
pub const abort = @import("abort.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const compaction = @import("compaction.zig");
pub const context_builder = @import("context_builder.zig");
pub const context_cache = @import("context_cache.zig");
pub const context_tokens = @import("context_tokens.zig");
pub const context_report = @import("context_report.zig");
pub const context_engine = @import("context_engine.zig");
pub const max_tokens_resolver = @import("max_tokens.zig");
pub const prompt = @import("prompt.zig");
pub const narration = @import("narration.zig");
pub const task_planner = @import("task_planner.zig");
pub const learning = @import("learning.zig");
pub const run_event_types = @import("run_event_types.zig");
const usage_runtime_mod = @import("../usage_runtime.zig");
pub const memory_loader = @import("memory_loader.zig");
pub const transcript = @import("transcript.zig");
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
    const StreamTimingContext = struct {
        agent: *Agent,
        callback: providers.StreamCallback,
        callback_ctx: *anyopaque,
        iteration: u32,
        provider_start_ms: i64,
        first_token_recorded: bool = false,
        first_token_ms: ?u64 = null,
    };

    fn streamCallbackWithTiming(ctx_ptr: *anyopaque, chunk: providers.StreamChunk) void {
        const ctx: *StreamTimingContext = @ptrCast(@alignCast(ctx_ptr));
        if (!ctx.first_token_recorded and chunk.delta.len > 0) {
            ctx.first_token_recorded = true;
            const first_token_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - ctx.provider_start_ms));
            ctx.first_token_ms = first_token_ms;
            log.info("turn.stage stage=llm_first_token iteration={d} duration_ms={d}", .{
                ctx.iteration,
                first_token_ms,
            });
            const first_token_event = ObserverEvent{ .turn_stage = .{
                .stage = "llm_first_token",
                .iteration = ctx.iteration,
                .duration_ms = first_token_ms,
            } };
            ctx.agent.observer.recordEvent(&first_token_event);
        }
        ctx.callback(ctx.callback_ctx, chunk);
    }

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
    /// Last known origin metadata for this session, owned by Session when present.
    origin_channel: ?[]const u8 = null,
    origin_lane: ?[]const u8 = null,
    origin_chat_id: ?[]const u8 = null,
    origin_account_id: ?[]const u8 = null,
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
    /// Sidecar provider for cheap auxiliary LLM calls (narration, compaction).
    /// null = sidecar not configured, features degrade gracefully.
    sidecar_provider: ?Provider = null,
    sidecar_model: []const u8 = "",
    /// Emit thinking narration every N tool iterations. 0 = disabled.
    narration_interval: u32 = 3,
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    max_tool_iterations: u32,
    max_history_messages: u32,
    /// Sliding-window compaction trigger. See CompactionConfig.history_window_turns.
    history_window_turns: u32 = 0,
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
    execution_mode: ExecutionMode = .execute,
    cancellation_token: CancellationToken = .{},
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
    provider_reliability_active: bool = false,
    compaction_keep_recent: u32 = compaction.DEFAULT_COMPACTION_KEEP_RECENT,
    compaction_max_summary_chars: u32 = compaction.DEFAULT_COMPACTION_MAX_SUMMARY_CHARS,
    compaction_max_source_chars: u32 = compaction.DEFAULT_COMPACTION_MAX_SOURCE_CHARS,
    lifecycle_summarizer_last_attempt_s: i64 = 0,
    lifecycle_summarizer_cooldown_secs: u64 = 900,
    lifecycle_summarizer_timeout_secs: u64 = 60,

    /// Optional security policy for autonomy checks and rate limiting.
    policy: ?*const SecurityPolicy = null,

    /// Security configuration for sandbox, audit, and resource checks.
    /// Used by /security-review slash command to report actual runtime config.
    security_config: config_types.SecurityConfig = .{},

    /// Lifecycle hooks — config-driven shell commands on agent events.
    hooks: []const hooks_mod.Hook = &.{},

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

    /// Optional usage runtime for structured per-turn accounting.
    usage_rt: ?*usage_runtime_mod.UsageRuntime = null,

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

    /// True when force-compression (hard-drop, no LLM summary) was used. Distinguished
    /// from graceful LLM compaction so we can show a stronger user-facing notice.
    context_force_compressed: bool = false,

    /// Turns since last memory nudge (periodic prompt asking agent what to persist).
    turns_since_memory_nudge: u32 = 0,
    /// Tool calls in the last completed turn (for skills auto-extraction).
    last_turn_tool_count: u32 = 0,

    /// Per-turn context lifecycle engine — stateless between turns.
    context_engine_state: context_engine.ContextEngine = .{},

    /// Compact explanation of what context was assembled on the last completed turn.
    last_turn_context: context_builder.LastTurnContext = .{},

    /// Raw user content for the current turn when provider-facing enrichment is active.
    current_turn_raw_user: ?[]const u8 = null,

    /// Enriched provider-facing user content for the current turn only.
    current_turn_enriched_user: ?[]const u8 = null,

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
            .history_window_turns = cfg.agent.history_window_turns,
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
            .provider_reliability_active = cfg.reliability.provider_retries > 0 or
                cfg.reliability.fallback_providers.len > 0 or
                cfg.reliability.model_fallbacks.len > 0,
            .compaction_keep_recent = cfg.agent.compaction_keep_recent,
            .compaction_max_summary_chars = cfg.agent.compaction_max_summary_chars,
            .compaction_max_source_chars = cfg.agent.compaction_max_source_chars,
            .security_config = cfg.security,
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
        self.clearCurrentTurnProviderOverride();
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
    /// Primary trigger: sliding-window (turn-count) — keeps last N user turns
    /// verbatim, collapses older into one summary block. Deterministic latency
    /// bound for stateless providers (Together/Groq) without prefix caching.
    /// Fallback: token-based triggers (60%/75%/85%) if window is 0.
    /// Uses sidecar provider for LLM summarization if available (cost savings:
    /// Groq Llama 8B instead of Sonnet/GLM/K2.5). Falls back to main provider.
    pub fn autoCompactHistory(self: *Agent) !bool {
        const compact_provider = if (self.sidecar_provider) |sp| sp else self.provider;
        const compact_model = if (self.sidecar_provider != null) self.sidecar_model else self.model_name;
        const cfg = compaction.CompactionConfig{
            .keep_recent = self.compaction_keep_recent,
            .max_summary_chars = self.compaction_max_summary_chars,
            .max_source_chars = self.compaction_max_source_chars,
            .token_limit = self.token_limit,
            .max_tokens = self.max_tokens,
            .message_timeout_secs = self.message_timeout_secs,
            .max_history_messages = self.max_history_messages,
            .history_window_turns = self.history_window_turns,
            .workspace_dir = self.workspace_dir,
        };

        // Primary: turn-based sliding window. When this fires, it supersedes
        // token-based passes for this invocation (the window already bounds payload).
        if (self.history_window_turns > 0) {
            const windowed = try compaction.compactByTurnWindow(self.allocator, &self.history, compact_provider, compact_model, cfg);
            if (windowed) return true;
        }

        // Fallback / complementary: token-based passes (handles runaway tool outputs
        // even when turn count is within window).
        return compaction.autoCompactHistory(self.allocator, &self.history, compact_provider, compact_model, cfg);
    }

    /// Manual compaction for explicit operator boundaries.
    pub fn manualCompactHistory(self: *Agent) !bool {
        const compact_provider = if (self.sidecar_provider) |sp| sp else self.provider;
        const compact_model = if (self.sidecar_provider != null) self.sidecar_model else self.model_name;
        return compaction.manualCompactHistory(self.allocator, &self.history, compact_provider, compact_model, .{
            .keep_recent = self.compaction_keep_recent,
            .max_summary_chars = self.compaction_max_summary_chars,
            .max_source_chars = self.compaction_max_source_chars,
            .token_limit = self.token_limit,
            .max_tokens = self.max_tokens,
            .message_timeout_secs = self.message_timeout_secs,
            .max_history_messages = self.max_history_messages,
            .history_window_turns = self.history_window_turns,
            .workspace_dir = self.workspace_dir,
        });
    }

    /// Force-compress history for context exhaustion recovery.
    /// Archives dropped messages to memory (when available) before deleting them.
    pub fn forceCompressHistory(self: *Agent) bool {
        return compaction.forceCompressHistoryWithArchive(
            self.allocator,
            &self.history,
            self.mem,
            self.memory_session_id,
        );
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

    fn clearCurrentTurnProviderOverride(self: *Agent) void {
        if (self.current_turn_enriched_user) |enriched| {
            self.allocator.free(enriched);
        }
        self.current_turn_enriched_user = null;
        self.current_turn_raw_user = null;
    }

    fn isCurrentTurnRawUser(self: *const Agent, content: []const u8) bool {
        const current = self.current_turn_raw_user orelse return false;
        return current.len == content.len and current.ptr == content.ptr;
    }

    fn providerMessageForOwned(self: *const Agent, msg: *const OwnedMessage) ChatMessage {
        if (msg.role == .user and self.isCurrentTurnRawUser(msg.content)) {
            if (self.current_turn_enriched_user) |enriched| {
                return .{ .role = msg.role, .content = enriched };
            }
        }
        return msg.toChatMessage();
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
        return voice_mode.channelSupportsAudio(channel);
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

    const reflection_prompt_execute =
        "Reflect on the tool results above and decide your next steps. " ++
        "If a tool failed due to policy/permissions, do not repeat the same blocked call; explain the limitation and choose a different available tool or ask the user for permission/config change. " ++
        "If a tool failed due to a transient issue (timeout/network/rate-limit), proactively retry up to 2 times with adjusted parameters before giving up. " ++
        "If a tool reports queued/async delivery, state it as queued (not confirmed delivered) unless a later tool confirms delivery.";
    const reflection_prompt_plan =
        "You are in plan mode. Analyze the read-only tool results above and provide a structured plan. Do not attempt to use mutating tools.";
    const reflection_prompt_review =
        "You are in review mode. Analyze the read-only tool results above and provide a structured review with findings and recommendations.";
    const reflection_prompt_background =
        "Process the tool results. Do not attempt user interaction tools.";

    fn getReflectionPrompt(mode: ExecutionMode) []const u8 {
        return switch (mode) {
            .plan => reflection_prompt_plan,
            .execute => reflection_prompt_execute,
            .review => reflection_prompt_review,
            .background => reflection_prompt_background,
        };
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
                    .output = "Action budget exhausted",
                    .success = false,
                    .tool_call_id = call.tool_call_id,
                } };
            }
        }
        // Execution mode gate: block tools not allowed in current mode.
        // Uses the static default metadata registry for built-in tools, then
        // applies args-aware refinement so read-only sub-actions of mutating
        // tools (e.g. `schedule.list`, `git.status`, HTTP GET) are allowed in
        // plan/review. Unknown tool names (MCP, dynamic) fall back to
        // conservative policy.
        if (self.execution_mode != .execute) {
            const registry = tools_mod.defaultMetadataRegistry();
            const base_meta = tool_metadata.lookupMetadata(call.name, registry) orelse
                tool_metadata.ToolMetadata.conservative(call.name);

            const meta = blk: {
                if (base_meta.flags.read_only) break :blk base_meta;
                const parsed = std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    call.arguments_json,
                    .{},
                ) catch break :blk base_meta;
                defer parsed.deinit();
                const args_obj = switch (parsed.value) {
                    .object => |obj| obj,
                    else => break :blk base_meta,
                };
                break :blk tools_mod.refineMetadata(base_meta, args_obj);
            };

            if (!self.execution_mode.allowsTool(meta)) {
                return .{
                    .blocked = .{
                        .name = call.name,
                        .output = switch (self.execution_mode) {
                            .plan => "Tool blocked: not allowed in plan mode (read-only tools only)",
                            .review => "Tool blocked: not allowed in review mode (read-only tools only)",
                            .background => "Tool blocked: not allowed in background mode (background-safe tools only)",
                            .execute => unreachable, // execute allows all tools
                        },
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    },
                };
            }
        }
        return .allowed;
    }

    fn executeToolCallsSerial(
        self: *Agent,
        tool_allocator: std.mem.Allocator,
        iteration: u32,
        parsed_calls: []const ParsedToolCall,
        results_buf: *std.ArrayListUnmanaged(ToolExecutionResult),
    ) !void {
        for (parsed_calls, 0..) |call, i| {
            var tool_use_id_buf: [96]u8 = undefined;
            const tool_use_id = toolUseIdForCall(call, iteration, i, &tool_use_id_buf);
            const command = toolCommandFromCall(call);
            const file_hint = toolFileFromCall(call);
            var files_buf: [1][]const u8 = undefined;
            const files = filesFromHint(file_hint, &files_buf);
            const tool_start_event = ObserverEvent{ .tool_call_start = .{
                .tool = call.name,
                .tool_use_id = tool_use_id,
                .input_preview = call.arguments_json,
                .command = command,
                .files = files,
                .activity_label = toolActivityLabel(call.name),
            } };
            self.observer.recordEvent(&tool_start_event);

            hooks_mod.runHooks(self.allocator, self.hooks, .tool_start, .{
                .tool_name = call.name,
                .session_key = self.memory_session_id,
                .workspace_dir = self.workspace_dir,
            });

            const tool_timer = std.time.milliTimestamp();
            const result = self.executeTool(tool_allocator, call);
            const tool_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - tool_timer)));

            const tool_event = ObserverEvent{ .tool_call = .{
                .tool = call.name,
                .duration_ms = tool_duration,
                .success = result.success,
                .tool_use_id = tool_use_id,
                .output_preview = result.output,
                .output_truncated = result.output.len > 256,
                .result_summary = if (result.success) "completed" else "failed",
                .command = command,
                .files = files,
            } };
            self.observer.recordEvent(&tool_event);

            hooks_mod.runHooks(self.allocator, self.hooks, .tool_end, .{
                .tool_name = call.name,
                .tool_success = result.success,
                .session_key = self.memory_session_id,
                .workspace_dir = self.workspace_dir,
            });

            try results_buf.append(self.allocator, result);
        }
    }

    fn toolUseIdForCall(call: ParsedToolCall, iteration: u32, index: usize, buf: *[96]u8) ?[]const u8 {
        if (call.tool_call_id) |id| return id;
        return std.fmt.bufPrint(buf, "local-{d}-{d}-{s}", .{ iteration, index, call.name }) catch null;
    }

    fn toolActivityLabel(tool_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, tool_name, "bash") or std.mem.eql(u8, tool_name, "shell")) return "Running command";
        if (std.mem.eql(u8, tool_name, "powershell")) return "Running PowerShell command";
        if (std.mem.eql(u8, tool_name, "file_read") or std.mem.eql(u8, tool_name, "read")) return "Reading file";
        if (std.mem.eql(u8, tool_name, "file_write") or std.mem.eql(u8, tool_name, "write_file")) return "Writing file";
        if (std.mem.eql(u8, tool_name, "file_edit") or std.mem.eql(u8, tool_name, "edit")) return "Editing file";
        if (std.mem.eql(u8, tool_name, "grep") or std.mem.eql(u8, tool_name, "search")) return "Searching files";
        if (std.mem.eql(u8, tool_name, "glob") or std.mem.eql(u8, tool_name, "list")) return "Listing files";
        return null;
    }

    fn toolCommandFromCall(call: ParsedToolCall) ?[]const u8 {
        if (std.mem.eql(u8, call.name, "bash") or std.mem.eql(u8, call.name, "shell") or std.mem.eql(u8, call.name, "powershell")) {
            return extractJsonStringField(call.arguments_json, "command");
        }
        return null;
    }

    fn toolFileFromCall(call: ParsedToolCall) ?[]const u8 {
        if (extractJsonStringField(call.arguments_json, "file_path")) |file_path| return file_path;
        if (extractJsonStringField(call.arguments_json, "path")) |path| return path;
        if (extractJsonStringField(call.arguments_json, "filename")) |filename| return filename;
        return null;
    }

    fn filesFromHint(file_hint: ?[]const u8, files_buf: *[1][]const u8) ?[]const []const u8 {
        if (file_hint) |file| {
            files_buf[0] = file;
            return files_buf[0..1];
        }
        return null;
    }

    fn skipJsonWhitespace(json: []const u8, start: usize) usize {
        var i = start;
        while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t')) : (i += 1) {}
        return i;
    }

    fn extractJsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, json, search_from, key)) |key_start| {
            const key_end = key_start + key.len;
            if (key_start == 0 or key_end >= json.len or json[key_start - 1] != '"' or json[key_end] != '"') {
                search_from = key_end;
                continue;
            }
            var i = skipJsonWhitespace(json, key_end + 1);
            if (i >= json.len or json[i] != ':') {
                search_from = key_end;
                continue;
            }
            i = skipJsonWhitespace(json, i + 1);
            if (i >= json.len or json[i] != '"') {
                search_from = key_end;
                continue;
            }
            const value_start = i + 1;
            i = value_start;
            var escaped = false;
            while (i < json.len) : (i += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (json[i] == '\\') {
                    escaped = true;
                    continue;
                }
                if (json[i] == '"') return json[value_start..i];
            }
            return null;
        }
        return null;
    }

    fn executeToolCallsParallel(
        self: *Agent,
        tool_allocator: std.mem.Allocator,
        iteration: u32,
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
            var tool_use_id_buf: [96]u8 = undefined;
            const tool_use_id = toolUseIdForCall(call, iteration, i, &tool_use_id_buf);
            const command = toolCommandFromCall(call);
            const file_hint = toolFileFromCall(call);
            var files_buf: [1][]const u8 = undefined;
            const files = filesFromHint(file_hint, &files_buf);
            const tool_start_event = ObserverEvent{ .tool_call_start = .{
                .tool = call.name,
                .tool_use_id = tool_use_id,
                .input_preview = call.arguments_json,
                .command = command,
                .files = files,
                .activity_label = toolActivityLabel(call.name),
            } };
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
            var tool_use_id_buf: [96]u8 = undefined;
            const tool_use_id = toolUseIdForCall(call, iteration, i, &tool_use_id_buf);
            const command = toolCommandFromCall(call);
            const file_hint = toolFileFromCall(call);
            var files_buf: [1][]const u8 = undefined;
            const files = filesFromHint(file_hint, &files_buf);
            const tool_event = ObserverEvent{ .tool_call = .{
                .tool = call.name,
                .duration_ms = ordered_durations[i],
                .success = result.success,
                .tool_use_id = tool_use_id,
                .output_preview = result.output,
                .output_truncated = result.output.len > 256,
                .result_summary = if (result.success) "completed" else "failed",
                .command = command,
                .files = files,
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
        self.cancellation_token.reset(); // Clear stale cancellation from previous turn
        commands.refreshSubagentToolContext(self);
        var turn_llm_calls: u32 = 0;
        var turn_retry_attempts: u32 = 0;
        var turn_tool_calls_total: u32 = 0;
        var turn_tool_iterations: u32 = 0;
        var turn_memory_enrich_ms: u64 = 0;
        var turn_compaction_ms: u64 = 0;
        var turn_first_token_ms: ?u64 = null;
        var turn_first_token_upper_bound_ms: ?u64 = null;

        // ── Adaptive exit: repeated-call detector ─────────────────────────
        // Tracks the FNV-1a hash of the last 3 tool call sets (name+args). If
        // the same hash appears 3 times in a row within a single turn, the
        // agent is stuck in a loop — terminate early with a synthesis prompt
        // instead of burning through max_tool_iterations. Hash of 0 is sentinel
        // for "slot unused". ring buffer indexed by `recent_call_idx % 3`.
        const LOOP_WINDOW: usize = 3;
        var recent_call_hashes: [LOOP_WINDOW]u64 = .{ 0, 0, 0 };
        var recent_call_idx: usize = 0;
        var loop_detected: bool = false;

        // Handle slash commands before sending to LLM (saves tokens)
        if (try self.handleSlashCommand(user_message)) |response| {
            return response;
        }

        self.context_was_compacted = false;
        self.context_force_compressed = false;
        self.last_turn_context = .{};
        self.clearCurrentTurnProviderOverride();
        defer self.clearCurrentTurnProviderOverride();

        const turn_start_event = ObserverEvent{ .turn_stage = .{
            .stage = "turn_start",
        } };
        self.observer.recordEvent(&turn_start_event);

        // Fire turn_start hooks
        hooks_mod.runHooks(self.allocator, self.hooks, .turn_start, .{
            .session_key = self.memory_session_id,
            .workspace_dir = self.workspace_dir,
        });

        // Inject system prompt on first turn (or when tracked workspace files changed).
        const prompt_refresh_plan = context_builder.buildPromptRefreshPlan(self);

        if (prompt_refresh_plan.should_refresh_system_prompt) {
            var cfg_for_caps_opt: ?Config = Config.load(self.allocator) catch null;
            defer if (cfg_for_caps_opt) |*cfg_loaded| cfg_loaded.deinit();
            const cfg_for_caps_ptr: ?*const Config = if (cfg_for_caps_opt) |*cfg_loaded| cfg_loaded else null;

            const capabilities_section = capabilities_mod.buildPromptSection(
                self.allocator,
                cfg_for_caps_ptr,
                self.tools,
            ) catch null;
            defer if (capabilities_section) |section| self.allocator.free(section);

            // Resolve persona from SOUL.md front-matter (REQ-022). Falls back to defaults when absent.
            const persona_profile_opt = prompt.resolvePersonaFromFile(self.allocator, self.workspace_dir);
            defer if (persona_profile_opt) |p| {
                if (p.voice) |v| self.allocator.free(v);
            };
            const persona_section: ?prompt.PersonaSection = if (persona_profile_opt) |p| .{
                .warmth = p.warmth,
                .proactivity = p.proactivity,
                .voice_style = p.voice,
                .twin_mode = p.twin_mode,
            } else null;

            const system_prompt = try prompt.buildSystemPrompt(self.allocator, .{
                .workspace_dir = self.workspace_dir,
                .model_name = self.model_name,
                .tools = self.tools,
                .capabilities_section = capabilities_section,
                .conversation_context = self.conversation_context,
                .sections = .{ .persona = persona_section },
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
            self.system_prompt_has_conversation_context = prompt_refresh_plan.conversation_context_present;
            self.system_prompt_conversation_context_fingerprint = prompt_refresh_plan.conversation_context_fingerprint;
            self.workspace_prompt_fingerprint = prompt_refresh_plan.workspace_prompt_fingerprint;
            self.system_prompt_time_bucket_min = prompt_refresh_plan.current_time_bucket_min;
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

        // Enrich message with memory context for the current provider-facing turn only.
        // Uses retrieval pipeline (hybrid search, RRF, temporal decay, MMR) when MemoryRuntime is available.
        const enrich_start_ms = std.time.milliTimestamp();
        const enrichment = if (self.mem) |mem|
            // Graceful degradation: if memory enrichment fails (backend error,
            // connectivity issue), proceed with the raw user message rather
            // than killing the entire turn. Memory is an enhancement, not a
            // prerequisite for conversation.
            memory_loader.enrichMessageWithRuntimeDetailed(self.allocator, mem, self.mem_rt, user_message, self.memory_session_id) catch |err| blk: {
                log.warn("memory.enrichment_failed error={s} — proceeding with raw message", .{@errorName(err)});
                break :blk memory_loader.EnrichmentResult{
                    .text = try self.allocator.dupe(u8, user_message),
                    .stats = .{},
                };
            }
        else
            memory_loader.EnrichmentResult{
                .text = try self.allocator.dupe(u8, user_message),
                .stats = .{},
            };
        const enriched = enrichment.text;
        const enrich_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - enrich_start_ms));
        turn_memory_enrich_ms = enrich_duration_ms;
        self.last_turn_context = context_builder.buildLastTurnContext(
            prompt_refresh_plan,
            enrichment.stats,
            enrich_duration_ms,
        );
        log.info("turn.stage stage=memory_enrich duration_ms={d}", .{enrich_duration_ms});
        const memory_stage_event = ObserverEvent{ .turn_stage = .{
            .stage = "memory_enrich",
            .duration_ms = enrich_duration_ms,
        } };
        self.observer.recordEvent(&memory_stage_event);
        self.current_turn_enriched_user = enriched;
        errdefer self.clearCurrentTurnProviderOverride();

        // NOTE: Narration frames flow only through the Observer event bus.
        // They must NEVER be appended to self.history — see narration.zig.
        const raw_user_history = try self.allocator.dupe(u8, user_message);
        var raw_user_history_appended = false;
        errdefer if (!raw_user_history_appended) self.allocator.free(raw_user_history);
        try self.history.append(self.allocator, .{
            .role = .user,
            .content = raw_user_history,
        });
        raw_user_history_appended = true;
        self.current_turn_raw_user = raw_user_history;

        // ── Learning signal detection (REQ-021) ─────────────────────
        // Scan user message for corrections/preferences. If found, extract
        // a behavioral fact and store it as a durable_fact/behavior/ key.
        if (self.mem) |mem| {
            const signals = learning.detectLearningSignals(self.allocator, user_message) catch &.{};
            defer if (signals.len > 0) self.allocator.free(signals);
            if (signals.len > 0) {
                const fact_content = learning.extractFactFromMessage(self.allocator, user_message, signals) catch null;
                defer if (fact_content) |fc| self.allocator.free(fc);
                if (fact_content) |fc| {
                    // T-1.5-08: enforce MAX_FACTS_PER_SESSION before storing
                    const at_limit = blk: {
                        const entries = mem.list(self.allocator, null, self.memory_session_id) catch break :blk false;
                        defer if (entries.len > 0) {
                            for (entries) |e| {
                                self.allocator.free(e.key);
                                self.allocator.free(e.content);
                            }
                            self.allocator.free(entries);
                        };
                        var fact_count: usize = 0;
                        for (entries) |e| {
                            if (std.mem.startsWith(u8, e.key, "durable_fact/behavior/")) fact_count += 1;
                        }
                        break :blk fact_count >= learning.MAX_FACTS_PER_SESSION;
                    };
                    if (at_limit) {
                        log.warn("learning.max_facts_reached session={?s}", .{self.memory_session_id});
                    } else {
                        const key = learning.factKey(self.allocator, fc) catch null;
                        if (key) |k| {
                            defer self.allocator.free(k);
                            _ = mem.store(k, fc, .core, self.memory_session_id) catch {};
                            log.info("learning.signal_detected signals={d} key={s}", .{ signals.len, k });
                        }
                    }
                }
            }
        }

        if (self.compact_context_enabled) {
            self.last_turn_compacted = false;
            log.info("turn.stage stage=turn_compaction duration_ms=0 mode=auto", .{});
            const compact_stage_event = ObserverEvent{ .turn_stage = .{
                .stage = "turn_compaction",
                .duration_ms = 0,
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
                    if (self.compact_context_enabled) {
                        const history_before_auto_compact = self.history.items.len;
                        self.last_turn_compacted = self.autoCompactHistory() catch false;
                        if (self.last_turn_compacted) {
                            self.recordAutoCompaction(history_before_auto_compact, self.history.items.len);
                            self.refreshDurableContinuityAfterCompaction();
                        }
                    }
                    self.ensureDurableContinuitySeed();
                    const cache_hit_event = ObserverEvent{ .turn_stage = .{
                        .stage = "response_cache_hit",
                    } };
                    self.observer.recordEvent(&cache_hit_event);
                    self.last_turn_context.cache_hit = true;
                    const complete_event = ObserverEvent{ .turn_complete = {} };
                    self.observer.recordEvent(&complete_event);
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
                if (self.compact_context_enabled) {
                    const history_before_auto_compact = self.history.items.len;
                    self.last_turn_compacted = self.autoCompactHistory() catch false;
                    if (self.last_turn_compacted) {
                        self.recordAutoCompaction(history_before_auto_compact, self.history.items.len);
                        self.refreshDurableContinuityAfterCompaction();
                    }
                }
                self.ensureDurableContinuitySeed();
                const cache_hit_event = ObserverEvent{ .turn_stage = .{
                    .stage = "response_cache_hit",
                } };
                self.observer.recordEvent(&cache_hit_event);
                self.last_turn_context.cache_hit = true;
                const complete_event = ObserverEvent{ .turn_complete = {} };
                self.observer.recordEvent(&complete_event);
                return cached_response;
            }
        }

        if (self.compact_context_enabled) {
            // Run provider-backed auto-compaction against the full working
            // session so context boundaries create durable continuity objects.
            const auto_compact_start_ms = std.time.milliTimestamp();
            const history_before_auto_compact = self.history.items.len;
            self.last_turn_compacted = self.autoCompactHistory() catch false;
            if (self.last_turn_compacted) {
                self.recordAutoCompaction(history_before_auto_compact, self.history.items.len);
                const auto_compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - auto_compact_start_ms));
                turn_compaction_ms += auto_compact_duration_ms;
                log.info("turn.stage stage=turn_auto_compaction duration_ms={d}", .{auto_compact_duration_ms});
                const auto_compact_stage_event = ObserverEvent{ .turn_stage = .{
                    .stage = "turn_auto_compaction",
                    .duration_ms = auto_compact_duration_ms,
                } };
                self.observer.recordEvent(&auto_compact_stage_event);
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

            // ── Adaptive exit: loop detected last iteration ──────────────
            // If repeated-call detector flagged a loop in the previous
            // iteration, drop out of the tool loop now and let the exhaustion
            // path produce a summary. This fires before LLM/tool work, so we
            // don't pay another iteration's cost for a known-stuck agent.
            if (loop_detected) {
                log.warn("agent.loop_exit iteration={d} — breaking to summary fallback", .{iteration});
                break;
            }

            // ── Cooperative cancellation check ──────────────────────────
            if (self.cancellation_token.isCancelled()) {
                log.warn("Turn cancelled at iteration {d}", .{iteration});
                const cancel_event = ObserverEvent{ .turn_cancelled = .{ .reason = "user_request", .iteration = iteration } };
                self.observer.recordEvent(&cancel_event);
                const complete_event = ObserverEvent{ .turn_complete = {} };
                self.observer.recordEvent(&complete_event);
                return try self.allocator.dupe(u8, "[Cancelled]");
            }

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
            var saw_stream_first_token = false;
            turn_llm_calls += 1;

            // Call provider: streaming or blocking. Reliable wrappers may retry/fallback internally.
            var response: ChatResponse = undefined;
            if (is_streaming) {
                var stream_timing_ctx = StreamTimingContext{
                    .agent = self,
                    .callback = self.stream_callback.?,
                    .callback_ctx = self.stream_ctx.?,
                    .iteration = iteration,
                    .provider_start_ms = timer_start,
                };
                const stream_result = self.provider.streamChat(
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
                    streamCallbackWithTiming,
                    @ptrCast(&stream_timing_ctx),
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
                saw_stream_first_token = stream_timing_ctx.first_token_recorded;
                if (stream_timing_ctx.first_token_ms) |value| {
                    turn_first_token_ms = value;
                }
                response = ChatResponse{
                    .content = stream_result.content,
                    .tool_calls = stream_result.tool_calls,
                    .usage = stream_result.usage,
                    .model = stream_result.model,
                    .reasoning_content = stream_result.reasoning_content,
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
                        blk: {
                            const history_before = self.history.items.len;
                            if (!self.forceCompressHistory()) break :blk false;
                            self.recordForceCompression(history_before, self.history.items.len);
                            break :blk true;
                        })
                    {
                        self.context_was_compacted = true;
                        self.context_force_compressed = true;
                        turn_retry_attempts += 1;
                        turn_llm_calls += 1;
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

                    if (self.provider_reliability_active) return err;

                    // Retry once
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    turn_retry_attempts += 1;
                    turn_llm_calls += 1;
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
                        if (self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and blk: {
                            const history_before = self.history.items.len;
                            if (!self.forceCompressHistory()) break :blk false;
                            self.recordForceCompression(history_before, self.history.items.len);
                            break :blk true;
                        }) {
                            self.context_was_compacted = true;
                            self.context_force_compressed = true;
                            turn_retry_attempts += 1;
                            turn_llm_calls += 1;
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
            if (!is_streaming or !saw_stream_first_token) {
                log.info("turn.stage stage=llm_first_token_upper_bound iteration={d} duration_ms={d}", .{
                    iteration,
                    duration_ms,
                });
                turn_first_token_upper_bound_ms = duration_ms;
                const first_token_bound_event = ObserverEvent{ .turn_stage = .{
                    .stage = "llm_first_token_upper_bound",
                    .iteration = iteration,
                    .duration_ms = duration_ms,
                } };
                self.observer.recordEvent(&first_token_bound_event);
            }

            // Track tokens
            self.total_tokens += response.usage.total_tokens;
            self.last_turn_usage = response.usage;
            if (self.usage_rt) |urt| {
                const input: u64 = @intCast(response.usage.prompt_tokens);
                const output: u64 = @intCast(response.usage.completion_tokens);
                urt.recordTurn(
                    self.default_provider,
                    input,
                    output,
                    0.0, // Cost calculation deferred to provider-specific pricing
                    0, // Duration refined when timing context available
                );
            }

            const response_text = response.contentOrEmpty();
            const use_native = response.hasToolCalls();

            // ── Native thinking narration ──
            // If the model returned reasoning_content (Claude extended thinking,
            // GLM <think> blocks, Kimi reasoning), emit it as a thinking narration
            // frame. This is the Claude Code approach: the model's own reasoning
            // IS the narration. No sidecar call needed.
            if (response.reasoning_content) |thinking| {
                if (thinking.len > 0) {
                    // Truncate to a reasonable narration length for the UI
                    const max_narration = @min(thinking.len, 200);
                    const thinking_event = ObserverEvent{ .narration_frame = .{
                        .message = thinking[0..max_narration],
                        .frame_type = .thinking,
                    } };
                    self.observer.recordEvent(&thinking_event);
                }
            }

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
            if (parsed_calls.len > 0) {
                turn_tool_iterations += 1;
                turn_tool_calls_total += @intCast(@min(parsed_calls.len, std.math.maxInt(u32)));
            }

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
                    if (self.compact_context_enabled) {
                        const history_before_auto_compact = self.history.items.len;
                        self.last_turn_compacted = self.autoCompactHistory() catch false;
                        if (self.last_turn_compacted) {
                            self.recordAutoCompaction(history_before_auto_compact, self.history.items.len);
                        }
                    }
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
                    const was_force = self.context_force_compressed;
                    self.context_was_compacted = false;
                    self.context_force_compressed = false;
                    const prefix = if (was_force)
                        // Hard-drop: older messages were removed without summarization.
                        // User deserves a clear signal that continuity is broken.
                        "[Context recovery: older messages were dropped to fit within the context window. Some history may be inaccessible.]\n\n"
                    else
                        "[Context compacted]\n\n";
                    break :blk try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, safe_display_text });
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

                const compact_start_ms = std.time.milliTimestamp();
                if (self.compact_context_enabled and !self.last_turn_compacted) {
                    const history_before_auto_compact = self.history.items.len;
                    self.last_turn_compacted = self.autoCompactHistory() catch false;
                    if (self.last_turn_compacted) {
                        self.recordAutoCompaction(history_before_auto_compact, self.history.items.len);
                    }
                }
                const compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - compact_start_ms));
                log.info("turn.stage stage=post_reply_compaction iteration={d} duration_ms={d} compacted={}", .{
                    iteration,
                    compact_duration_ms,
                    self.last_turn_compacted,
                });
                const compact_stage_event = ObserverEvent{ .turn_stage = .{
                    .stage = "post_reply_compaction",
                    .iteration = iteration,
                    .duration_ms = compact_duration_ms,
                } };
                self.observer.recordEvent(&compact_stage_event);

                if (self.last_turn_compacted) {
                    self.refreshDurableContinuityAfterCompaction();
                }
                self.ensureDurableContinuitySeed();

                // Auto-save the exact final user-visible reply as cold transcript memory.
                const autosave_start_ms = std.time.milliTimestamp();
                if (self.auto_save) {
                    if (self.mem) |mem| {
                        const visible_reply = if (tts_audio_reply_text) |audio_reply| audio_reply else final_text;
                        const ts: u128 = @bitCast(std.time.nanoTimestamp());
                        const save_key = std.fmt.allocPrint(self.allocator, "autosave_assistant_{d}", .{ts}) catch null;
                        if (save_key) |key| {
                            defer self.allocator.free(key);
                            if (mem.store(key, visible_reply, .conversation, self.memory_session_id)) |_| {
                                // Vector sync after auto-save
                                if (self.mem_rt) |rt| {
                                    rt.syncVectorAfterStore(self.allocator, key, visible_reply);
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

                // ── Hermes-inspired post-turn maintenance ──

                // Track tool usage for skills extraction
                self.last_turn_tool_count = turn_tool_calls_total;

                // Periodic memory nudge: every 10 turns, inject a prompt asking the
                // agent to self-evaluate what to persist to long-term memory. The agent
                // decides what's worth remembering — better than any heuristic.
                // Hermes Agent pattern: "the agent itself is the best judge of what
                // to remember."
                self.turns_since_memory_nudge += 1;
                if (self.turns_since_memory_nudge >= 10) {
                    self.turns_since_memory_nudge = 0;
                    if (self.mem != null) {
                        // Use .user role (not .system) because Anthropic/Gemini drop
                        // mid-history system messages. The "SYSTEM:" prefix ensures
                        // the model treats it as an instruction, not user input.
                        try self.history.append(self.allocator, .{
                            .role = .user,
                            .content = try self.allocator.dupe(u8,
                                "SYSTEM: Review the recent conversation. If any user preferences, " ++
                                "important decisions, or reusable procedures should be remembered " ++
                                "long-term, save them now using the memory tool. Only save what " ++
                                "has lasting relevance beyond this session."),
                        });
                        log.info("turn.stage stage=memory_nudge turns_elapsed=10", .{});
                    }
                }

                // Skills auto-extraction: after complex tasks (5+ tool calls), prompt
                // the agent to extract a reusable procedure. Hermes pattern: the self-
                // improvement flywheel. Cooldown: only prompt if the previous turn
                // did NOT already have 5+ tool calls (avoid per-turn injection in
                // sustained agentic workflows).
                if (turn_tool_calls_total >= 5 and self.workspace_dir.len > 0 and
                    self.last_turn_tool_count < 5)
                {
                    try self.history.append(self.allocator, .{
                        .role = .user,
                        .content = try self.allocator.dupe(u8,
                            "SYSTEM: You just completed a multi-step task with multiple tool " ++
                            "calls. If this procedure could be useful in the future, consider " ++
                            "saving it as a reusable skill file (SKILL.md) in the workspace. " ++
                            "Only do this if the procedure is genuinely reusable — not for " ++
                            "one-off tasks."),
                    });
                    log.info("turn.stage stage=skills_extraction_prompt tool_calls={d}", .{turn_tool_calls_total});
                }

                // Fire turn_end hooks
                hooks_mod.runHooks(self.allocator, self.hooks, .turn_end, .{
                    .session_key = self.memory_session_id,
                    .workspace_dir = self.workspace_dir,
                });

                // Free provider response fields (content, tool_calls, model)
                // All borrows have been duped into final_text and history at this point.
                self.freeResponseFields(&response);
                self.allocator.free(base_text);

                // ── Cache store (only for direct responses, no tool calls) ──
                const cache_start_ms = std.time.milliTimestamp();
                var cached = false;
                var cache_duration_ms: u64 = 0;
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
                        ) catch |err| {
                            log.warn("response_cache: semantic cache put failed ({}); cache miss on next identical query", .{err});
                        };
                        cached = true;
                    }
                }

                if (self.response_cache) |rc| {
                    rc.put(self.allocator, store_key_hex, self.model_name, final_text, token_count) catch |err| {
                        log.warn("response_cache: exact-match cache put failed ({}); cache miss on next identical query", .{err});
                    };
                    cached = true;
                }

                if (cached) {
                    cache_duration_ms = @intCast(@max(0, std.time.milliTimestamp() - cache_start_ms));
                    log.info("turn.stage stage=response_cache_put iteration={d} duration_ms={d}", .{ iteration, cache_duration_ms });
                }

                const finalize_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - finalize_start_ms));
                const total_turn_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - turn_start_ms));
                const first_token_ms_i64: i64 = if (turn_first_token_ms) |value| @intCast(value) else -1;
                const first_token_upper_bound_ms_i64: i64 = if (turn_first_token_upper_bound_ms) |value| @intCast(value) else -1;
                const post_reply_maintenance_ms: u64 = autosave_duration_ms + outbox_duration_ms + cache_duration_ms;
                log.info("turn.profile kind={s} llm_calls={d} retries={d} tool_iterations={d} tool_calls={d} first_token_ms={d} first_token_upper_bound_ms={d} memory_enrich_ms={d} pre_compaction_ms={d} autosave_ms={d} outbox_ms={d} cache_put_ms={d} post_reply_maintenance_ms={d} total_turn_ms={d}", .{
                    if (turn_tool_calls_total > 0) "tool" else "direct",
                    turn_llm_calls,
                    turn_retry_attempts,
                    turn_tool_iterations,
                    turn_tool_calls_total,
                    first_token_ms_i64,
                    first_token_upper_bound_ms_i64,
                    turn_memory_enrich_ms,
                    turn_compaction_ms,
                    autosave_duration_ms,
                    outbox_duration_ms,
                    cache_duration_ms,
                    post_reply_maintenance_ms,
                    total_turn_ms,
                });
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

            // ── Adaptive exit: repeated-call detector ─────────────────────
            // Hash this iteration's tool call set. If the same hash has
            // appeared in every slot of the ring buffer (LOOP_WINDOW
            // consecutive iterations), we're looping — set loop_detected so
            // the outer loop can exit cleanly after this iteration completes.
            var h = std.hash.Fnv1a_64.init();
            for (parsed_calls) |call| {
                h.update(call.name);
                h.update("\x00");
                h.update(call.arguments_json);
                h.update("\x01");
            }
            const call_set_hash = h.final();
            recent_call_hashes[recent_call_idx % LOOP_WINDOW] = call_set_hash;
            recent_call_idx += 1;
            if (recent_call_idx >= LOOP_WINDOW) {
                var all_same = true;
                for (recent_call_hashes) |hv| {
                    if (hv != call_set_hash) { all_same = false; break; }
                }
                if (all_same) {
                    loop_detected = true;
                    log.warn("agent.loop_detected iteration={d} hash={x} — same tool_call set repeated {d}x, will exit after this iteration", .{
                        iteration,
                        call_set_hash,
                        LOOP_WINDOW,
                    });
                }
            }

            // Execute tool calls (serial by default, optional parallel dispatcher)
            var results_buf: std.ArrayListUnmanaged(ToolExecutionResult) = .empty;
            defer results_buf.deinit(self.allocator);
            try results_buf.ensureTotalCapacity(self.allocator, parsed_calls.len);
            const dispatch_start_ms = std.time.milliTimestamp();
            const used_parallel_dispatch = self.shouldParallelDispatch(parsed_calls);
            if (used_parallel_dispatch) {
                try self.executeToolCallsParallel(arena, iteration, parsed_calls, &results_buf);
            } else {
                try self.executeToolCallsSerial(arena, iteration, parsed_calls, &results_buf);
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
            const reflection_prompt = getReflectionPrompt(self.execution_mode);
            const with_reflection = try std.fmt.allocPrint(
                arena,
                "{s}\n\n{s}",
                .{ scrubbed_results, reflection_prompt },
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

            // ── Thinking narration fallback (sidecar) ──
            // If the model didn't return native reasoning_content on this turn,
            // fall back to the sidecar for narration every N tool iterations.
            // This covers models without native thinking support.
            const had_native_thinking = response.reasoning_content != null and
                response.reasoning_content.?.len > 0;
            if (!had_native_thinking and
                self.sidecar_provider != null and self.narration_interval > 0 and
                turn_tool_iterations > 1 and
                turn_tool_iterations % self.narration_interval == 0)
            {
                const narration_thinking = @import("narration_thinking.zig");
                if (narration_thinking.generateThinkingNarration(
                    self.allocator,
                    self.sidecar_provider.?,
                    self.sidecar_model,
                    self.history.items,
                    self.history.items.len,
                    self.narration_interval,
                )) |thinking_text| {
                    defer self.allocator.free(thinking_text);
                    const thinking_event = ObserverEvent{ .narration_frame = .{
                        .message = thinking_text,
                        .frame_type = .thinking,
                    } };
                    self.observer.recordEvent(&thinking_event);
                    log.info("turn.stage stage=narration_thinking_sidecar iteration={d} len={d}", .{ iteration, thinking_text.len });
                }
            }

            const compact_start_ms = std.time.milliTimestamp();
            if (self.compact_context_enabled) {
                const history_before_auto_compact = self.history.items.len;
                const compacted_after_tools = self.autoCompactHistory() catch false;
                if (compacted_after_tools) {
                    self.last_turn_compacted = true;
                    self.recordAutoCompaction(history_before_auto_compact, self.history.items.len);
                }
            }
            const compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - compact_start_ms));
            log.info("turn.stage stage=history_maintenance_after_tools iteration={d} duration_ms={d}", .{ iteration, compact_duration_ms });
            const compact_stage_event = ObserverEvent{ .turn_stage = .{
                .stage = "history_maintenance_after_tools",
                .iteration = iteration,
                .duration_ms = compact_duration_ms,
            } };
            self.observer.recordEvent(&compact_stage_event);

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

        // Compact history so the next turn can continue from a stable boundary.
        const history_before_auto_compact = self.history.items.len;
        self.last_turn_compacted = self.autoCompactHistory() catch false;
        if (self.last_turn_compacted) {
            self.recordAutoCompaction(history_before_auto_compact, self.history.items.len);
            self.refreshDurableContinuityAfterCompaction();
        }
        const complete_event = ObserverEvent{ .turn_complete = {} };
        self.observer.recordEvent(&complete_event);
        const total_turn_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - turn_start_ms));
        const first_token_ms_i64: i64 = if (turn_first_token_ms) |value| @intCast(value) else -1;
        const first_token_upper_bound_ms_i64: i64 = if (turn_first_token_upper_bound_ms) |value| @intCast(value) else -1;
        log.info("turn.profile kind=tool_exhausted llm_calls={d} retries={d} tool_iterations={d} tool_calls={d} first_token_ms={d} first_token_upper_bound_ms={d} memory_enrich_ms={d} pre_compaction_ms={d} autosave_ms=0 outbox_ms=0 cache_put_ms=0 post_reply_maintenance_ms=0 total_turn_ms={d}", .{
            turn_llm_calls + 1, // include final summary call
            turn_retry_attempts,
            turn_tool_iterations,
            turn_tool_calls_total,
            first_token_ms_i64,
            first_token_upper_bound_ms_i64,
            turn_memory_enrich_ms,
            turn_compaction_ms,
            total_turn_ms,
        });

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
            m[i] = self.providerMessageForOwned(msg);
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
            messages[i] = self.providerMessageForOwned(msg);
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
    fn trimHistoryDetailed(self: *Agent) compaction.TrimStats {
        return compaction.trimHistoryDetailed(self.allocator, &self.history, self.max_history_messages);
    }

    /// Trim history to prevent unbounded growth.
    fn trimHistory(self: *Agent) void {
        _ = self.trimHistoryDetailed();
    }

    fn recordTrimStats(self: *Agent, trim_stats: compaction.TrimStats) void {
        context_builder.recordTrimStats(&self.last_turn_context, trim_stats);
    }

    fn recordAutoCompaction(self: *Agent, history_before: usize, history_after: usize) void {
        context_builder.recordAutoCompaction(&self.last_turn_context, history_before, history_after);
    }

    fn recordForceCompression(self: *Agent, history_before: usize, history_after: usize) void {
        context_builder.recordForceCompression(&self.last_turn_context, history_before, history_after);
    }

    fn refreshDurableContinuityAfterCompaction(self: *Agent) void {
        if (!self.last_turn_compacted) return;
        self.last_turn_context.durable_continuity_refreshed = commands.persistSessionCheckpointDetailed(self, "compaction:auto");
    }

    fn ensureDurableContinuitySeed(self: *Agent) void {
        if (self.last_turn_compacted) return;
        const mem = self.mem orelse return;
        const session_id = self.memory_session_id orelse return;
        if (session_id.len == 0) return;

        const latest_key = std.fmt.allocPrint(self.allocator, "summary_latest/{s}", .{session_id}) catch return;
        defer self.allocator.free(latest_key);

        const latest = mem.get(self.allocator, latest_key) catch return;
        if (latest) |entry| {
            var owned_entry = entry;
            owned_entry.deinit(self.allocator);
            return;
        }

        _ = commands.persistSessionCheckpointDetailed(self, "summary_seed:auto");
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
        self.last_turn_context = .{};
    }

    /// Persist a compact session checkpoint and refresh context anchor.
    /// Used by slash resets and session lifecycle hooks (TTL/eviction).
    pub fn persistSessionCheckpoint(self: *Agent, reason: []const u8) void {
        commands.persistSessionCheckpoint(self, reason);
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

    pub const HistoryPair = struct {
        role: []const u8,
        content: []const u8,
    };

    /// Get history entries as role-string + content pairs (for persistence).
    /// Caller owns the returned slice but NOT the inner strings (borrows from history).
    pub fn getHistory(self: *const Agent, allocator: std.mem.Allocator) ![]HistoryPair {
        const result = try allocator.alloc(HistoryPair, self.history.items.len);
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
    _ = prompt.PromptSections;
    _ = prompt.TurnClass;
    _ = prompt.PersonaSection;
    _ = prompt.PersonaProfile;
    _ = prompt.Warmth;
    _ = prompt.Proactivity;
    _ = prompt.resolvePersona;
    _ = prompt.resolvePersonaFromFile;
    _ = prompt.NarrationPolicy;
}

test "narration module reexport" {
    _ = narration.NarrationObserver;
    _ = narration.NarrationFrame;
    _ = narration.NarrationCallback;
    _ = narration.FrameType;
}

test "memory_loader module reexport" {
    _ = memory_loader.loadContext;
    _ = memory_loader.enrichMessage;
}

test "task_planner module reexport" {
    _ = task_planner.TaskPlan;
    _ = task_planner.TaskStep;
    _ = task_planner.parseTaskPlan;
}

test "learning module reexport" {
    _ = learning.LearningSignal;
    _ = learning.LearnedFact;
    _ = learning.detectLearningSignals;
}

test "run_event_types reexport" {
    _ = run_event_types.RunEventType;
    _ = run_event_types.RunEvent;
    _ = run_event_types.toSseFrame;
}

test "usage_runtime import" {
    _ = usage_runtime_mod.UsageRuntime;
    _ = usage_runtime_mod.TurnUsage;
    _ = usage_runtime_mod.UsageReport;
}

test {
    _ = dispatcher;
    _ = compaction;
    _ = cli;
    _ = prompt;
    _ = memory_loader;
    _ = task_planner;
    _ = learning;
    _ = run_event_types;
    _ = transcript;
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

test "Agent provider messages use current turn enrichment while history stays raw" {
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

    const raw = try allocator.dupe(u8, "raw user text");
    errdefer allocator.free(raw);
    try agent.history.append(allocator, .{
        .role = .user,
        .content = raw,
    });
    agent.current_turn_raw_user = raw;
    agent.current_turn_enriched_user = try allocator.dupe(u8, "[Memory context]\nraw user text");

    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const provider_messages = try agent.buildProviderMessages(arena);
    try std.testing.expectEqual(@as(usize, 1), provider_messages.len);
    try std.testing.expectEqualStrings("[Memory context]\nraw user text", provider_messages[0].content);
    try std.testing.expectEqualStrings("raw user text", agent.history.items[0].content);

    const flat_messages = try agent.buildMessageSlice();
    defer allocator.free(flat_messages);
    try std.testing.expectEqual(@as(usize, 1), flat_messages.len);
    try std.testing.expectEqualStrings("[Memory context]\nraw user text", flat_messages[0].content);
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

const TestSummaryProvider = struct {
    fn chatWithSystem(_: *anyopaque, alloc: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
        return alloc.dupe(
            u8,
            "focus: test summary\n" ++
                "decisions:\n- none\n" ++
                "open_loops:\n- none\n" ++
                "next:\n- none\n",
        );
    }

    fn chat(_: *anyopaque, alloc: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
        return .{
            .content = try alloc.dupe(
                u8,
                "focus: test summary\n" ++
                    "decisions:\n- none\n" ++
                    "open_loops:\n- none\n" ++
                    "next:\n- none\n",
            ),
        };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "test-summary-provider";
    }

    fn deinitFn(_: *anyopaque) void {}
};

var test_summary_provider_state: u8 = 0;
const test_summary_provider_vtable = providers.Provider.VTable{
    .chatWithSystem = TestSummaryProvider.chatWithSystem,
    .chat = TestSummaryProvider.chat,
    .supportsNativeTools = TestSummaryProvider.supportsNativeTools,
    .getName = TestSummaryProvider.getName,
    .deinit = TestSummaryProvider.deinitFn,
};

const TestInvalidSummaryProvider = struct {
    fn chatWithSystem(_: *anyopaque, alloc: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
        return alloc.dupe(u8, "plain text summary without required sections");
    }

    fn chat(_: *anyopaque, alloc: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
        return .{
            .content = try alloc.dupe(u8, "plain text summary without required sections"),
        };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "test-invalid-summary-provider";
    }

    fn deinitFn(_: *anyopaque) void {}
};

var test_invalid_summary_provider_state: u8 = 0;
const test_invalid_summary_provider_vtable = providers.Provider.VTable{
    .chatWithSystem = TestInvalidSummaryProvider.chatWithSystem,
    .chat = TestInvalidSummaryProvider.chat,
    .supportsNativeTools = TestInvalidSummaryProvider.supportsNativeTools,
    .getName = TestInvalidSummaryProvider.getName,
    .deinit = TestInvalidSummaryProvider.deinitFn,
};

const TestFailingSummaryProvider = struct {
    fn chatWithSystem(_: *anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
        return error.ProviderUnavailable;
    }

    fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
        return error.ProviderUnavailable;
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "test-failing-summary-provider";
    }

    fn deinitFn(_: *anyopaque) void {}
};

var test_failing_summary_provider_state: u8 = 0;
const test_failing_summary_provider_vtable = providers.Provider.VTable{
    .chatWithSystem = TestFailingSummaryProvider.chatWithSystem,
    .chat = TestFailingSummaryProvider.chat,
    .supportsNativeTools = TestFailingSummaryProvider.supportsNativeTools,
    .getName = TestFailingSummaryProvider.getName,
    .deinit = TestFailingSummaryProvider.deinitFn,
};

fn makeTestAgent(allocator: std.mem.Allocator) !Agent {
    var noop = observability.NoopObserver{};
    return Agent{
        .allocator = allocator,
        .provider = .{ .ptr = @ptrCast(&test_summary_provider_state), .vtable = &test_summary_provider_vtable },
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

test "slash /context detail preserves last turn context snapshot" {
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
        .last_turn_context = .{
            .available = true,
            .prompt_refreshed = true,
            .workspace_prompt_changed = true,
            .memory_context_injected = true,
            .memory_context_bytes = 123,
            .memory_enrich_ms = 9,
            .cache_hit = false,
        },
    };
    defer agent.deinit();

    const response = try agent.turn("/context detail");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "last_turn: prompt_refresh=yes reason=workspace memory_injected=yes bytes=123 enrich_ms=9 cache_hit=no") != null);
    try std.testing.expect(agent.last_turn_context.available);
    try std.testing.expectEqual(@as(usize, 123), agent.last_turn_context.memory_context_bytes);
}

test "slash /new writes checkpoint, summary objects, and context anchor" {
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
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_channel=app") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_lane=main") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "origin_channel=app") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "origin_lane=main") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_summary_key=timeline_summary/agent:zaki-bot:user:1:main/") != null);

    const session_entries = try mem.list(allocator, .conversation, "agent:zaki-bot:user:1:main");
    defer memory_mod.freeEntries(allocator, session_entries);
    for (session_entries) |entry| {
        if (std.mem.startsWith(u8, entry.key, "session_summary/agent:zaki-bot:user:1:main/")) {
            return error.TestUnexpectedResult;
        }
    }

    var found_timeline_summary = false;
    for (daily_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "timeline_summary/agent:zaki-bot:user:1:main/")) continue;
        found_timeline_summary = true;
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "focus:") != null);
        break;
    }
    try std.testing.expect(found_timeline_summary);

    const latest_key = "summary_latest/agent:zaki-bot:user:1:main";
    const latest = (try mem.get(allocator, latest_key)) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "type=summary_latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "channel=app") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "lane=main") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "origin_channel=app") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "origin_lane=main") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "source_key=timeline_summary/agent:zaki-bot:user:1:main/") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "focus:") != null);

    const timeline_index = (try mem.get(allocator, "timeline_index/current")) orelse return error.TestUnexpectedResult;
    defer timeline_index.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"channel\":\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"lane\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"session\":\"agent:zaki-bot:user:1:main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"key\":\"timeline_summary/agent:zaki-bot:user:1:main/") != null);
    const session_idx = std.mem.indexOf(u8, timeline_index.content, "\"session\":\"agent:zaki-bot:user:1:main\"") orelse return error.TestUnexpectedResult;
    const key_idx = std.mem.indexOf(u8, timeline_index.content, "\"key\":\"timeline_summary/agent:zaki-bot:user:1:main/") orelse return error.TestUnexpectedResult;
    const focus_idx = std.mem.indexOf(u8, timeline_index.content, "\"focus\":\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(session_idx < key_idx);
    try std.testing.expect(key_idx < focus_idx);
}

test "slash /new keeps wrapped telegram provenance inside user-scoped summaries" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:thread:telegram:thread:1110331014";
    agent.auto_save = true;
    tools_mod.setMessageTurnContext(.{
        .channel = "telegram",
        .account_id = "main",
        .chat_id = "1110331014",
    });
    defer tools_mod.clearMessageTurnContext();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "What did we decide on Telegram?"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "We agreed to validate the new summary flow."),
    });

    const response = (try agent.handleSlashCommand("/new")).?;
    defer allocator.free(response);
    try std.testing.expectEqualStrings("Session cleared.", response);

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_session=agent:zaki-bot:user:1:thread:telegram:thread:1110331014") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_channel=telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_lane=thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "origin_channel=telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "origin_lane=thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "origin_chat_id=1110331014") != null);

    const latest = (try mem.get(allocator, "summary_latest/agent:zaki-bot:user:1:thread:telegram:thread:1110331014")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "channel=telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "lane=thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "origin_channel=telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "origin_lane=thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "origin_chat_id=1110331014") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "source_key=timeline_summary/agent:zaki-bot:user:1:thread:telegram:thread:1110331014/") != null);

    const timeline_index = (try mem.get(allocator, "timeline_index/current")) orelse return error.TestUnexpectedResult;
    defer timeline_index.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"channel\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"lane\":\"thread\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"session\":\"agent:zaki-bot:user:1:thread:telegram:thread:1110331014\"") != null);
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
    const latest = try mem.get(allocator, "summary_latest/agent:zaki-bot:user:1:main");
    if (latest) |entry| {
        defer entry.deinit(allocator);
        return error.TestUnexpectedResult;
    }
}

test "persistSessionCheckpoint caps timeline index to 32 descriptors" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.auto_save = true;

    var i: usize = 0;
    while (i < 35) : (i += 1) {
        agent.clearHistory();
        const session_id = try std.fmt.allocPrint(allocator, "agent:zaki-bot:user:1:thread:test-{d}", .{i});
        defer allocator.free(session_id);
        agent.memory_session_id = session_id;

        const message = try std.fmt.allocPrint(allocator, "message {d}", .{i});
        defer allocator.free(message);
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try allocator.dupe(u8, message),
        });

        agent.persistSessionCheckpoint("new");
    }

    const timeline_index = (try mem.get(allocator, "timeline_index/current")) orelse return error.TestUnexpectedResult;
    defer timeline_index.deinit(allocator);

    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, timeline_index.content, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), count);
}

test "persistSessionCheckpoint omits last_summary_key when summarizer is disabled" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
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
        ._summarizer_cfg = .{
            .enabled = false,
            .window_size_tokens = 3000,
            .summary_max_tokens = 300,
            .auto_extract_semantic = true,
        },
    };
    agent.mem_rt = &rt;

    agent.persistSessionCheckpoint("new");

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_checkpoint_key=session_checkpoint_") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_summary_key=") == null);

    const latest = try mem.get(allocator, "summary_latest/agent:zaki-bot:user:1:main");
    if (latest) |entry| {
        defer entry.deinit(allocator);
        return error.TestUnexpectedResult;
    }
}

test "persistSessionCheckpoint includes last_summary_key when fallback summary is written" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.provider = .{ .ptr = @ptrCast(&test_invalid_summary_provider_state), .vtable = &test_invalid_summary_provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "recap this session"),
    });

    agent.persistSessionCheckpoint("new");

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_summary_key=timeline_summary/agent:zaki-bot:user:1:main/") != null);

    const timeline_entries = try mem.list(allocator, .daily, null);
    defer memory_mod.freeEntries(allocator, timeline_entries);
    var found_timeline_summary = false;
    for (timeline_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "timeline_summary/agent:zaki-bot:user:1:main/")) continue;
        found_timeline_summary = true;
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "focus: recap this session") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "next:") != null);
        break;
    }
    try std.testing.expect(found_timeline_summary);
}

test "persistSessionCheckpoint fallback prefers compaction carrier from actual history" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.provider = .{ .ptr = @ptrCast(&test_invalid_summary_provider_state), .vtable = &test_invalid_summary_provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "[Compaction summary]\n" ++
            "- preserved deploy decision and auth issue\n" ++
            "- keep rollout blocked until token truth is fixed\n"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "continue from there"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I will continue from there."),
    });

    agent.persistSessionCheckpoint("compaction:auto");

    const timeline_entries = try mem.list(allocator, .daily, null);
    defer memory_mod.freeEntries(allocator, timeline_entries);
    var found_timeline_summary = false;
    for (timeline_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "timeline_summary/agent:zaki-bot:user:1:main/")) continue;
        found_timeline_summary = true;
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "focus: preserved deploy decision and auth issue") != null);
        break;
    }
    try std.testing.expect(found_timeline_summary);
}

test "persistSessionCheckpoint summary_seed auto uses deterministic summary without provider call" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.provider = .{ .ptr = @ptrCast(&test_failing_summary_provider_state), .vtable = &test_failing_summary_provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "keep the HRS continuity available"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I will keep the HRS continuity available."),
    });

    agent.persistSessionCheckpoint("summary_seed:auto");

    const latest = (try mem.get(allocator, "summary_latest/agent:zaki-bot:user:1:main")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "type=summary_latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "HRS continuity available") != null);

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=summary_seed:auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_summary_key=timeline_summary/agent:zaki-bot:user:1:main/") != null);
}

test "persistSessionCheckpoint blocks fallback overwrite of existing canonical summary_latest" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.provider = .{ .ptr = @ptrCast(&test_failing_summary_provider_state), .vtable = &test_failing_summary_provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";

    const existing_latest =
        "type=summary_latest\n" ++
        "session=agent:zaki-bot:user:1:main\n" ++
        "channel=app\n" ++
        "lane=main\n" ++
        "origin_channel=app\n" ++
        "origin_lane=main\n" ++
        "source_key=timeline_summary/agent:zaki-bot:user:1:main/111\n" ++
        "at=2026-04-08T10:00:00Z\n" ++
        "focus: preserved canonical continuity\n" ++
        "decisions:\n- keep trusted latest\n" ++
        "open_loops:\n- none\n" ++
        "next:\n- stay canonical\n";
    try mem.store("summary_latest/agent:zaki-bot:user:1:main", existing_latest, .core, null);

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "seed deterministic continuity"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I will seed deterministic continuity."),
    });

    agent.persistSessionCheckpoint("summary_seed:auto");

    const latest = (try mem.get(allocator, "summary_latest/agent:zaki-bot:user:1:main")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expectEqualStrings(existing_latest, latest.content);

    const daily_entries = try mem.list(allocator, .daily, null);
    defer memory_mod.freeEntries(allocator, daily_entries);
    var found_timeline_summary = false;
    for (daily_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "timeline_summary/agent:zaki-bot:user:1:main/")) continue;
        found_timeline_summary = true;
        break;
    }
    try std.testing.expect(found_timeline_summary);
}

test "persistSessionCheckpoint upgrades fallback summary_latest to canonical" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";

    const existing_latest =
        "type=summary_latest\n" ++
        "session=agent:zaki-bot:user:1:main\n" ++
        "channel=app\n" ++
        "lane=main\n" ++
        "origin_channel=app\n" ++
        "origin_lane=main\n" ++
        "source_key=timeline_summary/agent:zaki-bot:user:1:main/111\n" ++
        "at=2026-04-08T10:00:00Z\n" ++
        "quality_tier=fallback\n" ++
        "focus: stale fallback continuity\n" ++
        "decisions:\n- none\n" ++
        "open_loops:\n- none\n" ++
        "next:\n- none\n";
    try mem.store("summary_latest/agent:zaki-bot:user:1:main", existing_latest, .core, null);

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "refresh canonical continuity"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I will refresh canonical continuity."),
    });

    agent.persistSessionCheckpoint("new");

    const latest = (try mem.get(allocator, "summary_latest/agent:zaki-bot:user:1:main")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "quality_tier=canonical") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "focus: test summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "stale fallback continuity") == null);
}

test "slash /reset checkpoints and clears history" {
    // /reset now calls handleResetCommand: checkpoint + clear + reset counters.
    // It no longer accepts a model argument (use /model for that).
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const response = (try agent.handleSlashCommand("/reset")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Session reset") != null);
    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
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
        .conversation_retention_days = 0,
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
        .conversation_retention_days = 0,
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

test "slash /compact writes continuity artifacts when compaction succeeds" {
    if (!@import("build_options").enable_sqlite) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:zaki-bot:user:1:main";

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    for (0..3) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "user {d}", .{i}),
        });
        try agent.history.append(allocator, .{
            .role = .assistant,
            .content = try std.fmt.allocPrint(allocator, "assistant {d}", .{i}),
        });
    }

    const response = (try agent.handleSlashCommand("/compact")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Context compacted and continuity refreshed.", response);
    try std.testing.expect(agent.last_turn_compacted);
    try std.testing.expect(agent.last_turn_context.durable_continuity_refreshed);

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=compaction:manual") != null);

    const latest = (try mem.get(allocator, "summary_latest/agent:zaki-bot:user:1:main")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "type=summary_latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "focus:") != null);
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

    const answer_index = std.mem.indexOf(u8, response, "final answer") orelse return error.TestUnexpectedResult;
    const reasoning_index = std.mem.indexOf(u8, response, "Reasoning:\nthinking trace") orelse return error.TestUnexpectedResult;
    try std.testing.expect(answer_index < reasoning_index);
    try std.testing.expect(std.mem.indexOf(u8, response, "[usage] total_tokens=10") != null);
}

test "turn does not duplicate reasoning in final reply when reasoning mode is stream" {
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

    const reasoning_cmd = (try agent.handleSlashCommand("/reasoning stream")).?;
    defer allocator.free(reasoning_cmd);

    const response = try agent.turn("hello");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "final answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Reasoning:\n") == null);
}

test "background origins no longer auto-compact on count boundary without token pressure" {
    const ProviderState = struct {
        calls: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const state: *@This() = @ptrCast(@alignCast(ptr));
            state.calls += 1;
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
            return "trim-only-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state = ProviderState{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ProviderState.chatWithSystem,
        .chat = ProviderState.chat,
        .supportsNativeTools = ProviderState.supportsNativeTools,
        .getName = ProviderState.getName,
        .deinit = ProviderState.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

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
        .max_history_messages = 2,
        .compaction_keep_recent = 1,
        .compact_context_enabled = true,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "u1"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "a1"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "u2"),
    });

    tools_mod.setTurnContext(.{ .origin = .heartbeat });
    defer tools_mod.clearTurnContext();

    const response = try agent.turn("next");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("ok", response);
    try std.testing.expectEqual(@as(usize, 1), provider_state.calls);
    try std.testing.expect(!agent.last_turn_compacted);
}

test "turn auto-compacts on token pressure before provider call" {
    const PressureProvider = struct {
        calls: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const state: *@This() = @ptrCast(@alignCast(ptr));
            state.calls += 1;
            const content = if (state.calls == 1) "compaction summary" else "ok";
            _ = request;
            return .{
                .content = try allocator.dupe(u8, content),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "pressure-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state = PressureProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = PressureProvider.chatWithSystem,
        .chat = PressureProvider.chat,
        .supportsNativeTools = PressureProvider.supportsNativeTools,
        .getName = PressureProvider.getName,
        .deinit = PressureProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

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
        .max_history_messages = 50,
        .token_limit = 4_000,
        .max_tokens = 512,
        .compaction_keep_recent = 2,
        .compact_context_enabled = true,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    for (0..5) |_| {
        const user_payload = try allocator.alloc(u8, 2_500);
        @memset(user_payload, 'u');
        try agent.history.append(allocator, .{
            .role = .user,
            .content = user_payload,
        });
        const assistant_payload = try allocator.alloc(u8, 2_500);
        @memset(assistant_payload, 'a');
        try agent.history.append(allocator, .{
            .role = .assistant,
            .content = assistant_payload,
        });
    }

    const response = try agent.turn("next");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("ok", response);
    // Provider calls >= 2: at least one compaction pass + the turn LLM call.
    // Exact count depends on how many compaction passes trigger (cheap, structured, LLM).
    try std.testing.expect(provider_state.calls >= 2);
    try std.testing.expect(agent.last_turn_compacted);
    try std.testing.expectEqual(@as(usize, 1), agent.last_turn_context.auto_compaction_events);
    try std.testing.expect(agent.last_turn_context.auto_compacted_messages > 0);
}

test "assistant autosave stores the full final visible reply" {
    if (!@import("build_options").enable_sqlite) return error.SkipZigTest;

    const ReplyProvider = struct {
        const reply =
            "This is the full assistant reply that should be persisted exactly as the user saw it, " ++
            "not a truncated autosave summary.";

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, reply);
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, reply),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "test-reply-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ReplyProvider.chatWithSystem,
        .chat = ReplyProvider.chat,
        .supportsNativeTools = ReplyProvider.supportsNativeTools,
        .getName = ReplyProvider.getName,
        .deinit = ReplyProvider.deinitFn,
    };

    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.provider = .{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.auto_save = true;
    agent.memory_session_id = "agent:test:user:1:main";

    const response = try agent.turn("persist this reply");
    defer allocator.free(response);
    try std.testing.expectEqualStrings(ReplyProvider.reply, response);

    const conversation_entries = try mem.list(allocator, .conversation, agent.memory_session_id);
    defer memory_mod.freeEntries(allocator, conversation_entries);

    var found_assistant_autosave = false;
    for (conversation_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "autosave_assistant_")) continue;
        found_assistant_autosave = true;
        try std.testing.expectEqualStrings(ReplyProvider.reply, entry.content);
    }
    try std.testing.expect(found_assistant_autosave);
}

test "auto compaction refreshes durable continuity artifacts" {
    if (!@import("build_options").enable_sqlite) return error.SkipZigTest;

    const CountingProvider = struct {
        calls: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "ok");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
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
            return "counting-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state = CountingProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = CountingProvider.chatWithSystem,
        .chat = CountingProvider.chat,
        .supportsNativeTools = CountingProvider.supportsNativeTools,
        .getName = CountingProvider.getName,
        .deinit = CountingProvider.deinitFn,
    };

    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.provider = .{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:test:user:1:main";
    agent.compact_context_enabled = true;
    agent.compaction_keep_recent = 2;
    agent.token_limit = 4_000;
    agent.max_tokens = 512;

    for (0..5) |_| {
        const user_payload = try allocator.alloc(u8, 2_500);
        @memset(user_payload, 'u');
        try agent.history.append(allocator, .{
            .role = .user,
            .content = user_payload,
        });
        const assistant_payload = try allocator.alloc(u8, 2_500);
        @memset(assistant_payload, 'a');
        try agent.history.append(allocator, .{
            .role = .assistant,
            .content = assistant_payload,
        });
    }

    const response = try agent.turn("next");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("ok", response);
    // Provider calls >= 2: compaction pass(es) + turn LLM call.
    try std.testing.expect(provider_state.calls >= 2);
    try std.testing.expect(agent.last_turn_compacted);
    try std.testing.expect(agent.last_turn_context.durable_continuity_refreshed);

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=compaction:auto") != null);

    const latest = (try mem.get(allocator, "summary_latest/agent:test:user:1:main")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "type=summary_latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "focus:") != null);
}

test "message-count boundary no longer auto-compacts without token pressure" {
    if (!@import("build_options").enable_sqlite) return error.SkipZigTest;

    const ReplyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "ok");
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
            return "trim-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ReplyProvider.chatWithSystem,
        .chat = ReplyProvider.chat,
        .supportsNativeTools = ReplyProvider.supportsNativeTools,
        .getName = ReplyProvider.getName,
        .deinit = ReplyProvider.deinitFn,
    };

    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.provider = .{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:test:user:1:main";
    agent.compact_context_enabled = true;
    agent.max_history_messages = 2;
    agent.compaction_keep_recent = 1;
    agent.token_limit = 262_144;
    agent.max_tokens = 512;

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "old user 1"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "old assistant 1"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "old user 2"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "old assistant 2"),
    });

    const response = try agent.turn("new turn");
    defer allocator.free(response);
    try std.testing.expectEqualStrings("ok", response);

    try std.testing.expect(!agent.last_turn_compacted);
    try std.testing.expect(!agent.last_turn_context.durable_continuity_refreshed);
    try std.testing.expectEqual(@as(u32, 0), agent.last_turn_context.trim_events);

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=summary_seed:auto") != null);

    const latest = (try mem.get(allocator, "summary_latest/agent:test:user:1:main")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "type=summary_latest") != null);
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

test "normal main-lane turn seeds summary_latest when compaction never runs" {
    if (!@import("build_options").enable_sqlite) return error.SkipZigTest;

    const ReplyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "ok");
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
            return "reply-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ReplyProvider.chatWithSystem,
        .chat = ReplyProvider.chat,
        .supportsNativeTools = ReplyProvider.supportsNativeTools,
        .getName = ReplyProvider.getName,
        .deinit = ReplyProvider.deinitFn,
    };

    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.provider = .{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    agent.mem = mem;
    agent.memory_session_id = "agent:test:user:1:main";
    agent.compact_context_enabled = false;

    const response = try agent.turn("hello");
    defer allocator.free(response);
    try std.testing.expectEqualStrings("ok", response);
    try std.testing.expect(!agent.last_turn_compacted);

    const latest = (try mem.get(allocator, "summary_latest/agent:test:user:1:main")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "type=summary_latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest.content, "source_key=timeline_summary/agent:test:user:1:main/") != null);

    const anchor = (try mem.get(allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_session=agent:test:user:1:main") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=summary_seed:auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchor.content, "last_summary_key=timeline_summary/agent:test:user:1:main/") != null);
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

    const StageObserver = struct {
        const Self = @This();
        turn_start_count: u32 = 0,
        cache_hit_count: u32 = 0,
        complete_count: u32 = 0,

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
                    if (std.mem.eql(u8, stage.stage, "turn_start")) self.turn_start_count += 1;
                    if (std.mem.eql(u8, stage.stage, "response_cache_hit")) self.cache_hit_count += 1;
                },
                .turn_complete => self.complete_count += 1,
                else => {},
            }
        }

        fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
        fn flush(_: *anyopaque) void {}
        fn name(_: *anyopaque) []const u8 {
            return "semantic-cache-stage-observer";
        }
    };

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
        .conversation_retention_days = 0,
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
    try std.testing.expectEqual(@as(u32, 1), stage_observer.turn_start_count);
    try std.testing.expectEqual(@as(u32, 1), stage_observer.complete_count);
    try std.testing.expectEqual(@as(u32, 0), stage_observer.cache_hit_count);

    const sem_stats_after_first = try sem_cache.stats();
    try std.testing.expect(sem_stats_after_first.count >= 1);

    const second = try agent.turn("semantic cache probe");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("provider-answer", second);
    try std.testing.expectEqual(@as(u32, 1), provider_state.calls);
    try std.testing.expectEqual(@as(u32, 2), stage_observer.turn_start_count);
    try std.testing.expectEqual(@as(u32, 2), stage_observer.complete_count);
    try std.testing.expectEqual(@as(u32, 1), stage_observer.cache_hit_count);

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

test "policy preflight reports action budget exhausted" {
    const allocator = std.testing.allocator;
    var tracker = RateTracker.init(allocator, 1);
    defer tracker.deinit();
    var policy = SecurityPolicy{
        .autonomy = .full,
        .workspace_dir = "/tmp",
        .max_actions_per_hour = 1,
        .tracker = &tracker,
    };

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
        .max_tool_iterations = 1,
        .max_history_messages = 4,
        .auto_save = false,
        .history = .empty,
        .policy = &policy,
    };
    defer agent.deinit();

    const call = ParsedToolCall{
        .name = "runtime_info",
        .arguments_json = "{}",
        .tool_call_id = null,
    };

    const first = agent.preflightToolPolicy(call);
    try std.testing.expect(first == .allowed);

    const second = agent.preflightToolPolicy(call);
    try std.testing.expect(second == .blocked);
    try std.testing.expectEqualStrings("Action budget exhausted", second.blocked.output);
}

test "preflight allows read-only tools in plan mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;
    const read_only_tools = [_][]const u8{
        "runtime_info", "file_read", "memory_recall", "memory_list",
        "memory_timeline", "web_fetch", "web_search", "task_list", "task_get",
    };
    for (read_only_tools) |name| {
        const call = ParsedToolCall{ .name = name, .arguments_json = "{}", .tool_call_id = null };
        const result = agent.preflightToolPolicy(call);
        try std.testing.expect(result == .allowed);
    }
}

test "preflight blocks mutating tools in plan mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;
    // Tools with no action-dependent downgrade; empty args stay mutating.
    // (Action-dependent tools are covered by the "still blocks mutating
    // sub-actions" test — they need concrete args to remain mutating.)
    const mutating_tools = [_][]const u8{
        "shell",        "file_write", "file_edit", "memory_store",
        "delegate",     "spawn",      "message",
    };
    for (mutating_tools) |name| {
        const call = ParsedToolCall{ .name = name, .arguments_json = "{}", .tool_call_id = null };
        const result = agent.preflightToolPolicy(call);
        try std.testing.expect(result == .blocked);
        try std.testing.expect(std.mem.indexOf(u8, result.blocked.output, "plan mode") != null);
    }
}

test "preflight blocks mutating tools in review mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .review;
    const call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    try std.testing.expect(std.mem.indexOf(u8, result.blocked.output, "review mode") != null);
}

test "preflight allows read-only tools in review mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .review;
    const call = ParsedToolCall{ .name = "file_read", .arguments_json = "{}", .tool_call_id = null };
    try std.testing.expect(agent.preflightToolPolicy(call) == .allowed);
}

test "preflight blocks unknown tools in plan mode via conservative fallback" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;
    const call = ParsedToolCall{
        .name = "mcp_unknown_tool",
        .arguments_json = "{}",
        .tool_call_id = null,
    };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
}

test "preflight permits unknown tools in execute mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .execute;
    const call = ParsedToolCall{
        .name = "mcp_unknown_tool",
        .arguments_json = "{}",
        .tool_call_id = null,
    };
    try std.testing.expect(agent.preflightToolPolicy(call) == .allowed);
}

test "preflight allows read-only sub-actions of mutating tools in plan mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;

    const cases = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "schedule", .args = "{\"action\":\"list\"}" },
        .{ .name = "schedule", .args = "{\"action\":\"get\",\"id\":\"abc\"}" },
        .{ .name = "git_operations", .args = "{\"operation\":\"status\"}" },
        .{ .name = "git_operations", .args = "{\"operation\":\"diff\"}" },
        .{ .name = "http_request", .args = "{\"url\":\"https://x\",\"method\":\"GET\"}" },
        .{ .name = "http_request", .args = "{\"url\":\"https://x\"}" },
        .{ .name = "composio", .args = "{\"action\":\"list\",\"app\":\"gmail\"}" },
        .{ .name = "composio", .args = "{\"action\":\"execute\",\"tool_slug\":\"gmail-list-messages\"}" },
        .{ .name = "skill_registry", .args = "{\"action\":\"list\"}" },
    };
    for (cases) |c| {
        const call = ParsedToolCall{ .name = c.name, .arguments_json = c.args, .tool_call_id = null };
        const result = agent.preflightToolPolicy(call);
        try std.testing.expect(result == .allowed);
    }
}

test "preflight still blocks mutating sub-actions in plan mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;

    const cases = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "schedule", .args = "{\"action\":\"create\",\"expression\":\"*/5 * * * *\",\"command\":\"echo\"}" },
        .{ .name = "git_operations", .args = "{\"operation\":\"commit\",\"message\":\"x\"}" },
        .{ .name = "http_request", .args = "{\"url\":\"https://x\",\"method\":\"POST\"}" },
        .{ .name = "composio", .args = "{\"action\":\"execute\",\"tool_slug\":\"gmail-send-email\"}" },
        .{ .name = "skill_registry", .args = "{\"action\":\"install\",\"skill_ref\":\"x/y\"}" },
    };
    for (cases) |c| {
        const call = ParsedToolCall{ .name = c.name, .arguments_json = c.args, .tool_call_id = null };
        const result = agent.preflightToolPolicy(call);
        try std.testing.expect(result == .blocked);
    }
}

test "preflight background mode allows background-safe tools and blocks others" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .background;

    const safe_call = ParsedToolCall{ .name = "file_read", .arguments_json = "{}", .tool_call_id = null };
    try std.testing.expect(agent.preflightToolPolicy(safe_call) == .allowed);

    const unsafe_call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    const blocked = agent.preflightToolPolicy(unsafe_call);
    try std.testing.expect(blocked == .blocked);
    try std.testing.expect(std.mem.indexOf(u8, blocked.blocked.output, "background mode") != null);

    // Sensitive non-background tools remain blocked.
    const schedule_call = ParsedToolCall{ .name = "schedule", .arguments_json = "{}", .tool_call_id = null };
    try std.testing.expect(agent.preflightToolPolicy(schedule_call) == .blocked);
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

test "turn retries once when provider reliability is inactive" {
    const FlakyProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
            if (self.call_count == 1) return error.TemporaryFailure;
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
            return "flaky-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;

    var provider_state = FlakyProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = FlakyProvider.chatWithSystem,
        .chat = FlakyProvider.chat,
        .supportsNativeTools = FlakyProvider.supportsNativeTools,
        .getName = FlakyProvider.getName,
        .deinit = FlakyProvider.deinitFn,
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
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const response = try agent.turn("hello");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("ok", response);
    try std.testing.expectEqual(@as(usize, 2), provider_state.call_count);
}

test "turn skips duplicate agent retry when provider reliability is active" {
    const FlakyProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
            return error.TemporaryFailure;
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "flaky-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;

    var provider_state = FlakyProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = FlakyProvider.chatWithSystem,
        .chat = FlakyProvider.chat,
        .supportsNativeTools = FlakyProvider.supportsNativeTools,
        .getName = FlakyProvider.getName,
        .deinit = FlakyProvider.deinitFn,
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
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .provider_reliability_active = true,
        .history = .empty,
    };
    defer agent.deinit();

    try std.testing.expectError(error.TemporaryFailure, agent.turn("hello"));
    try std.testing.expectEqual(@as(usize, 1), provider_state.call_count);
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

// ═══════════════════════════════════════════════════════════════════════════
// Baseline characterization tests (Phase 0 — SOTA program safety net)
// ═══════════════════════════════════════════════════════════════════════════

test "baseline: DEFAULT_MAX_TOOL_ITERATIONS is 25" {
    try std.testing.expectEqual(@as(u32, 25), DEFAULT_MAX_TOOL_ITERATIONS);
}

test "baseline: DEFAULT_MAX_HISTORY is 50" {
    try std.testing.expectEqual(@as(u32, 50), DEFAULT_MAX_HISTORY);
}

test "baseline: Agent struct has required execution control fields" {
    // Verify the Agent struct contains the fields that the execution-mode
    // and approval-modes sprints will extend. If these fields are renamed
    // or removed, the SOTA program needs to know immediately.
    // Use @hasField instead of runtime iteration (comptime-safe in Zig 0.15).
    try std.testing.expect(@hasField(Agent, "max_tool_iterations"));
    try std.testing.expect(@hasField(Agent, "max_history_messages"));
    try std.testing.expect(@hasField(Agent, "parallel_tools"));
    try std.testing.expect(@hasField(Agent, "model_name"));
    try std.testing.expect(@hasField(Agent, "observer"));
    try std.testing.expect(@hasField(Agent, "cancellation_token"));
}

test "baseline: context_tokens resolves known model windows" {
    // Snapshot key model context windows so any model table change is visible.
    const ct = @import("context_tokens.zig");
    try std.testing.expectEqual(@as(?u64, 200_000), ct.lookupContextTokens("claude-sonnet-4.6"));
    try std.testing.expectEqual(@as(?u64, 128_000), ct.lookupContextTokens("openai/gpt-4.1-mini"));
}

test "baseline: Agent deinit on minimal instance does not leak" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "baseline-test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = DEFAULT_MAX_TOOL_ITERATIONS,
        .max_history_messages = DEFAULT_MAX_HISTORY,
        .auto_save = false,
    };
    defer agent.deinit();

    // Verify defaults are applied correctly.
    try std.testing.expectEqual(@as(u32, 25), agent.max_tool_iterations);
    try std.testing.expectEqual(@as(u32, 50), agent.max_history_messages);
}

test "ttsAudioChannelSupported returns true for discord via voice_mode" {
    // Proves the hardcoded telegram-only check has been replaced with
    // voice_mode.channelSupportsAudio which supports multiple channels.
    try std.testing.expect(voice_mode.channelSupportsAudio("discord"));
    try std.testing.expect(voice_mode.channelSupportsAudio("telegram"));
    try std.testing.expect(voice_mode.channelSupportsAudio("whatsapp"));
}

test "ttsAudioChannelSupported returns false for cli via voice_mode" {
    try std.testing.expect(!voice_mode.channelSupportsAudio("cli"));
    try std.testing.expect(!voice_mode.channelSupportsAudio("unknown"));
}
