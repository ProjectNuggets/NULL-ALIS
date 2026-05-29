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
const result_cache_mod = @import("../tools/result_cache.zig");
const entitlement_mod = @import("../entitlement.zig");
const memory_mod = @import("../memory/root.zig");
const zaki_state_mod = @import("../zaki_state.zig");
const Memory = memory_mod.Memory;
const capabilities_mod = @import("../capabilities.zig");
const multimodal = @import("../multimodal.zig");
const platform = @import("../platform.zig");
const voice_mod = @import("../voice.zig");
const voice_mode = @import("../voice_mode.zig");
const observability = @import("../observability.zig");
const tool_dispatcher = @import("../tool_mode.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const SecurityPolicy = @import("../security/policy.zig").SecurityPolicy;
const RateTracker = @import("../security/policy.zig").RateTracker;
const approval_modes_mod = @import("../security/approval_modes.zig");
const ApprovalPolicy = approval_modes_mod.ApprovalPolicy;
const AutonomyLevel = @import("../security/policy.zig").AutonomyLevel;
const hooks_mod = @import("../hooks.zig");
const execution_mode_mod = @import("execution_mode.zig");
const ExecutionMode = execution_mode_mod.ExecutionMode;
const tool_metadata = @import("../tools/metadata.zig");
const abort_mod = @import("abort.zig");
const CancellationToken = abort_mod.CancellationToken;
const goal_loop = @import("goal_loop.zig");
pub const reflection = @import("reflection.zig");

const cache = memory_mod.cache;
pub const abort = @import("abort.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const compaction = @import("compaction.zig");
// W1.2: context_builder is now an internal stage of context_engine.
// External consumers should use `agent.context_engine.builder`.
// Kept as a private const here for internal agent/root.zig callers.
const context_builder = @import("context_builder.zig");
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
// W1.2: memory_loader is now an internal stage of context_engine.
// External consumers should use `agent.context_engine.memory_loader`.
// Kept as a private const here for internal agent/root.zig callers.
const memory_loader = @import("memory_loader.zig");
pub const transcript = @import("transcript.zig");
pub const commands = @import("commands.zig");
/// V1.12 — wiki-link entity pipeline. Per-3-turn LLM extraction of entity
/// mentions, cosine-resolution against memory_entities, COOCCURS edge
/// emission. Multilingual by construction. See entity_pipeline.zig for
/// the design contract.
pub const entity_pipeline = @import("entity_pipeline.zig");
/// V1.13 Day 1 — Working Memory layer (Layer 0). 15 hot slots per
/// session that persist across turns and render into the volatile
/// prompt block. See agent/working_memory.zig.
pub const working_memory = @import("working_memory.zig");
/// V1.13 Day 4 — Procedural memory (Layer 6). Captures skill execution
/// traces for recall on next invocation. Schema lives in
/// zaki_state.skill_executions; Day 4.2 adds render + capture.
pub const procedural_memory = @import("procedural_memory.zig");
/// v1.14.18-B G16 (WM-CROSS-SESSION) — session-end promotion of
/// high-importance working-memory slots to durable_facts. See
/// agent/promotion.zig.
pub const promotion = @import("promotion.zig");
/// V1.13 Day 5 — Dream state (Layer 7). 3 AM cron-driven idle-time
/// consolidation: brain hygiene, importance recompute, dream_log
/// reflection. Pattern extraction + narrative synthesis (LLM steps)
/// deferred to Day 5.2.
pub const dream = @import("dream.zig");
const ParsedToolCall = dispatcher.ParsedToolCall;
const ToolExecutionResult = dispatcher.ToolExecutionResult;

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum agentic tool-use iterations per user message.
const DEFAULT_MAX_TOOL_ITERATIONS: u32 = 25;

/// Maximum non-system messages before trimming.
const DEFAULT_MAX_HISTORY: u32 = 50;

/// Anti-thrash guard: if BOTH entries in compaction_savings_ring are under
/// this percentage, Agent.autoCompactHistory skips the next attempt. Protects
/// against repeated LLM summary calls on a tightly-packed session saving little.
const COMPACTION_MIN_SAVINGS_PERCENT: u8 = 10;

// ═══════════════════════════════════════════════════════════════════════════
// Agent
// ═══════════════════════════════════════════════════════════════════════════

pub const Agent = struct {
    const StreamEmissionMode = enum {
        undecided,
        pass_through,
        hold_for_validation,
    };

    const StreamTimingContext = struct {
        agent: *Agent,
        callback: providers.StreamCallback,
        callback_ctx: *anyopaque,
        iteration: u32,
        provider_start_ms: i64,
        first_token_recorded: bool = false,
        first_token_ms: ?u64 = null,
        emission_mode: StreamEmissionMode = .undecided,
        buffered_text: std.ArrayListUnmanaged(u8) = .empty,
        final_pending: bool = false,
        /// D53 third defense layer (2026-05-24): in `.pass_through` mode the
        /// chunk-by-chunk emit can leak `<tool_call>` markup that the model
        /// emits AFTER legitimate prose (so the streamer already committed to
        /// pass_through on the firstNonEmptyLine check). Markup can also be
        /// split across two chunks ("...some text<too" + "l_call>{...}").
        /// We hold a short trailing buffer of up-to-`pending_tail_max` bytes
        /// across chunks so a split prefix can be reassembled on the next
        /// chunk and stripped. Emitted to the user-facing callback in
        /// `emitScrubbedDelta` only after the next chunk arrives (or on the
        /// final chunk via `flushPendingTail`).
        pending_tail: std.ArrayListUnmanaged(u8) = .empty,

        /// Longest markup sentinel we scan for. `</tool_call>` is 12 bytes;
        /// hold up to that minus one so we never block a fully-formed
        /// sentinel from being detected.
        const pending_tail_max: usize = 11;

        fn deinit(self: *StreamTimingContext) void {
            self.buffered_text.deinit(self.agent.allocator);
            self.pending_tail.deinit(self.agent.allocator);
        }

        fn flushBuffered(self: *StreamTimingContext) void {
            if (self.buffered_text.items.len > 0) {
                // D53 second-layer scrub (2026-05-24): the `.undecided` →
                // `.pass_through` transition fires when firstNonEmptyLine
                // looks clean, but `buffered_text` may already contain mid-
                // stream markup ("Got it.\n<tool_call>{...}"). Strip before
                // emitting; otherwise the entire accumulated buffer leaks
                // raw on transition.
                const scrubbed = Agent.stripToolCallMarkup(self.agent.allocator, self.buffered_text.items);
                defer if (scrubbed.ptr != self.buffered_text.items.ptr) self.agent.allocator.free(scrubbed);
                if (scrubbed.len > 0) {
                    self.callback(self.callback_ctx, providers.StreamChunk.textDelta(scrubbed));
                }
                self.buffered_text.clearRetainingCapacity();
            }
            if (self.final_pending) {
                self.callback(self.callback_ctx, providers.StreamChunk.finalChunk());
                self.final_pending = false;
            }
            self.emission_mode = .pass_through;
        }

        fn flushValidatedReply(self: *StreamTimingContext, reply_text: []const u8) void {
            if (self.emission_mode == .pass_through) return;
            self.buffered_text.clearRetainingCapacity();
            if (reply_text.len > 0) {
                // D53 (2026-05-24): reply_text comes from already-scrubbed
                // display_text (see agent/root.zig:4129) so it should be
                // clean; the strip here is defense-in-depth for any future
                // caller that forgets the upstream scrub.
                const scrubbed = Agent.stripToolCallMarkup(self.agent.allocator, reply_text);
                defer if (scrubbed.ptr != reply_text.ptr) self.agent.allocator.free(scrubbed);
                self.callback(self.callback_ctx, providers.StreamChunk.textDelta(scrubbed));
            }
            self.callback(self.callback_ctx, providers.StreamChunk.finalChunk());
            self.final_pending = false;
            self.emission_mode = .pass_through;
        }

        fn recordBufferedDelta(self: *StreamTimingContext, delta: []const u8) bool {
            self.buffered_text.appendSlice(self.agent.allocator, delta) catch return false;
            return true;
        }

        /// D53 third defense layer (2026-05-24): emit a chunk that came in
        /// during `.pass_through` mode, with streaming-aware markup scrub.
        ///
        /// Two concerns:
        ///   1. Complete markup wholly within the chunk → strip via
        ///      `stripToolCallMarkup`.
        ///   2. Markup split across two chunks (e.g. chunk N ends with
        ///      "...<too", chunk N+1 starts with "l_call>{") → hold the
        ///      trailing bytes that could be a markup-prefix and reassemble
        ///      on the next chunk.
        ///
        /// `is_final == true` on the chunk means we should also flush the
        /// held tail (whatever it is, the stream is ending, so any held
        /// bytes are real content, not a future-markup prefix).
        fn emitScrubbedDelta(self: *StreamTimingContext, chunk: providers.StreamChunk) void {
            // Combine any held tail with the new delta so split markup
            // reassembles correctly.
            const allocator = self.agent.allocator;
            var combined: std.ArrayListUnmanaged(u8) = .empty;
            defer combined.deinit(allocator);
            combined.appendSlice(allocator, self.pending_tail.items) catch {
                // OOM — fall back to direct forward of the new delta (drop
                // the held tail, accept the rare leak rather than fail the
                // turn). Reset state so we don't double-emit later.
                self.pending_tail.clearRetainingCapacity();
                self.callback(self.callback_ctx, chunk);
                return;
            };
            combined.appendSlice(allocator, chunk.delta) catch {
                self.pending_tail.clearRetainingCapacity();
                self.callback(self.callback_ctx, chunk);
                return;
            };
            self.pending_tail.clearRetainingCapacity();

            // Strip complete markup blocks.
            const scrubbed = Agent.stripToolCallMarkup(allocator, combined.items);
            defer if (scrubbed.ptr != combined.items.ptr) allocator.free(scrubbed);

            // Figure out how many trailing bytes look like a markup prefix
            // we should hold (only when more chunks may follow).
            const hold_len: usize = if (chunk.is_final) 0 else Agent.trailingMarkupPrefixLen(scrubbed);
            const emit_len = scrubbed.len - hold_len;
            if (emit_len > 0) {
                self.callback(self.callback_ctx, providers.StreamChunk.textDelta(scrubbed[0..emit_len]));
            }
            if (hold_len > 0) {
                self.pending_tail.appendSlice(allocator, scrubbed[emit_len..]) catch {
                    // Same OOM fallback: emit the rest directly.
                    self.callback(self.callback_ctx, providers.StreamChunk.textDelta(scrubbed[emit_len..]));
                };
            }
            if (chunk.is_final) {
                self.callback(self.callback_ctx, providers.StreamChunk.finalChunk());
            }
        }

        /// Called when the stream ends without a chunk.is_final having
        /// been routed through `emitScrubbedDelta` (defensive — both paths
        /// would otherwise lose the held tail).
        fn flushPendingTail(self: *StreamTimingContext) void {
            if (self.pending_tail.items.len > 0) {
                self.callback(self.callback_ctx, providers.StreamChunk.textDelta(self.pending_tail.items));
                self.pending_tail.clearRetainingCapacity();
            }
        }
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
                .run_id = ctx.agent.current_run_id,
            } };
            ctx.agent.observer.recordEvent(&first_token_event);
        }
        if (ctx.emission_mode == .pass_through) {
            // D53 third defense layer (2026-05-24): route every pass_through
            // chunk through `emitScrubbedDelta` so mid-stream `<tool_call>`
            // markup the streamer already committed to flowing through gets
            // stripped before reaching the user's SSE stream. Handles two
            // leak shapes: complete markup inside one chunk (stripped
            // inline), and markup split across two chunks (held + joined
            // on next call). Final chunk flushes any held tail.
            ctx.emitScrubbedDelta(chunk);
            return;
        }
        if (chunk.is_final) {
            ctx.final_pending = true;
            return;
        }
        if (chunk.delta.len == 0) return;
        if (!ctx.recordBufferedDelta(chunk.delta)) {
            ctx.flushBuffered();
            ctx.callback(ctx.callback_ctx, chunk);
            return;
        }

        const buffered_line = Agent.firstNonEmptyLine(ctx.buffered_text.items) orelse return;
        if (Agent.looksLikeStreamingStatusPrefix(buffered_line) or
            Agent.looksLikeToolCallMarkupPrefix(buffered_line))
        {
            ctx.emission_mode = .hold_for_validation;
            return;
        }

        ctx.flushBuffered();
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
    /// V1.6 commit 5b.3 — extraction wiring. When both are set, Pass C
    /// of compaction parses its JSON tail and persists atomic facts
    /// via extraction_persist.persistExtracted. Populated at agent
    /// init from the gateway's tenant runtime (state.zaki_state +
    /// numeric user_id from tenant_ctx). When null/0, extraction is
    /// disabled and CompactionConfig stays V1.5-equivalent.
    extraction_state_mgr: ?*zaki_state_mod.Manager = null,
    /// 5b-loose-ends-sweep — was sentinel `i64 = 0`; replaced with optional
    /// to avoid magic-value brittleness per IN-4.
    extraction_user_id: ?i64 = null,
    /// V1.6 commit 8 — embedding provider for entity coreference. When set,
    /// extraction_persist resolves object strings via memory_entities
    /// cosine ≥0.95 (Mem0 threshold). Without it, falls back to
    /// hash-based entity_<sha256(lower(object))> from V1.6 cmt7.
    extraction_coref_embed: ?@import("../memory/vector/embeddings.zig").EmbeddingProvider = null,
    /// V1.9-6 — LLM provider + model for the contradiction judge on the
    /// session-end summarizer path. V1.8-1 wired the judge for
    /// memory_store + Pass C; this closes the third callsite (commands.zig
    /// session-end summarizer → durable_fact/* writes routed through
    /// extraction_persist.persistExtracted). When set, contradictions are
    /// applied + dedup'd against existing memory state. Without it, the
    /// legacy V1.7-cmt9.6 behavior runs (judge_ctx=null at the call site;
    /// MD5 dedup only, no semantic contradiction detection).
    extraction_judge_provider: ?providers.Provider = null,
    extraction_judge_model_name: []const u8 = "",
    // V1.14.12 (Path A) — extraction_legacy_direct_writes field removed.
    /// V1.14.12 (M2 review CRITICAL) — cardinality fast-path gate
    /// threaded through to JudgeContext so persistExtracted honors
    /// the operator-set value. Default true preserves M2 behavior.
    extraction_cardinality_fastpath: bool = true,
    /// V1.14.7 — extraction trigger gates (per-turn enqueue, memory nudge,
    /// skills nudge). Defaults preserve V1.14.6 behavior. C2 wires structured
    /// extraction into compaction; C3 flips defaults to disabled and deletes
    /// the per-turn sites. See config_types.ExtractionConfig docs for the
    /// migration rationale (per-turn extraction is unique to nullalis among
    /// reference agents — Claude Code / Hermes / Mem0 / Letta extract at
    /// natural distillation moments only).
    extraction_cfg: config_types.ExtractionConfig = .{},
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
    /// Vision-capable fallback model wired from reliability.vision_fallback.
    /// When the current turn contains image content and the default model
    /// doesn't support vision, the turn swaps to this model. Empty =
    /// fallback disabled (current-regression behavior: images silently
    /// dropped by text-only models).
    vision_fallback_model: []const u8 = "",
    /// Opt-in gate for the provider Files-API video upload arc.
    /// Default `false` until the live Moonshot endpoint contract is
    /// smoke-probed end-to-end (see WARN-4 in v1.14.23 review). When
    /// false, over-inline-cap videos fall back to the text-note path
    /// even when an uploader is wired. Plumbed through to
    /// `MultimodalConfig.experimental_video_upload`.
    experimental_video_upload: bool = false,
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
    /// V1.11 (2026-05-07): aligned struct default false → true to match
    /// `config_types.AgentConfig.parallel_tools` (default true). The mismatch
    /// was latent — `fromConfig` always overlays the config value, so
    /// production resolution was correct — but any direct Agent construction
    /// (tests, CLI shortcuts, edge cases) silently got serial dispatch.
    /// Aligning here eliminates the discrepancy ZAKI surfaced during his
    /// V1.11 self-audit. Production behavior unchanged; latent bug closed.
    parallel_tools: bool = true,
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
    last_executed_tool: []const u8 = "",
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
    /// Generic pending tool approval (WP1.4). Only one may exist at a time in v1.
    /// All slices are owned — never borrow from model-response memory.
    pending_tool_approval: ?PendingToolApproval = null,
    pending_tool_approval_id_counter: u64 = 0,
    /// Monotonically increasing run counter incremented at the start of every
    /// `turn()` to mint a stable run ID for client event correlation (WP1.3).
    run_id_counter: u64 = 0,
    /// Stack-backed buffer holding the active turn's run ID. Lifetime is
    /// scoped to a single `turn()` call — `current_run_id` is set on entry
    /// and cleared on exit.
    current_run_id_buf: [40]u8 = undefined,
    /// Slice into `current_run_id_buf` valid only while a turn is executing.
    /// Null between turns. Read by event-emit sites to populate `run_id` on
    /// observer events without changing existing call signatures.
    current_run_id: ?[]const u8 = null,
    /// When true, `preflightToolPolicy` skips the generic approval gate.
    /// Set during `executeApprovedPendingTool` so a user-approved call does
    /// not re-trigger approval. Other gates (security, action budget,
    /// execution mode) still apply.
    approval_bypass_active: bool = false,
    /// When true (production default), resolving `/approve allow-once` runs
    /// the tool AND invokes a continuation turn so the LLM reasons about the
    /// tool result and produces the final user-facing reply. Fixes the
    /// "approval drops after click" bug (2026-04-18). Tests that do not
    /// provide a live provider may set this to false to preserve the legacy
    /// "return tool output as reply text" behavior.
    approval_continues_turn: bool = true,
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

    /// S5.7 — memoized Config load. Populated on first use by
    /// `cachedConfigForCaps()`. Config is effectively immutable during an
    /// Agent's lifetime (no hot-reload path exists), so reading config.json
    /// on every turn is pure waste — a 50-message burst today does 50 file
    /// reads + JSON parses. `cached_config_loaded` disambiguates "never
    /// attempted" from "attempted and failed" so a transient filesystem
    /// hiccup at first use doesn't re-spin the load every turn afterwards.
    ///
    /// **Invariant (MED-1 review fix):** once `cached_config_loaded` flips
    /// to true AND `cached_config` is non-null, neither field may be
    /// reassigned for the remaining lifetime of this Agent. `cachedConfig
    /// ForCaps` returns a `*const Config` into the optional payload inside
    /// this field — any reassignment would silently dangle that pointer on
    /// any caller that holds it. If a future hot-reload path is needed,
    /// land it as an explicit `invalidateConfigCache()` method that
    /// simultaneously clears all outstanding pointer users, not a bare
    /// field write.
    cached_config: ?Config = null,
    cached_config_loaded: bool = false,

    /// Whether compaction was performed during the last turn.
    last_turn_compacted: bool = false,

    /// V1.14.10 A — in-flight guard for async lifecycle summarizer.
    /// True while a background lifecycle thread is running. Hot-path
    /// callers (compaction:auto, summary_seed:auto) skip enqueuing
    /// when already in-flight — the next legitimate trigger picks
    /// up whatever the in-flight one missed. Atomic so the spawned
    /// thread can clear it safely from a non-agent thread.
    lifecycle_in_flight: std.atomic.Value(bool) = .{ .raw = false },
    /// Join handle for the lifecycle worker. The worker still clears
    /// `lifecycle_in_flight`; the owning Agent joins the handle before
    /// teardown so the worker cannot outlive Agent-owned memory.
    lifecycle_thread_mu: std.Thread.Mutex = .{},
    lifecycle_thread: ?std.Thread = null,

    /// Whether context was force-compacted due to exhaustion during the current turn.
    context_was_compacted: bool = false,

    /// True when force-compression (hard-drop, no LLM summary) was used. Distinguished
    /// from graceful LLM compaction so we can show a stronger user-facing notice.
    context_force_compressed: bool = false,

    /// Turns since last memory nudge (periodic prompt asking agent what to persist).
    turns_since_memory_nudge: u32 = 0,
    /// V1.12 — turns since last entity-pipeline (wiki_link) run. Auto-fires
    /// every 3 turns to extract entity mentions from the recent turn pair(s)
    /// and emit COOCCURS edges. Multilingual by construction. See
    /// agent/entity_pipeline.zig for the design contract.
    turns_since_extraction: u32 = 0,
    /// Tool calls in the last completed turn (for skills auto-extraction).
    last_turn_tool_count: u32 = 0,
    /// v1.14.18-A F3 — session-wide tool count for procedural-memory capture gate.
    /// Accumulates across ALL turns of a session; read + reset at session-end.
    /// Replaces the last_turn-only signal that left skill_executions empty.
    session_total_tool_count: u32 = 0,
    /// v1.14.18-A F3 — session-wide tool-name manifest for the capture trace.
    session_tool_names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// v1.14.18-A F3 — per-turn goal state for ReAct reflection loop.
    active_goal_state: ?goal_loop.GoalState = null,
    /// Last completed turn goal-loop verdict, retained after active_goal_state
    /// is cleared so session-end procedural capture can score the outcome.
    session_last_goal_status: ?goal_loop.GoalStatus = null,
    /// v1.14.18-B G5 — serialized reflection trail JSON for cross-session learning.
    /// Serialized at turn-end from active_reflection_trail; passed to procedural_memory.captureSession.
    session_reflection_trail_json: ?[]const u8 = null,

    /// v1.14.18-A G4 (TASK-PLANNER READ-BACK) — the agent's most-recent
    /// task plan. Promoted from a turnOutcome loop-local to an Agent field
    /// so `context_engine.assemble` can render it as a `<task_plan>`
    /// volatile-prompt block (plan + live step progress carried back into
    /// the next turn's prompt). Persist-until-replaced: a new `<task_plan>`
    /// in a later turn deinits this and stores the new one; freed at
    /// Agent.deinit. Null until the agent first emits a plan.
    active_task_plan: ?task_planner.TaskPlan = null,

    /// v1.14.18-B G3 (NARRATION-AS-CONTEXT) — agent-owned ring buffer
    /// of recent narration frames. The per-turn `NarrationObserver`
    /// (built fresh in `turnOutcome`) holds a pointer back so emitted
    /// frames flow into recall. Surfaces as `<recent_thoughts>` in the
    /// volatile prompt via `context_engine.assemble`. Size cap is
    /// `narration.RING_BUFFER_CAPACITY` (16); FIFO eviction.
    ///
    /// **Initialization invariant:** the inner `allocator` field MUST be
    /// re-bound to `self.allocator` before the agent runs its first turn.
    /// `fromConfig` performs that re-bind. Direct-construction call sites
    /// (tests) should call `initNarrationRingBuffer(self.allocator)` after
    /// the Agent struct is fully wired but BEFORE any turn fires. The
    /// default below uses a sentinel `failing_allocator` so any missed
    /// initialization surfaces loudly — `push` logs a warn ("did you
    /// forget to call NarrationRingBuffer.init?") on every dupe failure,
    /// which fires for every frame against the sentinel. See
    /// `narration.NarrationRingBuffer.push` for the loud-failure rationale.
    narration_ring_buffer: narration.NarrationRingBuffer = .{ .allocator = std.testing.failing_allocator },
    /// v1.14.18-B G3 — current tool iteration the agent is preparing
    /// for. Stamped onto each pushed narration frame so the
    /// `<recent_thoughts>` block carries historical iteration numbers,
    /// not the current one. Bumped by `turnOutcome` between iterations.
    ///
    /// **Session-monotonic:** NOT reset per turn. Turn 2 may start at
    /// iter=17 (resuming from turn 1's final iteration count + 1).
    /// `<recent_thoughts iteration="N">` therefore displays session-wide
    /// counts. The `+%=` bump on `u32` is wrapping (per Zig semantics);
    /// at one iteration per ReAct step this wraps after ~4 billion
    /// iterations, so wrap is not a practical concern.
    iteration_counter: u32 = 0,

    /// **D1.8** — count of `durable_fact/behavior/*` entries this session
    /// has stored. Replaces the prior pattern (`mem.list` + filter scan
    /// on EVERY user message that tripped a learning signal — O(N) over
    /// all session memories per signal-bearing turn). Lazy-initialized
    /// on first check via a one-time `mem.list` scan; incremented on
    /// successful `mem.store(durable_fact/behavior/*)`. Bounds-checked
    /// against `learning.MAX_FACTS_PER_SESSION`. `null` means "not yet
    /// initialized this session" — first turn that needs the count
    /// pays the one-time O(N) cost; subsequent turns are O(1).
    learning_fact_count: ?u32 = null,

    /// Per-turn context lifecycle engine — stateless between turns.
    context_engine_state: context_engine.ContextEngine = .{},

    /// Compact explanation of what context was assembled on the last completed turn.
    last_turn_context: context_builder.LastTurnContext = .{},

    /// Raw user content for the current turn (context v2: memory is not
    /// substituted; raw is what goes to the provider).
    current_turn_raw_user: ?[]const u8 = null,

    /// Anti-thrash ring (iter20): last two compaction savings percentages.
    /// If both below COMPACTION_MIN_SAVINGS_PERCENT, autoCompactHistory skips
    /// its next attempt. Force-compress path bypasses this guard.
    compaction_savings_ring: [2]u8 = .{ 100, 100 },

    /// An owned copy of a ChatMessage, where content is heap-allocated.
    pub const OwnedMessage = struct {
        role: providers.Role,
        content: []const u8,
        /// Optional reasoning trace for an assistant turn. Captured from
        /// the model's `reasoning_content` (Kimi native CoT) and replayed
        /// to the provider so Moonshot's `thinking.keep:"all"` retains the
        /// model's cross-turn chain of thought. Allocator-owned when set;
        /// freed by `deinit`. Null for user/system/tool messages and for
        /// assistant turns where the model emitted no reasoning.
        reasoning: ?[]const u8 = null,

        pub fn deinit(self: *const OwnedMessage, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
            if (self.reasoning) |r| allocator.free(r);
        }

        fn toChatMessage(self: *const OwnedMessage) ChatMessage {
            return .{
                .role = self.role,
                .content = self.content,
                .reasoning_content = self.reasoning,
            };
        }
    };

    /// Result of a single agent turn. Returned by `turn()` to give
    /// callers (gateway, session manager, BFF, frontend) structured
    /// visibility into what happened, instead of just a bare reply
    /// string.
    ///
    /// **Why this struct exists (D1):** the historical `turn()` return
    /// was `![]const u8` — just the assistant text. Tool-only turns
    /// (where the model emits spawn/delegate calls but no post-tool
    /// assistant text) were invisible to the gateway, which then
    /// fabricated a literal `"received"` placeholder (`gateway.zig:9184`
    /// + `:10562`). Sprint 1's S1.10 (`963fc92`) replaced the literal
    /// with `EMPTY_TURN_PLACEHOLDER` as a min fix; this struct is the
    /// real fix, letting the gateway render structured tool-only-turn
    /// SSE frames (`spawned_task_ids`, `tool_calls_executed`) instead
    /// of any placeholder at all.
    ///
    /// **Ownership:** `text` is heap-allocated in the agent's
    /// allocator and transfers to the caller — caller must free via
    /// `deinit(allocator)` or by handing it to a consumer that frees.
    /// The `tool_calls_executed` and `spawned_task_ids` slices are
    /// also owned and freed by `deinit`. Use `justText` for the most
    /// common case (text-only reply); use `deinit` exactly once.
    pub const TurnOutcome = struct {
        /// The assistant text reply. Empty string for tool-only turns.
        /// Heap-allocated in the agent's allocator.
        text: []const u8,
        /// Convenience flag: true when the model produced tool/spawn
        /// calls but no post-tool text. Equivalent to
        /// `text.len == 0 and (tool_calls_executed.len > 0 or
        /// spawned_task_ids.len > 0)` but pre-computed so callers
        /// don't have to recompute.
        tool_only_turn: bool = false,
        /// Names of tools that executed this turn (in execution
        /// order). Empty slice means no tools fired. Each slice is
        /// owned and freed by `deinit`.
        tool_calls_executed: []const []const u8 = &.{},
        /// IDs of subagent tasks spawned this turn (via `spawn` or
        /// `delegate` tool). Empty slice means none. These tasks
        /// complete asynchronously; the bus delivers their results on
        /// separate SSE frames. Each slice is owned and freed by
        /// `deinit`.
        spawned_task_ids: []const []const u8 = &.{},
        /// Tool-loop iterations consumed this turn. Useful for
        /// observability dashboards distinguishing healthy 1-2-iter
        /// turns from near-exhaustion 24-iter turns.
        iterations_used: u32 = 0,
        /// True when the turn exited via the loop-detector early-out
        /// (same tool-call signature repeated past threshold). Lets
        /// the gateway show a different status badge than plain
        /// iteration-exhaustion.
        loop_detected: bool = false,

        /// Convenience constructor for the most common case: text-only
        /// reply with no tools and no spawns. The slice is taken as-is
        /// and the caller transfers ownership to the outcome.
        pub fn justText(text: []const u8) TurnOutcome {
            return .{ .text = text };
        }

        /// Free all owned memory. Caller must call this exactly once
        /// on the returned outcome. After this, every field's slice
        /// is invalid.
        pub fn deinit(self: *const TurnOutcome, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            for (self.tool_calls_executed) |name| allocator.free(name);
            allocator.free(self.tool_calls_executed);
            for (self.spawned_task_ids) |id| allocator.free(id);
            allocator.free(self.spawned_task_ids);
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

        // V1.11 self-verification log (2026-05-07): emit the actual runtime caps
        // applied to this agent so ZAKI (or any operator) can grep gateway.log
        // and confirm what's in effect. Surfaced after ZAKI reported hitting an
        // iteration cap of 10 — without this log there was no way to verify
        // whether the configured preset (balanced=200) was actually being
        // applied or if something was short-circuiting it.
        log.info("agent.fromConfig max_tool_iterations={d} max_history_messages={d} model={s} ctx_tokens={d} max_tokens={d} reasoning={s}", .{
            cfg.agent.max_tool_iterations,
            cfg.agent.max_history_messages,
            default_model,
            resolved_token_limit,
            resolved_max_tokens,
            cfg.reasoning_effort orelse "auto",
        });

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
            .vision_fallback_model = cfg.reliability.vision_fallback.model,
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
            .provider_reliability_active = cfg.reliability.provider_retries > 0 or
                cfg.reliability.fallback_providers.len > 0 or
                cfg.reliability.model_fallbacks.len > 0,
            .compaction_keep_recent = cfg.agent.compaction_keep_recent,
            .compaction_max_summary_chars = cfg.agent.compaction_max_summary_chars,
            .compaction_max_source_chars = cfg.agent.compaction_max_source_chars,
            .security_config = cfg.security,
            .extraction_cfg = cfg.agent.extraction,
            .history = .empty,
            .total_tokens = 0,
            .has_system_prompt = false,
            .last_turn_compacted = false,
            // v1.14.18-B G3 — bind the narration ring buffer to the agent's
            // allocator so push() dups land in the right arena and deinit
            // frees through the right path. Sentinel default
            // (`failing_allocator`) on the field declaration ensures any
            // construction path that forgets this re-bind surfaces loudly.
            .narration_ring_buffer = narration.NarrationRingBuffer.init(allocator),
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

    /// S5.7 — return a pointer into the memoized Config. First call loads
    /// from disk and caches; subsequent calls return the cached value (or
    /// null if the initial load failed, which we remember via
    /// `cached_config_loaded`). The pointer is valid until `deinit`.
    pub fn cachedConfigForCaps(self: *Agent) ?*const Config {
        if (!self.cached_config_loaded) {
            self.cached_config_loaded = true;
            if (Config.load(self.allocator)) |loaded| {
                self.cached_config = loaded;
            } else |err| {
                // First-load failure: leave cache empty but mark loaded so we
                // don't retry every turn. Operator can restart the agent to
                // force a reload.
                log.warn("config.load_failed_for_caps err={s} — caps will render without config context", .{@errorName(err)});
            }
        }
        return if (self.cached_config) |*cfg| cfg else null;
    }

    /// V1.14.10 A — Wait for any in-flight async lifecycle worker to
    /// complete. Bounded by `timeout_ms`. Returns true if drained,
    /// false if timed out.
    ///
    /// Used by Agent.deinit and session recycle paths so the lifecycle
    /// worker is joined before Agent-owned memory is released.
    /// Also exposed publicly so tests that assert on side-effects
    /// (memory writes) of the lifecycle path can wait deterministically
    /// before asserting.
    pub fn waitForLifecycleIdle(self: *Agent, timeout_ms: i64) bool {
        const wait_start_ms = std.time.milliTimestamp();
        while (self.lifecycle_in_flight.load(.acquire)) {
            const elapsed = std.time.milliTimestamp() - wait_start_ms;
            if (elapsed >= timeout_ms) return false;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        self.joinLifecycleThreadIfPresent();
        return true;
    }

    pub fn joinLifecycleThreadIfPresent(self: *Agent) void {
        var thread: ?std.Thread = null;
        self.lifecycle_thread_mu.lock();
        thread = self.lifecycle_thread;
        self.lifecycle_thread = null;
        self.lifecycle_thread_mu.unlock();
        if (thread) |t| t.join();
    }

    /// Default Agent.deinit waits in 30s chunks until lifecycle work
    /// drains. Shutdown may take longer under provider contention, but
    /// this path must not release memory while a worker still has a
    /// live Agent pointer.
    pub fn deinit(self: *Agent) void {
        while (!self.deinitWithTimeout(30_000)) {
            log.warn("Agent.deinit: lifecycle worker still active; waiting before teardown", .{});
        }
    }

    /// V1.14.10 A review fix (M-02 + H-02): deinit with a custom
    /// drain timeout. Returns `true` if the lifecycle worker drained
    /// cleanly within the budget; `false` if it timed out.
    ///
    /// On `false`, the function leaves Agent-owned memory intact and
    /// returns without tearing down. That can intentionally leak the
    /// old Agent object if the caller discards it anyway. Callers that
    /// pass a finite timeout must retain the Agent and retry later when
    /// this returns false.
    ///
    /// Hot-path callers (recycleSessionInPlace / TTL evict) should:
    ///   1. Call `deinitWithTimeout(5_000)` with a tight budget.
    ///   2. If returning `false`, SKIP whatever destructive next-step
    ///      they had planned (recycle, replace) — the worker may
    ///      still need the agent. Retry next loop iteration.
    pub fn deinitWithTimeout(self: *Agent, timeout_ms: i64) bool {
        const drained = self.waitForLifecycleIdle(timeout_ms);
        if (!drained) {
            log.warn("Agent.deinit: async lifecycle still in flight after {d}ms — skipping teardown to avoid dangling worker pointers", .{timeout_ms});
            return false;
        }

        self.clearCurrentTurnProviderOverride();
        if (self.cached_config) |*cfg| cfg.deinit();
        if (self.model_name_owned) self.allocator.free(self.model_name);
        if (self.default_provider_owned) self.allocator.free(self.default_provider);
        if (self.exec_node_id_owned and self.exec_node_id != null) self.allocator.free(self.exec_node_id.?);
        if (self.tts_provider_owned and self.tts_provider != null) self.allocator.free(self.tts_provider.?);
        if (self.pending_exec_command_owned and self.pending_exec_command != null) self.allocator.free(self.pending_exec_command.?);
        self.clearPendingToolApproval();
        if (self.focus_target_owned and self.focus_target != null) self.allocator.free(self.focus_target.?);
        if (self.dock_target_owned and self.dock_target != null) self.allocator.free(self.dock_target.?);
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.tool_specs);
        self.clearSessionToolNames();
        self.session_tool_names.deinit(self.allocator);
        // v1.14.18-B G3 — free recorded narration frames (dup'd messages
        // + tool names). Safe even on agents whose ring buffer never
        // received a push (len=0); the inner free-loop is a no-op then.
        self.narration_ring_buffer.deinit();
        // v1.14.18-B G5 fix — free the last turn's serialized reflection trail.
        if (self.session_reflection_trail_json) |j| self.allocator.free(j);
        // v1.14.18-A G4 — free the retained task plan (persist-until-replaced).
        if (self.active_task_plan) |*plan| plan.deinit(self.allocator);
        return drained;
    }

    /// Estimate total tokens in conversation history.
    pub fn tokenEstimate(self: *const Agent) u64 {
        return compaction.tokenEstimate(self.history.items);
    }

    /// Auto-compact history when it exceeds thresholds.
    /// Primary trigger: sliding-window (turn-count) — keeps last N user turns
    /// verbatim, collapses older into one summary block. Deterministic latency
    /// bound for stateless providers (Together/Groq) without prefix caching.
    /// Fallback: token-based triggers (70%/80%/90% in context v2) if window is 0.
    /// Uses sidecar provider for LLM summarization if available (cost savings:
    /// Groq Llama 8B instead of Sonnet/GLM/K2.5). Falls back to main provider.
    ///
    /// Anti-thrash guard (iter20): if the last two compactions each saved less
    /// than 10% of history size, skip this one and log `compaction.skipped
    /// reason=thrash_guard`. Protects against the pathological case where a
    /// tightly-packed session triggers expensive LLM summary calls every turn
    /// for diminishing returns. Force-compress (emergency path) bypasses this
    /// guard via `forceCompressHistory` which calls `compaction.*` directly.
    pub fn autoCompactHistory(self: *Agent) !bool {
        // Thrash guard
        if (self.compaction_savings_ring[0] < COMPACTION_MIN_SAVINGS_PERCENT and
            self.compaction_savings_ring[1] < COMPACTION_MIN_SAVINGS_PERCENT)
        {
            log.info("compaction.skipped reason=thrash_guard ring=[{d},{d}]", .{
                self.compaction_savings_ring[0],
                self.compaction_savings_ring[1],
            });
            return false;
        }

        const compact_provider = if (self.sidecar_provider) |sp| sp else self.provider;
        const compact_model = if (self.sidecar_provider != null) self.sidecar_model else self.model_name;
        // V1.14.9 review fix (H-01): single source of truth via
        // buildCompactionConfig. Both auto + manual paths share it.
        //
        // Reconciliation merge 2026-05-19 with main's `d6b3221e fix: wire
        // extraction judge into compaction`: that fix populated the same
        // two judge fields inline with a `compact_model` fallback when no
        // explicit extraction_judge_model_name was configured. The
        // refactor preserves both intents — buildCompactionConfig accepts
        // `compact_model` as the default-judge-model parameter, so the
        // judge runs by default using the compact model unless overridden.
        const cfg = self.buildCompactionConfig(compact_model);

        // iter22 (Nova's Medium finding): measure thrash savings in TOKENS,
        // not message count. Some compaction passes (Pass A cheap dedup,
        // tool-result truncation) shrink bytes WITHIN messages without
        // removing messages — counting messages would falsely flag these
        // as "no savings" and suppress useful future compactions. Token
        // pressure is what triggers compaction, so token pressure is what
        // we gate against when deciding to skip.
        const before_tokens = compaction.tokenEstimate(self.history.items);

        // iter23: turn-window trim deleted (12K-era leftover). Token-budget
        // autoCompactHistory is the single source of truth for when to compact.
        //
        // HI-04 fix (2026-05-07): the prior comment was wrong on TWO counts.
        // (1) The 50% `compaction_trigger` is an ADVISORY marker for the
        //     /context UI and the agent's "mind your length" hint; it does
        //     NOT fire compaction. Actual compaction fires inside
        //     autoCompactHistory at 70% (Pass A: cheap dedup) and 90%
        //     (Pass C: LLM summarization).
        // (2) Pass B was deleted in iter28 (commit 8136f8d) — only A and C
        //     remain. The "/B" reference was stale.
        const compacted = try compaction.autoCompactHistory(self.allocator, &self.history, compact_provider, compact_model, cfg);
        if (compacted) self.recordCompactionSavings(before_tokens, compaction.tokenEstimate(self.history.items));
        return compacted;
    }

    /// Update the 2-entry ring that the thrash guard reads next turn.
    /// Inputs are TOKEN estimates (not message counts). See comment in
    /// autoCompactHistory for rationale.
    fn recordCompactionSavings(self: *Agent, before_tokens: u64, after_tokens: u64) void {
        if (before_tokens == 0) return;
        const saved: u64 = if (before_tokens > after_tokens) (before_tokens - after_tokens) else 0;
        const pct: u8 = @intCast(@min(100, (saved * 100) / before_tokens));
        self.compaction_savings_ring[1] = self.compaction_savings_ring[0];
        self.compaction_savings_ring[0] = pct;
    }

    /// Manual compaction for explicit operator boundaries.
    pub fn manualCompactHistory(self: *Agent) !bool {
        const compact_provider = if (self.sidecar_provider) |sp| sp else self.provider;
        const compact_model = if (self.sidecar_provider != null) self.sidecar_model else self.model_name;
        // V1.14.9 review fix (H-01): operator-triggered /compact must also
        // benefit from the unified extractor wire (graph density, judge
        // contradiction resolution, working-memory promotion). Pre-fix this
        // path's literal CompactionConfig dropped every extraction field —
        // silently degrading manual compactions back to V1.5 behavior even
        // though autoCompactHistory worked correctly.
        //
        // 2026-05-19 reconcile-merge CORRECTION: pass `null` (not `compact_model`)
        // as default_judge_model here. Rationale: d6b3221e's intent was
        // specifically the AUTO compaction path. Extending the same fallback
        // to manual was an overreach that broke the canonical `/compact`
        // test — the test fixture doesn't wire `extraction_judge_provider`,
        // so populating `extraction_judge_model_name` with `compact_model`
        // makes the judge LOOK configured while `judge_provider` is null,
        // leading to a null-vtable segfault in `runExtractionCall`. Manual
        // /compact retains its prior degrade-gracefully behavior (judge off
        // unless explicitly configured by operator).
        return compaction.manualCompactHistory(
            self.allocator,
            &self.history,
            compact_provider,
            compact_model,
            self.buildCompactionConfig(null),
        );
    }

    /// V1.14.9 review fix (H-01): single source of truth for
    /// CompactionConfig construction. `autoCompactHistory` and
    /// `manualCompactHistory` both build their config via this helper, so
    /// the extraction-wire fields can't get out of sync between paths.
    /// `forceCompressHistory` deliberately does NOT use this — that path
    /// runs when the LLM is unavailable; extraction calls would just fail
    /// or pile up.
    ///
    /// `default_judge_model` is the fallback used when
    /// `self.extraction_judge_model_name` is empty. Per the 2026-05-19
    /// reconcile merge with main's `d6b3221e fix: wire extraction judge
    /// into compaction`, callers pass their `compact_model` so the
    /// judge runs by default using the compact model when no explicit
    /// extraction-judge model is configured. Pass `null` (or "") if the
    /// caller wants the Path A degrade-gracefully behavior (judge off
    /// when not configured).
    fn buildCompactionConfig(self: *Agent, default_judge_model: ?[]const u8) compaction.CompactionConfig {
        // Defensive coupling: a non-null judge_model_name with a null
        // judge_provider crashes `extraction/runner.zig:555` (null vtable
        // dereference). Only set the model name if the provider is also
        // present, regardless of what the caller asked for.
        const resolved_judge_model: ?[]const u8 = blk: {
            if (self.extraction_judge_provider == null) break :blk null;
            if (self.extraction_judge_model_name.len > 0) break :blk self.extraction_judge_model_name;
            if (default_judge_model) |dm| {
                if (dm.len > 0) break :blk dm;
            }
            break :blk null;
        };

        return compaction.CompactionConfig{
            .keep_recent = self.compaction_keep_recent,
            .max_summary_chars = self.compaction_max_summary_chars,
            .max_source_chars = self.compaction_max_source_chars,
            .token_limit = self.token_limit,
            .max_tokens = self.max_tokens,
            .message_timeout_secs = self.message_timeout_secs,
            .max_history_messages = self.max_history_messages,
            .workspace_dir = self.workspace_dir,
            .archive_memory = self.mem,
            .archive_session_id = self.memory_session_id,
            .archive_mem_rt = self.mem_rt,
            .extraction_state_mgr = self.extraction_state_mgr,
            .extraction_user_id = self.extraction_user_id,
            .extraction_coref_embed = self.extraction_coref_embed,
            .extraction_judge_provider = self.extraction_judge_provider,
            .extraction_judge_model_name = resolved_judge_model,
            // V1.14.12 (Path A) — extraction_legacy_direct_writes propagation removed.
            // V1.14.12 (M2 review CRITICAL) — propagate the cardinality
            // fast-path flag so Pass C judge_ctx honors operator config.
            .extraction_cardinality_fastpath = self.extraction_cardinality_fastpath,
        };
    }

    /// Force-compress history for context exhaustion recovery.
    /// Archives dropped messages to memory (when available) before deleting them.
    pub fn forceCompressHistory(self: *Agent) bool {
        return compaction.forceCompressHistoryWithArchive(
            self.allocator,
            &self.history,
            self.mem,
            self.mem_rt,
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

    /// Reset per-turn scratch state. Kept for turn-boundary hygiene.
    /// Context v2 removed the enriched-user substitution path, so this just
    /// clears the raw-user pointer tracking now.
    fn clearCurrentTurnProviderOverride(self: *Agent) void {
        self.current_turn_raw_user = null;
    }

    fn providerMessageForOwned(self: *const Agent, msg: *const OwnedMessage) ChatMessage {
        // Context v2: history holds raw user bytes; emit as-is to preserve
        // byte-stability across turns for provider KV-cache hits. No
        // substitution, no prior-memory prepending.
        _ = self;
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
            // Telegram + other channel adapters emit "[Voice]: <transcript>" and
            // "[Audio]: <transcript>" (bracket closes before the colon). The
            // prior form "[voice:" / "[audio:" matched the bracketed sentinel
            // used by the agent output pipeline, not the inbound-channel prefix,
            // so voice_replies=on was silently a no-op on real voice notes.
            // Match "[voice]" / "[audio]" instead, which is a prefix of both
            // forms and is case-insensitive-safe.
            .inbound => containsAsciiIgnoreCase(user_message, "[voice]") or containsAsciiIgnoreCase(user_message, "[audio]"),
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
            // S7.7 — TTS failure-notice parity with STT. Previously the
            // return-null path dropped audio to text silently; STT has
            // emitted a `system_notice` via `emitMultimodalFailureNotice`
            // since its initial wiring. Now both directions surface the
            // same operator-visible frame so "audio channel degraded"
            // chrome fires consistently.
            var detail_buf: [128]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "tts synth failed: provider={s} reason={s}", .{ provider_name, @errorName(err) }) catch "tts synth failed";
            voice_mod.emitMultimodalFailureNotice(&self.observer, detail);
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

        if (looksLikeInProgressStatusClaim(text)) return true;

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

    const strong_in_progress_status_prefixes = [_][]const u8{
        "executing ",
        "running ",
        "searching ",
        "fetching ",
        "checking ",
        "trying ",
        "attempting ",
        "looking up ",
        "working on ",
        "opening ",
        "calling ",
        "sending ",
        "querying ",
        "inspecting ",
        "verifying ",
    };

    const weak_in_progress_status_prefixes = [_][]const u8{
        "using ",
        "reading ",
        "loading ",
    };

    fn looksLikeInProgressStatusClaim(text: []const u8) bool {
        const raw_line = firstNonEmptyLine(text) orelse return false;
        const line = trimActionStatusLeadIn(raw_line);
        if (line.len == 0 or line.len > 160) return false;

        var matched_strong_prefix = false;
        inline for (strong_in_progress_status_prefixes) |prefix| {
            if (startsWithAsciiIgnoreCase(line, prefix)) {
                matched_strong_prefix = true;
                break;
            }
        }
        if (matched_strong_prefix) {
            return !looksLikeNonActionExplanation(line);
        }

        var matched_weak_prefix = false;
        inline for (weak_in_progress_status_prefixes) |prefix| {
            if (startsWithAsciiIgnoreCase(line, prefix)) {
                matched_weak_prefix = true;
                break;
            }
        }
        if (!matched_weak_prefix) return false;
        if (looksLikeNonActionExplanation(line)) return false;

        return std.mem.endsWith(u8, line, ":") or
            std.mem.endsWith(u8, line, "...") or
            std.mem.endsWith(u8, line, "…") or
            containsAsciiIgnoreCase(line, " now") or
            containsAsciiIgnoreCase(line, " before i") or
            containsAsciiIgnoreCase(line, " for you") or
            containsAsciiIgnoreCase(line, " to check") or
            containsAsciiIgnoreCase(line, " to verify");
    }

    fn looksLikeStreamingStatusPrefix(line: []const u8) bool {
        const normalized = trimActionStatusLeadIn(line);
        if (normalized.len == 0 or normalized.len > 160) return false;
        inline for (strong_in_progress_status_prefixes) |prefix| {
            if (matchesAsciiPrefixPartially(normalized, prefix)) return true;
        }
        inline for (weak_in_progress_status_prefixes) |prefix| {
            if (matchesAsciiPrefixPartially(normalized, prefix)) return true;
        }
        return false;
    }

    fn trimActionStatusLeadIn(line: []const u8) []const u8 {
        var rest = std.mem.trimLeft(u8, line, " \t([{<\"'`*_#>-");
        var iterations: u8 = 0;
        while (iterations < 3 and rest.len > 0) : (iterations += 1) {
            const marker = extractLeadingAsciiWord(rest) orelse break;
            if (!isActionStatusLeadInMarker(marker.word)) break;
            rest = std.mem.trimLeft(u8, rest[marker.end_index..], " \t,:;.!?-)]}>\"'`*_#");
        }
        return rest;
    }

    fn extractLeadingAsciiWord(text: []const u8) ?struct { word: []const u8, end_index: usize } {
        if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return null;
        var idx: usize = 0;
        while (idx < text.len and std.ascii.isAlphabetic(text[idx])) : (idx += 1) {}
        return .{ .word = text[0..idx], .end_index = idx };
    }

    fn isActionStatusLeadInMarker(word: []const u8) bool {
        const markers = [_][]const u8{
            "actually",
            "ok",
            "okay",
            "alright",
            "right",
            "sure",
            "well",
            "so",
            "then",
            "now",
            "great",
            "fine",
        };
        inline for (markers) |marker| {
            if (std.ascii.eqlIgnoreCase(word, marker)) return true;
        }
        return false;
    }

    fn looksLikeNonActionExplanation(line: []const u8) bool {
        const negative_markers = [_][]const u8{
            " not ",
            "n't ",
            "cannot ",
            "can't ",
            "unable ",
            "unsupported",
            "unavailable",
            "unnecessary",
            "no need",
            "not necessary",
            "disabled",
            "impossible",
            "without ",
        };
        inline for (negative_markers) |marker| {
            if (containsAsciiIgnoreCase(line, marker)) return true;
        }
        return false;
    }

    fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
        var start: usize = 0;
        while (start < text.len) {
            while (start < text.len and (text[start] == '\n' or text[start] == '\r')) : (start += 1) {}
            if (start >= text.len) return null;
            const line_end_rel = std.mem.indexOfAnyPos(u8, text, start, "\r\n") orelse text.len;
            const line = std.mem.trim(u8, text[start..line_end_rel], " \t");
            if (line.len > 0) return line;
            start = line_end_rel + 1;
        }
        return null;
    }

    fn startsWithToolCallMarkup(text: []const u8) bool {
        const trimmed = std.mem.trimLeft(u8, text, " \t\r\n");
        return std.mem.startsWith(u8, trimmed, "<tool_call>");
    }

    /// True when the streaming buffer's first line looks like tool-call
    /// markup we want to hold off the user-visible stream. Matches:
    ///
    ///   * `<tool_call>` and any partial prefix of it (`<`, `<t`, `<tool_c`…) —
    ///     the canonical opener; the streaming callback may see only the first
    ///     few bytes in chunk 1 and the rest in chunk 2.
    ///   * `tool_call>` — the residue we see when an upstream stage (provider
    ///     normaliser, codex tool-payload pass) ate the leading `<` while
    ///     trying to recognise the opener.
    ///   * `ool_call>` — the residue when the leading `<t` was eaten (the
    ///     exact QA T4a / T6 leak shape).
    ///
    /// The streaming callback uses this to switch to `hold_for_validation` so
    /// none of these shapes flow to `final_reply` tokens. The held text is
    /// parsed/stripped post-completion (see `startsWithToolCallMarkup` for
    /// malformed-startup handling and `stripToolCallMarkup` for the final-text
    /// belt-and-suspenders).
    ///
    /// `line` is expected pre-trimmed (from `firstNonEmptyLine`).
    fn looksLikeToolCallMarkupPrefix(line: []const u8) bool {
        // Canonical opener — full or partial prefix.
        if (matchesAsciiPrefixPartially(line, "<tool_call>")) return true;
        // Residue shapes — must be exact-prefix matches so a stray substring
        // mid-sentence doesn't hold a legitimate reply.
        if (std.mem.startsWith(u8, line, "tool_call>")) return true;
        if (std.mem.startsWith(u8, line, "ool_call>")) return true;
        return false;
    }

    /// D53 third defense layer (2026-05-24): when streaming a chunk through
    /// the `.pass_through` path, return the number of TRAILING bytes that
    /// could be the start of a (yet-unfinished) markup sentinel. Caller
    /// holds those bytes until the next chunk so a markup token split
    /// across two chunks (e.g. chunk N ends "...<too", chunk N+1 starts
    /// "l_call>{") gets reassembled and stripped on the combined buffer.
    ///
    /// Sentinels we care about: `<tool_call>` (11), `</tool_call>` (12),
    /// `tool_call>` (10), `ool_call>` (9). Hold the LONGEST tail that
    /// matches a non-empty prefix of any sentinel; cap at the longest
    /// sentinel length minus one (12 - 1 = 11). Empty input → 0.
    fn trailingMarkupPrefixLen(buf: []const u8) usize {
        if (buf.len == 0) return 0;
        const sentinels = [_][]const u8{
            "</tool_call>",
            "<tool_call>",
            "tool_call>",
            "ool_call>",
        };
        const max_hold: usize = 11;
        const scan_start: usize = if (buf.len > max_hold) buf.len - max_hold else 0;
        var best: usize = 0;
        // Try each tail position from earliest possible to end-of-buf and
        // see if buf[i..] is a strict prefix of any sentinel (and shorter
        // than the full sentinel — equal length means we have the COMPLETE
        // sentinel and stripToolCallMarkup would have eaten it already).
        var i: usize = scan_start;
        while (i < buf.len) : (i += 1) {
            const tail = buf[i..];
            inline for (sentinels) |s| {
                if (tail.len < s.len and std.mem.eql(u8, tail, s[0..tail.len])) {
                    const hold = buf.len - i;
                    if (hold > best) best = hold;
                }
            }
        }
        return best;
    }

    /// Defensive scrub of tool-call markup from text that's about to be emitted
    /// as a user-facing reply. Handles three cases the streaming hold-path
    /// can't catch on its own:
    ///
    ///   1. **Complete blocks** — `<tool_call>{…}</tool_call>` embedded
    ///      mid-text (model emitted text → markup → text in the SAME
    ///      response chunk, so the streamer was already in pass_through).
    ///   2. **Stray fragments** — `<tool_call>`, `</tool_call>`,
    ///      `<tool_call` (incomplete open), `tool_call>` and `ool_call>`
    ///      (the partial-prefix residue when the streamer held the leading
    ///      `<t` or `<` and then flushValidatedReply emitted the rest of
    ///      `final_text` verbatim). The QA T6 leak (`ool_call>` prefix
    ///      ahead of a clean answer) is exactly this case.
    ///   3. **Trailing whitespace runs** left by the strip — two or more
    ///      consecutive blank lines collapse to one.
    ///
    /// Returns an owned slice. On allocator OOM, returns the original
    /// (caller-owned) text unchanged — the leak is cosmetic and we'd rather
    /// emit the raw answer than fail the turn.
    fn stripToolCallMarkup(allocator: std.mem.Allocator, text: []const u8) []u8 {
        // Fast path: nothing to strip if the text doesn't mention "tool_call"
        // at all (the trailing `_call` is the rarest substring so check
        // partial first to short-circuit).
        if (std.mem.indexOf(u8, text, "tool_call") == null and
            std.mem.indexOf(u8, text, "ool_call>") == null)
        {
            return allocator.dupe(u8, text) catch return @constCast(text);
        }

        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(allocator);

        var rest = text;
        while (rest.len > 0) {
            // Find the next markup remnant: prefer the longest match so an
            // open tag isn't half-consumed by a fragment match.
            const opens = std.mem.indexOf(u8, rest, "<tool_call>");
            const closes = std.mem.indexOf(u8, rest, "</tool_call>");
            const open_partial = std.mem.indexOf(u8, rest, "<tool_call"); // missing >
            const tag_frag = std.mem.indexOf(u8, rest, "tool_call>"); // missing <
            const partial_frag = std.mem.indexOf(u8, rest, "ool_call>"); // missing <t

            // Earliest hit wins.
            var hit: ?usize = null;
            var hit_len: usize = 0;
            inline for (.{
                .{ opens, "<tool_call>".len, true },
                .{ closes, "</tool_call>".len, false },
                .{ open_partial, "<tool_call".len, false },
                .{ tag_frag, "tool_call>".len, false },
                .{ partial_frag, "ool_call>".len, false },
            }) |entry| {
                if (entry[0]) |idx| {
                    if (hit == null or idx < hit.?) {
                        hit = idx;
                        hit_len = entry[1];
                        // Marker: if it's a true `<tool_call>` opener, also
                        // try to consume up to the matching `</tool_call>`.
                        if (entry[2]) {
                            if (std.mem.indexOfPos(u8, rest, idx + entry[1], "</tool_call>")) |close_idx| {
                                hit_len = (close_idx + "</tool_call>".len) - idx;
                            }
                            // No matching close — drop just the opener; the
                            // dangling JSON body will be cleaned up by the
                            // bracket-balance heuristic on the next loop
                            // iteration (or stays as harmless prose).
                        }
                    }
                }
            }

            if (hit == null) {
                out.appendSlice(allocator, rest) catch return @constCast(text);
                break;
            }
            out.appendSlice(allocator, rest[0..hit.?]) catch return @constCast(text);
            rest = rest[hit.? + hit_len ..];
        }

        // Collapse runs of >=2 blank lines down to one.
        const collapsed = collapseBlankLineRuns(allocator, out.items) catch {
            return out.toOwnedSlice(allocator) catch return @constCast(text);
        };
        out.deinit(allocator);
        return collapsed;
    }

    /// Helper for `stripToolCallMarkup`. Collapses runs of consecutive empty
    /// lines (≥3 newlines in a row → 2 newlines).
    fn collapseBlankLineRuns(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(allocator);
        var i: usize = 0;
        var newline_run: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == '\n') {
                newline_run += 1;
                if (newline_run <= 2) try out.append(allocator, c);
            } else if (c == ' ' or c == '\t' or c == '\r') {
                if (newline_run > 0) {
                    // skip whitespace inside a newline run
                } else {
                    try out.append(allocator, c);
                }
            } else {
                newline_run = 0;
                try out.append(allocator, c);
            }
        }
        // Trim leading whitespace introduced by the strip.
        const trimmed = std.mem.trimLeft(u8, out.items, " \t\r\n");
        const result = try allocator.dupe(u8, trimmed);
        out.deinit(allocator);
        return result;
    }

    fn startsWithAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
        }
        return true;
    }

    fn matchesAsciiPrefixPartially(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len == 0 or needle.len == 0) return false;
        const limit = @min(haystack.len, needle.len);
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
        }
        return true;
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
        "**This is your reply to the user. Not a planning document. Not a step-by-step outline. The actual reply.**\n\n" ++
        "**STEP 1 (mandatory): Surface what the tool above just returned.** Quote file contents, show command output, list recalled memory entries with their actual keys + content, cite search findings inline with URLs, confirm the byte count + path that was written. The user CANNOT see the `<tool_result>` block above — they see only your text. If you don't render it, it didn't happen for them.\n\n" ++
        "**STEP 2 (only after Step 1): Decide if more tools are needed for the user's full request.** If yes, fire the next tool — do NOT print a heading like 'Step 2: Reading the file' without immediately firing the read tool. **Empty step headers ('Step N:', 'Now I will...', 'Next:') without the actual execution AND result are equivalent to fabricating progress.** If no more tools needed, conclude with the actual answer (not a plan to answer).\n\n" ++
        "Concrete examples:\n" ++
        "  WRONG (R7-tool — the rough edge from prompt-7 testing 2026-04-27):\n" ++
        "    iter 0 emits: '**Step 1: Writing the file**' + file_write tool call → tool succeeds\n" ++
        "    iter 1 emits: '**Step 2: Reading the file back**' (and stops — no file_read tool, no content)\n" ++
        "    User sees: two empty headings. No file content. No confirmation. Failure.\n\n" ++
        "  RIGHT:\n" ++
        "    iter 0 emits: file_write tool call (no preamble headings yet)\n" ++
        "    iter 1 emits: 'Wrote 24 bytes to research_test.txt: \"researcher pass at 01:32\"' + file_read tool call\n" ++
        "    iter 2 emits: 'Read back: \"researcher pass at 01:32\" — confirmed.'\n" ++
        "    User sees: actual results at every step. Trust contract preserved.\n\n" ++
        "Failure modes to refuse:\n" ++
        "  - 'Step N: <action>' with no execution OR result in the same iteration\n" ++
        "  - '✅ done' / '✅ SUCCESS' with no rendered result content\n" ++
        "  - 'I'll do X' / 'Now I will Y' as a complete reply without doing X/Y\n" ++
        "  - Bullet lists of actions you're about to take without executing them\n\n" ++
        "If a tool failed due to policy/permissions, do not repeat the same blocked call; explain the limitation, surface the actual error message from the tool, and choose a different available tool or ask the user for permission/config change. " ++
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

    /// Why a tool was blocked during preflight. Keeps the decision
    /// self-describing for dispatch consumers without requiring string parsing.
    const ToolPreflightSource = enum {
        security_read_only,
        action_budget,
        execution_mode,
        background_origin,
        approval_required,
        approval_denied,
        /// Blocked because the user's entitlement does not cover this tool
        /// (expired subscription, free tier calling an expensive class-C
        /// tool, or integration tool called with integrations disabled).
        /// Gateway surfaces this as HTTP 402 when it reaches chat-stream
        /// (S2.3); per-tool blocks reach the LLM as a normal tool error.
        entitlement_required,
    };

    /// Outcome of the approval policy gate resolved from tool metadata + autonomy.
    /// Split out from `ApprovalPolicy` so `confirm_once`/`confirm_always` collapse
    /// into a single actionable verdict for preflight.
    const ApprovalGateOutcome = enum { allow, require_confirm, deny };

    fn resolveApprovalGateOutcome(
        meta: tool_metadata.ToolMetadata,
        autonomy: AutonomyLevel,
    ) ApprovalGateOutcome {
        return switch (ApprovalPolicy.forTool(meta, autonomy)) {
            .auto_approve => .allow,
            .confirm_once, .confirm_always => .require_confirm,
            .deny => .deny,
        };
    }

    /// Owned snapshot of a tool call awaiting generic user approval.
    /// Strings are duped from the call so they survive across turns and
    /// are independent of model-response arenas.
    ///
    /// Sprint 2 (prod-readiness 2026-05-28) — added `approval_id`,
    /// `created_at_unix` for the canonical UI binding contract:
    ///
    ///   * `approval_id` is a stable string the UI pins to a single
    ///     approval card. Format: `apr-<u64>` (deterministic transform
    ///     of `id`). FE sends it back in `POST /sessions/:key/approve`
    ///     so a stale card cannot accidentally resolve a NEW pending
    ///     approval that took the slot after a collision-reject.
    ///   * `created_at_unix` powers the UI's "waiting Ns" countdown and
    ///     is the anchor for future TTL enforcement (currently unused
    ///     by the runtime; the field is the schema commitment).
    ///   * `expires_at_unix` is null in V1 (no TTL sweep yet); the
    ///     schema slot exists so the UI can render countdown when
    ///     populated by V1.x.
    pub const PendingToolApproval = struct {
        id: u64,
        /// Stable wire ID for the FE — `apr-<id>`. Heap-owned.
        approval_id: []const u8,
        tool_name: []const u8,
        tool_call_id: ?[]const u8,
        arguments_json: []const u8,
        reason: []const u8,
        risk_level: tool_metadata.RiskLevel,
        /// Unix epoch seconds — when the approval was created.
        created_at_unix: i64,
        /// Optional Unix epoch seconds — when the approval auto-expires.
        /// V1 always-null (no TTL sweep). UI renders countdown when set.
        expires_at_unix: ?i64 = null,
    };

    const ToolPreflightAllowed = struct {
        metadata: tool_metadata.ToolMetadata,
    };

    const ToolPreflightBlocked = struct {
        name: []const u8,
        tool_call_id: ?[]const u8,
        output: []const u8,
        source: ToolPreflightSource,
        reason: []const u8,
        mode: ExecutionMode,
        risk_level: tool_metadata.RiskLevel,
        metadata: tool_metadata.ToolMetadata,

        fn toToolExecutionResult(self: ToolPreflightBlocked) ToolExecutionResult {
            return .{
                .name = self.name,
                .output = self.output,
                .success = false,
                .tool_call_id = self.tool_call_id,
            };
        }
    };

    const ToolPreflightDecision = union(enum) {
        allowed: ToolPreflightAllowed,
        blocked: ToolPreflightBlocked,
    };

    /// Kept as an alias of `ToolPreflightDecision` to minimise churn across
    /// existing call sites and tests.
    const PolicyPreflightResult = ToolPreflightDecision;

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

            // Parallel workers run on separate threads; each needs its own
            // bound controller so self-inspection tools (context_snapshot) see
            // the same agent as the main turn loop. set_execution_mode is
            // flagged concurrency_safe=false so it never fans out here.
            tools_mod.setAgentController(self.agent.controller());
            defer tools_mod.clearAgentController();

            tools_mod.setToolObserver(&self.agent.observer);
            defer tools_mod.clearToolObserver();

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

    fn isParallelSafeToolCall(self: *const Agent, call: ParsedToolCall) bool {
        // Single source of truth: `ToolMetadata.flags.concurrency_safe`
        // resolved via canonicalMetadataForCall (which performs args-aware
        // refinement for action-dispatched tools like schedule/composio).
        // This used to be a hardcoded allowlist that drifted from the
        // metadata registry — see the migration note in tools/root.zig's
        // refineMetadata.
        const meta = tools_mod.canonicalMetadataForCall(self.allocator, call.name, call.arguments_json);
        return meta.flags.concurrency_safe;
    }

    fn recordSessionToolNames(self: *Agent, parsed_calls: []const ParsedToolCall) void {
        for (parsed_calls) |call| {
            const owned_name = self.allocator.dupe(u8, call.name) catch |err| {
                log.warn("procedural_memory.tool_name_dupe_failed tool={s} err={s}", .{ call.name, @errorName(err) });
                continue;
            };
            self.session_tool_names.append(self.allocator, owned_name) catch |err| {
                log.warn("procedural_memory.tool_name_append_failed tool={s} err={s}", .{ call.name, @errorName(err) });
                self.allocator.free(owned_name);
            };
        }
    }

    fn clearSessionToolNames(self: *Agent) void {
        for (self.session_tool_names.items) |name| {
            self.allocator.free(name);
        }
        self.session_tool_names.clearRetainingCapacity();
    }

    fn snapshotAndClearActiveGoalState(self: *Agent) void {
        if (self.active_goal_state) |*goal_state| {
            self.session_last_goal_status = goal_state.status;
            goal_state.deinit(self.allocator);
        }
        self.active_goal_state = null;
    }

    /// Resolve tool metadata for a call via the canonical helper in
    /// `tools/root.zig`. Kept as a thin wrapper so agent preflight, reporting
    /// paths (`/permissions`), and SecurityPolicy callers all read metadata
    /// through the same registry + args-aware refinement.
    fn metadataForToolCall(self: *Agent, call: ParsedToolCall) tool_metadata.ToolMetadata {
        return tools_mod.canonicalMetadataForCall(self.allocator, call.name, call.arguments_json);
    }

    /// Origin gate used by preflight. Parses args once locally so the gate
    /// shares the same argument-aware behavior as the original
    /// `toolBlockedForCurrentTurn` call site without relying on the caller
    /// to pre-parse arguments.
    fn checkBackgroundOriginGate(self: *Agent, call: ParsedToolCall, meta: tool_metadata.ToolMetadata) ?[]const u8 {
        const turn_ctx = tools_mod.getTurnContext();
        if (!tools_mod.isBackgroundTurnOrigin(turn_ctx.origin)) return null;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            call.arguments_json,
            .{},
        ) catch {
            // If args aren't valid JSON we fall back to name-only check with an
            // empty object — downstream tool exec will also reject the call.
            var empty = std.json.ObjectMap.init(self.allocator);
            defer empty.deinit();
            return tools_mod.toolBlockedForCurrentTurnWithMeta(call.name, empty, meta);
        };
        defer parsed.deinit();
        const args_obj: std.json.ObjectMap = switch (parsed.value) {
            .object => |obj| obj,
            else => blk: {
                break :blk std.json.ObjectMap.init(self.allocator);
            },
        };
        return tools_mod.toolBlockedForCurrentTurnWithMeta(call.name, args_obj, meta);
    }

    fn backgroundSendModeBlocked(self: *Agent, call: ParsedToolCall) bool {
        if (!std.mem.eql(u8, call.name, tools_mod.message.MessageTool.tool_name)) return false;
        const turn_ctx = tools_mod.getTurnContext();
        if (!tools_mod.isBackgroundTurnOrigin(turn_ctx.origin)) return false;
        return self.send_mode == .off;
    }

    fn appendPendingApprovalToolHistory(
        self: *Agent,
        arena: std.mem.Allocator,
        results: []const ToolExecutionResult,
    ) !void {
        if (results.len == 0) return;

        const formatted_results = try dispatcher.formatToolResults(arena, results);
        const scrubbed_results = try providers.scrubToolOutput(arena, formatted_results);
        try self.history.append(self.allocator, .{
            .role = .user,
            .content = try self.allocator.dupe(u8, scrubbed_results),
        });
    }

    pub const PendingApprovalSnapshot = struct {
        exec_id: u64,
        command: []const u8,
    };

    /// W2.3: Read-only snapshot of the current pending tool approval.
    /// Returns null when no approval is pending. The returned `command` slice
    /// points into Agent-owned memory; callers must copy it if they need to
    /// outlive the Agent's mutex window.
    pub fn pendingApprovalSnapshot(self: *const Agent) ?PendingApprovalSnapshot {
        const cmd = self.pending_exec_command orelse return null;
        return .{ .exec_id = self.pending_exec_id, .command = cmd };
    }

    pub fn clearPendingToolApproval(self: *Agent) void {
        const pending = self.pending_tool_approval orelse return;
        self.allocator.free(pending.approval_id);
        self.allocator.free(pending.tool_name);
        if (pending.tool_call_id) |id| self.allocator.free(id);
        self.allocator.free(pending.arguments_json);
        self.allocator.free(pending.reason);
        self.pending_tool_approval = null;
    }

    fn setPendingToolApproval(
        self: *Agent,
        call: ParsedToolCall,
        meta: tool_metadata.ToolMetadata,
        reason: []const u8,
    ) !u64 {
        // v1 contract: exactly one pending generic approval at a time.
        // Refuse to silently overwrite a prior request the user has not yet
        // resolved — the caller decides how to surface the collision.
        if (self.pending_tool_approval != null) return error.PendingToolApprovalAlreadyExists;

        const tool_name = try self.allocator.dupe(u8, call.name);
        errdefer self.allocator.free(tool_name);
        const args_copy = try self.allocator.dupe(u8, call.arguments_json);
        errdefer self.allocator.free(args_copy);
        const reason_copy = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(reason_copy);
        var tool_call_id_copy: ?[]const u8 = null;
        errdefer if (tool_call_id_copy) |id| self.allocator.free(id);
        if (call.tool_call_id) |id| {
            tool_call_id_copy = try self.allocator.dupe(u8, id);
        }

        self.pending_tool_approval_id_counter += 1;
        if (self.pending_tool_approval_id_counter == 0) self.pending_tool_approval_id_counter = 1;
        const new_id = self.pending_tool_approval_id_counter;

        // Sprint 2 (2026-05-28) — derive a stable wire ID the FE can
        // pin. Format `apr-<u64>`. The u64 is per-session (lives in
        // `pending_tool_approval_id_counter`) so collisions can only
        // happen within a single agent instance — and the
        // `error.PendingToolApprovalAlreadyExists` reject above prevents
        // overwrite while one is live.
        const approval_id = try std.fmt.allocPrint(self.allocator, "apr-{d}", .{new_id});
        errdefer self.allocator.free(approval_id);

        self.pending_tool_approval = .{
            .id = new_id,
            .approval_id = approval_id,
            .tool_name = tool_name,
            .tool_call_id = tool_call_id_copy,
            .arguments_json = args_copy,
            .reason = reason_copy,
            .risk_level = meta.risk_level,
            .created_at_unix = std.time.timestamp(),
            .expires_at_unix = null,
        };
        return new_id;
    }

    /// Execute the currently pending approved tool exactly once.
    /// Bypasses the generic approval preflight but preserves other gates.
    /// Returned output may borrow either static storage or memory owned by
    /// `tool_allocator`; keep that allocator alive until the caller is done.
    ///
    /// **CR-01 fix (2026-05-07):** does NOT clear pending state. The
    /// pre-fix design used `defer self.clearPendingToolApproval();` here,
    /// which freed the slice fields of `pending_tool_approval` (tool_name,
    /// arguments_json, etc.) before the caller's synthetic-message
    /// `allocPrint(.., .{pending.tool_name, ...})` ran — classic UAF.
    /// Now ownership is in the CALLER (`handleGenericToolApprove`):
    /// callers must invoke `clearPendingToolApproval()` after they've
    /// finished reading the pending struct's slices. Re-approval during
    /// tool execution is prevented by `approval_bypass_active` below,
    /// not by clearing the pending struct.
    pub fn executeApprovedPendingTool(
        self: *Agent,
        tool_allocator: std.mem.Allocator,
    ) !ToolExecutionResult {
        const pending = self.pending_tool_approval orelse return error.NoPendingApproval;
        // Rebuild a ParsedToolCall pointing at the owned snapshot so
        // dispatch sees identical arguments to what the user approved.
        const call = ParsedToolCall{
            .name = pending.tool_name,
            .arguments_json = pending.arguments_json,
            .tool_call_id = pending.tool_call_id,
        };
        self.approval_bypass_active = true;
        defer self.approval_bypass_active = false;
        // Re-run preflight (security, budget, mode) but skip approval gate.
        return switch (self.preflightToolPolicy(call)) {
            .allowed => self.executeToolUnchecked(tool_allocator, call),
            .blocked => |decision| decision.toToolExecutionResult(),
        };
    }

    fn preflightToolPolicy(self: *Agent, call: ParsedToolCall) PolicyPreflightResult {
        const meta = self.metadataForToolCall(call);

        if (self.policy) |pol| {
            if (!pol.canAct()) {
                return .{ .blocked = .{
                    .name = call.name,
                    .tool_call_id = call.tool_call_id,
                    .output = "Action blocked: agent is in read-only mode",
                    .source = .security_read_only,
                    .reason = "security_policy_read_only",
                    .mode = self.execution_mode,
                    .risk_level = meta.risk_level,
                    .metadata = meta,
                } };
            }
            if (pol.isRateLimited()) {
                return .{ .blocked = .{
                    .name = call.name,
                    .tool_call_id = call.tool_call_id,
                    .output = "Action budget exhausted",
                    .source = .action_budget,
                    .reason = "action_budget_exhausted",
                    .mode = self.execution_mode,
                    .risk_level = meta.risk_level,
                    .metadata = meta,
                } };
            }
        }
        // Background-origin gate: when the current turn runs on a background
        // lane (heartbeat/wake/scheduler/proactive), enforce the per-origin
        // policy before we consume budget or trigger approval. This used to
        // run from `executeToolUnchecked` after the approval gate, which let
        // budget be spent and approval be surfaced for calls the origin lane
        // would never execute.
        if (self.checkBackgroundOriginGate(call, meta)) |msg| {
            return .{ .blocked = .{
                .name = call.name,
                .tool_call_id = call.tool_call_id,
                .output = msg,
                .source = .background_origin,
                .reason = "background_origin_denied",
                .mode = self.execution_mode,
                .risk_level = meta.risk_level,
                .metadata = meta,
            } };
        }
        if (self.backgroundSendModeBlocked(call)) {
            return .{ .blocked = .{
                .name = call.name,
                .tool_call_id = call.tool_call_id,
                .output = "Proactive sends are disabled (send_mode=off)",
                .source = .background_origin,
                .reason = "send_mode_off",
                .mode = self.execution_mode,
                .risk_level = meta.risk_level,
                .metadata = meta,
            } };
        }
        // Execution mode gate: block tools not allowed in current mode.
        // Built-in tools come from `defaultMetadataRegistry`; unknown tool
        // names (MCP, dynamic) fall back to conservative policy via
        // `metadataForToolCall`.
        if (self.execution_mode != .execute) {
            if (!self.execution_mode.allowsTool(meta)) {
                const output: []const u8 = switch (self.execution_mode) {
                    .plan => "Tool blocked: not allowed in plan mode (read-only tools only)",
                    .review => "Tool blocked: not allowed in review mode (read-only tools only)",
                    .background => "Tool blocked: not allowed in background mode (background-safe tools only)",
                    .execute => unreachable, // execute allows all tools
                };
                const reason: []const u8 = switch (self.execution_mode) {
                    .plan, .review => "mode_requires_read_only",
                    .background => "mode_requires_background_safe",
                    .execute => unreachable,
                };
                return .{ .blocked = .{
                    .name = call.name,
                    .tool_call_id = call.tool_call_id,
                    .output = output,
                    .source = .execution_mode,
                    .reason = reason,
                    .mode = self.execution_mode,
                    .risk_level = meta.risk_level,
                    .metadata = meta,
                } };
            }
        }
        // Entitlement gate (S2.4). Runs BEFORE the approval gate so a free
        // user hitting an expensive tool sees a clean "upgrade required"
        // instead of an approval prompt that would never enable the call.
        // approval_bypass_active bypasses entitlement too: an already-approved
        // pending-tool execution was already gated on the original call, so
        // re-checking entitlement on execution would double-charge the user
        // in subtle ways if their tier was mid-change.
        if (!self.approval_bypass_active) {
            const rt_turn_ctx = tools_mod.getTurnContext();
            const ent = rt_turn_ctx.entitlement;
            const now_unix = std.time.timestamp();

            // Gate 1: billing status must permit any paid action. Expired /
            // canceled-past-period-end collapses to blocking all non-read-only
            // tools. Read-only tools stay allowed so the user can still
            // review and delete their data (GDPR grace).
            if (!ent.canAct(now_unix) and !meta.flags.read_only) {
                return .{ .blocked = .{
                    .name = call.name,
                    .tool_call_id = call.tool_call_id,
                    .output = "Subscription expired — reactivate to use paid features. Read-only tools remain available.",
                    .source = .entitlement_required,
                    .reason = "entitlement_inactive",
                    .mode = self.execution_mode,
                    .risk_level = meta.risk_level,
                    .metadata = meta,
                } };
            }

            const effective_tier = ent.effectiveTier(now_unix);
            const limits = entitlement_mod.Entitlement.limitsFor(effective_tier);

            // Gate 2: class-C (expensive) tools are gated out of the free tier.
            // Users get a clear upgrade prompt rather than a vague rate-limit.
            if (meta.cost_class == .c and effective_tier == .free) {
                return .{ .blocked = .{
                    .name = call.name,
                    .tool_call_id = call.tool_call_id,
                    .output = "This tool is part of the Pro tier. Upgrade to unlock image generation, browser automation, integrations, and subagent delegation.",
                    .source = .entitlement_required,
                    .reason = "entitlement_tier_gate",
                    .mode = self.execution_mode,
                    .risk_level = meta.risk_level,
                    .metadata = meta,
                } };
            }

            // Gate 3: integration tools gated by the explicit feature flag.
            // Distinct from the cost-class gate so enterprise contracts can
            // selectively enable integrations without opening every class-C
            // tool. Enumerated here rather than via a tool_metadata flag
            // because "integration" is a product-boundary concept, not a
            // security-or-cost attribute.
            const is_integration = std.mem.eql(u8, meta.name, "composio") or
                std.mem.eql(u8, meta.name, "mcp");
            if (is_integration and !limits.integrations_enabled) {
                return .{ .blocked = .{
                    .name = call.name,
                    .tool_call_id = call.tool_call_id,
                    .output = "Integrations (Gmail, Calendar, Drive, etc.) are a Pro tier feature. Upgrade to connect your accounts.",
                    .source = .entitlement_required,
                    .reason = "entitlement_integrations_disabled",
                    .mode = self.execution_mode,
                    .risk_level = meta.risk_level,
                    .metadata = meta,
                } };
            }

            // Gate 4 (S2.8): cumulative tool-weight budget. maxInt means
            // "unlimited" (enterprise) — skip the check entirely. Otherwise
            // ask: if this tool runs, does the session's accumulated weight
            // exceed the tier's budget? Conservatively session-scoped here
            // rather than calendar-monthly; true monthly persistence lands
            // with D5 (CostTracker full wire-up). Session-scoping still
            // bounds single-session abuse — a free user cannot run 100
            // class-C tools in a single session and stay under budget=500.
            if (limits.monthly_weight_budget != std.math.maxInt(u64)) {
                const candidate: u64 = @intCast(meta.cost_class.weight());
                const accumulated: u64 = if (self.usage_rt) |urt| urt.sessionWeight() else 0;
                if (accumulated +| candidate > limits.monthly_weight_budget) {
                    return .{ .blocked = .{
                        .name = call.name,
                        .tool_call_id = call.tool_call_id,
                        .output = "Usage budget reached for this billing period. Upgrade your plan or wait until next reset.",
                        .source = .entitlement_required,
                        .reason = "entitlement_weight_budget",
                        .mode = self.execution_mode,
                        .risk_level = meta.risk_level,
                        .metadata = meta,
                    } };
                }
            }
        }

        // Generic approval gate (WP1.4). Only applies when a SecurityPolicy is
        // configured and bypass is not active for an already-approved call.
        if (!self.approval_bypass_active) {
            if (self.policy) |pol| {
                const outcome = resolveApprovalGateOutcome(meta, pol.autonomy);
                switch (outcome) {
                    .allow => {
                        // S5 (2026-05-29, prod-readiness) — the gate ran
                        // and the policy auto-approved. Only emitted
                        // when a SecurityPolicy is configured AND the
                        // approval-bypass is not active, so the counter
                        // tracks genuine approval-relevant decisions
                        // rather than every safe-tool dispatch.
                        observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "auto_approved" } });
                    },
                    .deny => {
                        // S5 (2026-05-29, prod-readiness) — policy-level
                        // deny is the "blocked" tail of the approval
                        // lifecycle. Operator-only autonomy tier rejects
                        // any confirm-required tool outright.
                        observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "blocked" } });
                        return .{ .blocked = .{
                            .name = call.name,
                            .tool_call_id = call.tool_call_id,
                            .output = "Tool denied by approval policy (operator-only)",
                            .source = .approval_denied,
                            .reason = "approval_policy_deny",
                            .mode = self.execution_mode,
                            .risk_level = meta.risk_level,
                            .metadata = meta,
                        } };
                    },
                    .require_confirm => {
                        const reason_text: []const u8 = "supervised_mutating_requires_approval";
                        _ = self.setPendingToolApproval(call, meta, reason_text) catch |err| switch (err) {
                            // Collision: a prior pending approval is unresolved.
                            // Leave it untouched, do not emit another event, and
                            // tell the caller to resolve the existing one first.
                            error.PendingToolApprovalAlreadyExists => return .{ .blocked = .{
                                .name = call.name,
                                .tool_call_id = call.tool_call_id,
                                .output = "Another tool approval is already pending. Resolve it with /approve allow-once|deny before issuing new calls.",
                                .source = .approval_required,
                                .reason = "approval_already_pending",
                                .mode = self.execution_mode,
                                .risk_level = meta.risk_level,
                                .metadata = meta,
                            } },
                            // Out-of-memory or other allocation failure: fail closed.
                            else => return .{ .blocked = .{
                                .name = call.name,
                                .tool_call_id = call.tool_call_id,
                                .output = "Approval required but could not register pending state",
                                .source = .approval_required,
                                .reason = reason_text,
                                .mode = self.execution_mode,
                                .risk_level = meta.risk_level,
                                .metadata = meta,
                            } },
                        };
                        const event = ObserverEvent{ .approval_required = .{
                            .tool = meta.name,
                            .reason = reason_text,
                            .risk_level = meta.risk_level.toSlice(),
                            .run_id = self.current_run_id,
                        } };
                        self.observer.recordEvent(&event);
                        // S5 (2026-05-29, prod-readiness) — approval-lifecycle
                        // chartable signal. "issued" denotes "the gate raised
                        // a confirm request to the user." The user-resolution
                        // tail (user_approved / user_denied) lands at the
                        // commands.zig `/approve` handler; this site only
                        // emits issuance.
                        observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "issued" } });
                        return .{ .blocked = .{
                            .name = call.name,
                            .tool_call_id = call.tool_call_id,
                            .output = "Approval required. Use /approve allow-once|deny",
                            .source = .approval_required,
                            .reason = reason_text,
                            .mode = self.execution_mode,
                            .risk_level = meta.risk_level,
                            .metadata = meta,
                        } };
                    },
                }
            }
        }
        if (self.policy) |pol| {
            const allowed = pol.recordAction() catch true;
            if (!allowed) {
                return .{ .blocked = .{
                    .name = call.name,
                    .tool_call_id = call.tool_call_id,
                    .output = "Action budget exhausted",
                    .source = .action_budget,
                    .reason = "action_budget_exhausted",
                    .mode = self.execution_mode,
                    .risk_level = meta.risk_level,
                    .metadata = meta,
                } };
            }
        }
        return .{ .allowed = .{ .metadata = meta } };
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
            self.last_executed_tool = call.name;
            const tool_start_event = ObserverEvent{ .tool_call_start = .{
                .tool = call.name,
                .tool_use_id = tool_use_id,
                .input_preview = call.arguments_json,
                .command = command,
                .files = files,
                .activity_label = toolActivityLabel(call.name),
                .run_id = self.current_run_id,
            } };
            self.observer.recordEvent(&tool_start_event);

            hooks_mod.runHooks(self.allocator, self.hooks, .tool_start, .{
                .tool_name = call.name,
                .session_key = self.memory_session_id,
                .workspace_dir = self.workspace_dir,
            });

            // **D1.14** — generalized tool-result cache.
            // For tools flagged `cacheable`, check the global cache
            // before executing. Hit → synthesize ToolExecutionResult
            // from cached output, skip the dispatch. Miss → execute,
            // then put successful results into the cache with the
            // metadata's TTL. Mutating tools are statically prevented
            // from being cacheable via ToolFlags.validate.
            //
            // **D1.14 cross-session-safety fix (2026-04-26):** the
            // cache key now includes a scope string built from
            // metadata.cache_scope + agent context. Default scope
            // `.session` folds in tenant_user_id + memory_session_id
            // so a session-scoped tool (memory_recall) cannot leak
            // results across sessions. Pre-fix the key was just
            // (tool_name, args_json) — would have leaked on first
            // opt-in. Caught in self-review before any tool was
            // flagged cacheable; no live data exposure.
            const cache_meta = self.metadataForToolCall(call);
            var cache_scope_buf: [256]u8 = undefined;
            const cache_scope: []const u8 = blk_scope: {
                if (!cache_meta.flags.cacheable) break :blk_scope "";
                const tenant_ctx = tools_mod.getTenantContext();
                break :blk_scope switch (cache_meta.cache_scope) {
                    .global => "global",
                    .tenant => std.fmt.bufPrint(&cache_scope_buf, "tenant:{s}", .{
                        tenant_ctx.user_id orelse "anon",
                    }) catch "tenant:overflow",
                    .session => std.fmt.bufPrint(&cache_scope_buf, "session:{s}:{s}", .{
                        tenant_ctx.user_id orelse "anon",
                        self.memory_session_id orelse "default",
                    }) catch "session:overflow",
                };
            };
            var cache_hit_used: bool = false;
            const tool_timer = std.time.milliTimestamp();
            const result = blk: {
                if (cache_meta.flags.cacheable) {
                    if (result_cache_mod.global.get(tool_allocator, cache_scope, call.name, call.arguments_json)) |hit| {
                        cache_hit_used = true;
                        break :blk dispatcher.ToolExecutionResult{
                            .name = try tool_allocator.dupe(u8, call.name),
                            .output = hit.output,
                            .success = hit.success,
                            .tool_call_id = if (call.tool_call_id) |id| try tool_allocator.dupe(u8, id) else null,
                        };
                    }
                }
                break :blk self.executeTool(tool_allocator, call);
            };
            const tool_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - tool_timer)));

            // **D1.14** — store successful results in the cache on
            // miss + cacheable. Failures are NOT cached (a transient
            // 500 from web_search shouldn't pollute future calls).
            if (!cache_hit_used and cache_meta.flags.cacheable and result.success and cache_meta.cache_ttl_secs > 0) {
                result_cache_mod.global.put(cache_scope, call.name, call.arguments_json, result.output, result.success, cache_meta.cache_ttl_secs) catch |err| {
                    log.warn("D1.14.cache_put_failed tool={s} err={s}", .{ call.name, @errorName(err) });
                };
            }

            const tool_event = ObserverEvent{ .tool_call = .{
                .tool = call.name,
                .duration_ms = tool_duration,
                .success = result.success,
                .tool_use_id = tool_use_id,
                .output_preview = result.output,
                .output_truncated = result.output.len > 256,
                .result_summary = if (cache_hit_used) "cache_hit" else if (result.success) "completed" else "failed",
                .command = command,
                .files = files,
                .run_id = self.current_run_id,
            } };
            self.observer.recordEvent(&tool_event);

            hooks_mod.runHooks(self.allocator, self.hooks, .tool_end, .{
                .tool_name = call.name,
                .tool_success = result.success,
                .session_key = self.memory_session_id,
                .workspace_dir = self.workspace_dir,
            });

            try results_buf.append(self.allocator, result);
            if (self.pending_tool_approval != null) break;
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
                .run_id = self.current_run_id,
            } };
            self.observer.recordEvent(&tool_start_event);

            switch (self.preflightToolPolicy(call)) {
                .blocked => |decision| {
                    blocked[i] = true;
                    ordered_results[i] = decision.toToolExecutionResult();
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
                .run_id = self.current_run_id,
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

    // ── Agent controller (used by set_execution_mode / context_snapshot) ──
    //
    // Tools under `src/tools/` cannot import `agent/root.zig` (cycle), so we
    // expose a narrow vtable they can consult through the thread-local set at
    // the start of each turn. Self-control tools mutate the agent through
    // this interface; other tools ignore it.

    fn agentCtrlSetMode(ptr: *anyopaque, mode: []const u8) bool {
        const agent: *Agent = @ptrCast(@alignCast(ptr));
        const parsed = execution_mode_mod.ExecutionMode.fromString(mode) orelse return false;
        agent.execution_mode = parsed;
        return true;
    }

    fn agentCtrlGetMode(ptr: *anyopaque) []const u8 {
        const agent: *Agent = @ptrCast(@alignCast(ptr));
        return agent.execution_mode.toSlice();
    }

    fn agentCtrlSnapshot(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const agent: *Agent = @ptrCast(@alignCast(ptr));
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.writeAll("{\"execution_mode\":\"");
        try w.writeAll(agent.execution_mode.toSlice());
        try w.writeAll("\",\"verbose_level\":\"");
        try w.writeAll(agent.verbose_level.toSlice());
        try w.writeAll("\",\"reasoning_mode\":\"");
        try w.writeAll(agent.reasoning_mode.toSlice());
        // Q2 (2026-04-27): expose reasoning_effort separately from
        // reasoning_mode. These are orthogonal:
        //   - reasoning_mode: client-side trace VISIBILITY (off/on/stream)
        //   - reasoning_effort: server-side thinking DEPTH (low/medium/high/none)
        // Agent was conflating them when reporting state to user. For
        // reasoning-capable models (Kimi K2.5/K2.6, Moonshot, OpenAI o-series)
        // null reasoning_effort means "use the wire-level default" which for
        // Kimi/Moonshot is "medium" per Together docs (see helpers.zig).
        // We report the explicit user value if set, else "default" so the
        // agent can answer truthfully without lying about a config value
        // that isn't there.
        try w.writeAll("\",\"reasoning_effort\":\"");
        if (agent.reasoning_effort) |re| {
            try w.writeAll(re);
        } else {
            try w.writeAll("default");
        }
        try w.writeAll("\",\"session_key\":");
        if (agent.memory_session_id) |sid| {
            try w.print("\"{s}\"", .{sid});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"pending_tool_approval\":");
        if (agent.pending_tool_approval) |pta| {
            try w.print("{{\"id\":{d},\"tool_name\":\"{s}\",\"risk_level\":\"{s}\"", .{
                pta.id,
                pta.tool_name,
                pta.risk_level.toSlice(),
            });
            if (pta.tool_call_id) |tcid| {
                try w.print(",\"tool_call_id\":\"{s}\"", .{tcid});
            }
            try w.writeAll("}");
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"run_id\":");
        if (agent.current_run_id) |rid| {
            try w.print("\"{s}\"", .{rid});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}");
        return try out.toOwnedSlice(allocator);
    }

    const agent_controller_vtable: tools_mod.AgentController.VTable = .{
        .set_execution_mode = agentCtrlSetMode,
        .get_execution_mode = agentCtrlGetMode,
        .snapshot_json = agentCtrlSnapshot,
    };

    pub fn controller(self: *Agent) tools_mod.AgentController {
        return .{ .ptr = @ptrCast(self), .vtable = &agent_controller_vtable };
    }

    /// Execute a single conversation turn: send messages to LLM, parse tool calls,
    /// execute tools, and loop until a final text response is produced.
    ///
    /// **D1.2:** Returns a `TurnOutcome` struct (text + tool_calls_executed +
    /// spawned_task_ids + iterations_used + loop_detected) instead of bare
    /// `[]const u8`. The legacy `turn()` wrapper at the bottom of this method
    /// preserves the old signature for callers that only need the text.
    /// New callers (gateway, session manager — D1.3, D1.4) should use
    /// `turnOutcome` directly so the structured tool-only-turn SSE frame
    /// can carry real metadata instead of fabricating `EMPTY_TURN_PLACEHOLDER`.
    pub fn turnOutcome(self: *Agent, user_message: []const u8) !TurnOutcome {
        const turn_start_ms = std.time.milliTimestamp();
        self.cancellation_token.reset(); // Clear stale cancellation from previous turn

        // v1.14.13 Agent F: route all per-turn observer events through the
        // narration wrapper so channel/SSE observers receive progress frames.
        //
        // v1.14.18-B G3 (NARRATION-AS-CONTEXT): bind the wrapper to the
        // Agent's persistent narration ring buffer so emitted frames flow
        // into recall. The buffer is Agent-owned (initialized in
        // `fromConfig`) so it survives the per-turn wrapper. We seed
        // `current_iteration` from `self.iteration_counter` here, which is
        // session-monotonic (NOT reset per turn) — so turn 2 may start at
        // iter=17, turn 3 at iter=33, etc. `<recent_thoughts iteration="N">`
        // therefore displays session-wide counts. The counter is bumped
        // per ReAct iteration below (search "iteration_counter +%=" in
        // this function).
        const base_observer = self.observer;
        var narration_observer = narration.NarrationObserver{
            .inner = base_observer,
            .ring_buffer = &self.narration_ring_buffer,
            .current_iteration = self.iteration_counter,
        };
        const wrap_narration = !std.mem.eql(u8, base_observer.getName(), "narration");
        if (wrap_narration) self.observer = narration_observer.observer();
        defer {
            if (wrap_narration) self.observer = base_observer;
        }

        // Bind the agent controller so self-control tools (set_execution_mode,
        // context_snapshot) can read/write our state during this turn.
        tools_mod.setAgentController(self.controller());
        defer tools_mod.clearAgentController();

        // Bind our observer so tools that emit system_notice events
        // (connector_stale, etc.) can surface them on THIS session's SSE
        // stream. Shared `tools_slice` means per-tool observer binding is
        // wrong — threadlocal per-turn is the only correct scope.
        tools_mod.setToolObserver(&self.observer);
        defer tools_mod.clearToolObserver();

        // ── WP1.3 Run ID ──────────────────────────────────────────────
        // Mint one stable run ID per turn so all observer events (tool
        // start/result, llm request/response, turn stages, approvals) can
        // be grouped on the client. Stack-backed; lifetime is the turn.
        self.run_id_counter +%= 1;
        self.current_run_id = std.fmt.bufPrint(
            &self.current_run_id_buf,
            "r-{d}-{d}",
            .{ turn_start_ms, self.run_id_counter },
        ) catch null;
        defer self.current_run_id = null;

        commands.refreshSubagentToolContext(self);
        var turn_llm_calls: u32 = 0;
        var turn_retry_attempts: u32 = 0;
        var turn_tool_calls_total: u32 = 0;
        var turn_tool_iterations: u32 = 0;
        var turn_memory_enrich_ms: u64 = 0;
        var turn_compaction_ms: u64 = 0;
        defer self.session_total_tool_count +%= turn_tool_calls_total; // v1.14.18-A F3
        var turn_first_token_ms: ?u64 = null;
        var turn_first_token_upper_bound_ms: ?u64 = null;
        // v1.14.18-A G4 — active_task_plan is now an Agent field (see decl);
        // it persists across turns so context_engine.assemble can render it
        // as a <task_plan> prompt block. These two flags stay turn-local.
        var task_plan_checked = false;
        var task_plan_complete_emitted = false;

        // **D1.7** — accumulator for task_ids spawned during this turn
        // (via the `spawn` tool — `delegate` is synchronous and inlines
        // its result, so no task_id to track). Populated by parsing the
        // spawn tool's result string ("Subagent 'X' spawned with
        // task_id=N state=queued ...") after each tool execution. Owned
        // by the turn body until ownership transfers to the returned
        // TurnOutcome at exit; freed by `spawned_task_ids_cleanup`
        // defer if no transfer happens (e.g. error path).
        var spawned_task_ids_acc: std.ArrayListUnmanaged([]const u8) = .empty;
        var spawned_task_ids_transferred: bool = false;
        defer {
            if (!spawned_task_ids_transferred) {
                for (spawned_task_ids_acc.items) |id| self.allocator.free(id);
                spawned_task_ids_acc.deinit(self.allocator);
            }
        }

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
            return TurnOutcome.justText(response);
        }

        self.context_was_compacted = false;
        self.context_force_compressed = false;
        self.last_turn_context = .{};
        self.clearCurrentTurnProviderOverride();
        defer self.clearCurrentTurnProviderOverride();

        const turn_start_event = ObserverEvent{ .turn_stage = .{
            .stage = "turn_start",
            .run_id = self.current_run_id,
        } };
        self.observer.recordEvent(&turn_start_event);

        // Fire turn_start hooks
        hooks_mod.runHooks(self.allocator, self.hooks, .turn_start, .{
            .session_key = self.memory_session_id,
            .workspace_dir = self.workspace_dir,
        });

        // Context v2: memory is now part of the volatile system block instead
        // of being prepended to the user message. Load it first so we can
        // include it in the system prompt rebuild below.
        //
        // v1.14.14 ContextEngine migration (CONTEXT-ENGINE audit-ledger row).
        //   Phase 1 — INGEST: the ~163-line memory-enrichment block that
        //   inlined here now lives in ContextEngine.ingest (WM render +
        //   memory_slot load + recall.metrics telemetry + memory_enrich
        //   observer event).
        //   Phase 2 — ASSEMBLE: the ~205-line prompt-rebuild block that
        //   followed (last_turn_context write + capabilities + persona +
        //   procedural_memory + stable/tool/volatile prompt construction +
        //   history[0] write + 5 prompt-state field updates +
        //   prefix.stable_hash diagnostic) now lives in
        //   ContextEngine.assemble.
        //
        // Lifetimes: ingest_out owns heap-allocated memory_slot.fenced_content
        // + wm_render_set + wm_block. The deinit defer below frees them at
        // turn end, AFTER assemble has borrowed memory_slot.fenced_content
        // into PromptContext.memory_slot.
        var ingest_out = try self.context_engine_state.ingest(self.allocator, self, user_message);
        defer ingest_out.deinit(self.allocator);
        turn_memory_enrich_ms = ingest_out.result.memory_enrich_ms;

        // v1.14.18-A F3: Initialize goal-loop state from user message
        // OPTION A: caller (turnOutcome) owns goal_text slice; struct borrows it.
        // goal_text lives for the turn duration (user_message is stable).
        // GoalState.deinit will NOT free goal_text — that's turnOutcome's responsibility.
        const goal_text = try goal_loop.extractGoal(self.allocator, user_message);
        // NOTE: goal_text is NOT freed here; it's borrowed by active_goal_state
        // and freed implicitly when user_message goes out of scope (stack-allocated).
        self.active_goal_state = goal_loop.GoalState{
            .goal_text = goal_text,
            .iteration_count = 0,
            .status = .in_progress,
            .no_progress_count = 0,
            .progress_notes = .empty,
        };
        // Snapshot status for session-end procedural capture before
        // clearing the turn-scoped state. Goal text is borrowed.
        defer self.snapshotAndClearActiveGoalState();

        // v1.14.18-B G5: Initialize reflection trail for capturing iteration-level learning
        var active_reflection_trail = reflection.ReflectionTrail{
            .goal_text = goal_text, // BORROW from user_message
        };
        defer active_reflection_trail.deinit(self.allocator);

        // v1.14.18-B G5 coverage fix (coordinator review, 2026-05-20): serialize
        // the reflection trail on EVERY turnOutcome exit path. The prior inline
        // serialization sat in the post-tool-loop exit block (~root.zig:4656) and
        // was SKIPPED by the in-loop early-returns (approval-pending, cached-
        // response at 3120/3149, tool-driven exits at 4171/4186/4378) — so G5's
        // reflection trail was captured only for turns that ran the tool loop to
        // its natural exit. This defer is registered AFTER the deinit defer above,
        // so by Zig's LIFO ordering it runs FIRST — reading the trail's final
        // state before deinit frees the entries. Covers all 8 return paths.
        defer {
            const trail_json: ?[]const u8 = active_reflection_trail.serialize(self.allocator) catch |err| blk: {
                log.warn("failed to serialize reflection trail: {s}", .{@errorName(err)});
                break :blk self.allocator.dupe(u8, "[]") catch null;
            };
            if (trail_json) |j| {
                // Free the prior turn's trail before overwriting — the field is
                // reassigned every turn-end; a bare assign leaks the previous alloc.
                if (self.session_reflection_trail_json) |old| self.allocator.free(old);
                self.session_reflection_trail_json = j;
            }
        }

        // v1.14.14 Phase 4 — time the assemble phase so afterTurn() can
        // record per-phase durations into stability.json.
        const assemble_start_ms = std.time.milliTimestamp();
        const assemble_result = try self.context_engine_state.assemble(self.allocator, self, &ingest_out);
        const assemble_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - assemble_start_ms));

        // v1.14.14 Phase 4 — afterTurn fires on EVERY post-assemble exit via
        // this single defer. Reads agent state at exit time (last_turn_compacted,
        // history.items.len, turn_compaction_ms) so the snapshot reflects the
        // total post-turn state regardless of which return branch fired.
        // Emits the JSONL stability record to NULLALIS_STABILITY_JSON_PATH
        // (env-gated; no-op by default). Failures are silent — the snapshot
        // is best-effort diagnostic, never a turn blocker.
        //
        // v1.14.14.1 Finding 4 follow-up: CompactResult no longer carries
        // messages_before/messages_after. The synthesized CompactResult here
        // only conveys `.compacted` + `.method` for the afterTurn event-count
        // signals. Per-site accurate message_before/after pairs flow to
        // `self.last_turn_context` via `recordAutoCompaction` /
        // `recordForceCompression` inside `ContextEngine.compact` /
        // `forceCompact`. afterTurn's returned `TurnContextResult` is still
        // discarded by `_ = ...`; agent.last_turn_context is the live surface.
        //
        // `compact_method` is the LAST-WIN classification when both auto and
        // force-compress fired in the same turn (rare: only when the provider
        // returned context-exhausted mid-turn and a subsequent auto-compact
        // also succeeded). Reports `.force_compress` in that case — operator
        // dashboards still see "compaction happened," just not the multiplicity.
        defer {
            const compact_method: context_engine.CompactResult.CompactMethod = if (!self.last_turn_compacted)
                .none
            else if (self.context_force_compressed)
                .force_compress
            else
                .auto;
            _ = self.context_engine_state.afterTurn(
                self.allocator,
                ingest_out.result,
                assemble_result,
                .{
                    .compacted = self.last_turn_compacted,
                    .method = compact_method,
                },
                .{
                    .ingest_ms = ingest_out.result.memory_enrich_ms,
                    .assemble_ms = assemble_duration_ms,
                    .compact_ms = turn_compaction_ms,
                },
                turn_start_ms,
                self.memory_session_id orelse "none",
            );
        }

        // Auto-save user message to memory (nanoTimestamp key to avoid collisions within the same second)
        if (self.auto_save) {
            if (self.mem) |mem| {
                const ts: u128 = @bitCast(std.time.nanoTimestamp());
                const save_key = std.fmt.allocPrint(self.allocator, "autosave_user_{d}", .{ts}) catch null;
                if (save_key) |key| {
                    defer self.allocator.free(key);
                    if (mem.store(key, user_message, .conversation, self.memory_session_id)) |_| {
                        // Vector sync after auto-save (fire-and-forget — the
                        // user's visible save succeeded; vector sync status
                        // reaches operators via log.warn, not the user).
                        if (self.mem_rt) |rt| {
                            _ = rt.syncVectorAfterStore(self.allocator, key, user_message);
                        }
                    } else |err| {
                        // S4.1 — durable-write silent catch closed. Previously
                        // `else |_| {}` ate the error. Autosave is the cold
                        // transcript tier (per the cold-memory-auditability
                        // directive); losing it without a log is a data-integrity
                        // hole invisible to operators. Log + continue (turn
                        // completes; autosave is best-effort, not blocking).
                        log.warn("autosave.user_failed key={s} err={s}", .{ key, @errorName(err) });
                    }
                }
            }
        }

        // Context v2: memory enrichment happens BEFORE system prompt rebuild
        // (see above). User message is no longer wrapped with memory context —
        // the raw user message goes directly into history, and memory lives in
        // the volatile portion of the system prompt via PromptContext.memory_slot.
        // Byte-stable user messages + byte-stable stable system prefix = cache hits
        // across turns on any KV-cache-capable backend.

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
                    // T-1.5-08 + D1.8: enforce MAX_FACTS_PER_SESSION before
                    // storing. Pre-D1.8 this scanned the entire session
                    // memory list on every turn that produced a learning
                    // signal (O(N) over all memories per check). Now we
                    // lazy-init `learning_fact_count` once per session via
                    // the same scan, then maintain it as a counter — O(1)
                    // on every subsequent check.
                    if (self.learning_fact_count == null) {
                        const entries = mem.list(self.allocator, null, self.memory_session_id) catch &.{};
                        defer if (entries.len > 0) {
                            for (entries) |e| {
                                self.allocator.free(e.key);
                                self.allocator.free(e.content);
                            }
                            self.allocator.free(entries);
                        };
                        var fact_count: u32 = 0;
                        for (entries) |e| {
                            if (std.mem.startsWith(u8, e.key, "durable_fact/behavior/")) fact_count += 1;
                        }
                        self.learning_fact_count = fact_count;
                    }
                    const at_limit = (self.learning_fact_count.?) >= learning.MAX_FACTS_PER_SESSION;
                    if (at_limit) {
                        log.warn("learning.max_facts_reached session={?s}", .{self.memory_session_id});
                    } else {
                        const key = learning.factKey(self.allocator, fc) catch null;
                        if (key) |k| {
                            defer self.allocator.free(k);
                            // S4.2 — durable-write silent catch closed. Learning
                            // facts are the behavioral-correction corpus; losing
                            // one silently means the agent doesn't learn from a
                            // user correction it thought it saved.
                            if (mem.store(k, fc, .core, self.memory_session_id)) |_| {
                                // D1.8: only bump counter on confirmed-stored.
                                // If the store fails, the count must NOT advance
                                // or we'd silently exceed MAX_FACTS_PER_SESSION
                                // on subsequent turns when the prior write didn't
                                // actually land.
                                if (self.learning_fact_count) |*c| c.* += 1;
                            } else |err| {
                                log.warn("learning.fact_store_failed key={s} err={s}", .{ k, @errorName(err) });
                            }
                            log.info("learning.signal_detected signals={d} key={s}", .{ signals.len, k });
                        }
                    }
                }
            }
        }

        if (self.compact_context_enabled) {
            // iter32: reset per-turn flag only. The previous "turn_compaction"
            // stage event was a pre-flight heartbeat with duration_ms=0 — the
            // frontend showed "Trimming context" on EVERY turn because the
            // label fired regardless of whether any compaction actually ran.
            // Misleading UI. Real compaction emits its own events later
            // (post_reply_compaction, autoCompactHistory result recording).
            self.last_turn_compacted = false;
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
                        // v1.14.14 Phase 3 — route through ContextEngine.compact.
                        if (self.context_engine_state.compact(self).compacted) {
                            self.refreshDurableContinuityAfterCompaction();
                        }
                    }
                    self.ensureDurableContinuitySeed();
                    const cache_hit_event = ObserverEvent{ .turn_stage = .{
                        .stage = "response_cache_hit",
                        .run_id = self.current_run_id,
                    } };
                    self.observer.recordEvent(&cache_hit_event);
                    self.last_turn_context.cache_hit = true;
                    const complete_event = ObserverEvent{ .turn_complete = {} };
                    self.observer.recordEvent(&complete_event);
                    return TurnOutcome.justText(cached_hit.response);
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
                    // v1.14.14 Phase 3 — route through ContextEngine.compact.
                    if (self.context_engine_state.compact(self).compacted) {
                        self.refreshDurableContinuityAfterCompaction();
                    }
                }
                self.ensureDurableContinuitySeed();
                const cache_hit_event = ObserverEvent{ .turn_stage = .{
                    .stage = "response_cache_hit",
                    .run_id = self.current_run_id,
                } };
                self.observer.recordEvent(&cache_hit_event);
                self.last_turn_context.cache_hit = true;
                const complete_event = ObserverEvent{ .turn_complete = {} };
                self.observer.recordEvent(&complete_event);
                return TurnOutcome.justText(cached_response);
            }
        }

        if (self.compact_context_enabled) {
            // Run provider-backed auto-compaction against the full working
            // session so context boundaries create durable continuity objects.
            const auto_compact_start_ms = std.time.milliTimestamp();
            // v1.14.14 Phase 3 — route through ContextEngine.compact.
            if (self.context_engine_state.compact(self).compacted) {
                const auto_compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - auto_compact_start_ms));
                turn_compaction_ms += auto_compact_duration_ms;
                log.info("turn.stage stage=turn_auto_compaction duration_ms={d}", .{auto_compact_duration_ms});
                const auto_compact_stage_event = ObserverEvent{ .turn_stage = .{
                    .stage = "turn_auto_compaction",
                    .duration_ms = auto_compact_duration_ms,
                    .run_id = self.current_run_id,
                } };
                self.observer.recordEvent(&auto_compact_stage_event);
            }
        }

        // Record agent event
        const start_event = ObserverEvent{ .llm_request = .{
            .provider = self.provider.getName(),
            .model = self.model_name,
            .messages_count = self.history.items.len,
            .run_id = self.current_run_id,
        } };
        self.observer.recordEvent(&start_event);

        // Tool call loop — reuse a single arena across iterations (retains pages)
        var iter_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer iter_arena.deinit();

        // V1.7-cherrypick fix (CR-WIP-03): reset `last_executed_tool` at the
        // start of every turn. The field is assigned via `self.last_executed_tool
        // = call.name;` (line ~1981), where `call.name` is allocated in this
        // iter_arena and freed on the defer above. Without this reset, turn
        // N+1's cancellation print at lines ~2975-2976 reads freed memory if
        // cancellation fires before any tool runs in N+1.
        self.last_executed_tool = "";

        var iteration: u32 = 0;
        var forced_follow_through_count: u32 = 0;
        // v1.14.18-B G11: one-shot guard for the stuck→recall escalation.
        var stuck_escalation_count: u32 = 0;
        while (iteration < self.max_tool_iterations) : (iteration += 1) {
            _ = iter_arena.reset(.retain_capacity);
            const arena = iter_arena.allocator();

            // v1.14.18-B G3 — stamp the iteration counter onto the
            // NarrationObserver so any frames emitted during this
            // iteration carry the right `iteration` field in the
            // ring buffer (so `<recent_thoughts>` shows correct iter
            // numbers next turn). Bumping by 1 (vs `iteration` raw)
            // keeps the displayed value 1-based for humans.
            self.iteration_counter +%= 1;
            if (wrap_narration) {
                narration_observer.current_iteration = self.iteration_counter;
            }

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
                const cancel_text = if (self.last_executed_tool.len > 0)
                    try std.fmt.allocPrint(self.allocator, "[Cancelled: last tool was {s}]", .{self.last_executed_tool})
                else
                    try self.allocator.dupe(u8, "[Cancelled]");
                return TurnOutcome{
                    .text = cancel_text,
                    .iterations_used = iteration,
                };
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
                .run_id = self.current_run_id,
            } };
            self.observer.recordEvent(&build_stage_event);

            // Vision routing. When a turn carries image content, the model
            // that handles it must be vision-capable. A native-multimodal
            // primary (Kimi K2.6, etc. — see model_capabilities) keeps the
            // image and processes it directly: full agent context + tools,
            // one provider, no hop. Only a text-only primary is diverted to
            // the configured vision sidecar (reliability.vision_fallback).
            //
            // The capability check is a positive allowlist in
            // model_capabilities — OpenAI-compatible providers report
            // supports_vision=true for every model, so a provider-level gate
            // is useless. An unknown model is treated as text-only and routes
            // through the sidecar, so images are never silently dropped.
            var effective_model: []const u8 = self.model_name;
            if (shouldRouteToVisionFallback(
                self.model_name,
                self.vision_fallback_model,
                hasImageContentParts(messages),
            )) {
                effective_model = self.vision_fallback_model;
                log.info("turn.stage stage=vision_fallback iteration={d} from={s} to={s}", .{
                    iteration, self.model_name, self.vision_fallback_model,
                });
                const notice = ObserverEvent{ .system_notice = .{
                    .kind = "vision_fallback",
                    .severity = "info",
                    .message = "Model routed to vision-capable fallback for this turn (image attached).",
                    .detail = self.vision_fallback_model,
                    .run_id = self.current_run_id,
                } };
                self.observer.recordEvent(&notice);
            }

            // Video routing. A turn can carry video content parts (built by
            // multimodal.zig from [VIDEO:] markers). There is no video
            // sidecar, so if the effective model has no native video support
            // the video is dropped + a system_notice is emitted; a
            // video-capable model keeps it. Runs on `messages`, the slice
            // shared by the streaming and blocking provider calls below.
            try self.routeVideoForModel(arena, messages, effective_model, iteration);

            const timer_start = std.time.milliTimestamp();
            const is_streaming = self.stream_callback != null and self.provider.supportsStreaming();
            var saw_stream_first_token = false;
            var stream_timing_ctx: ?StreamTimingContext = null;
            defer if (stream_timing_ctx) |*ctx| ctx.deinit();
            turn_llm_calls += 1;

            // Call provider: streaming or blocking. Reliable wrappers may retry/fallback internally.
            var response: ChatResponse = undefined;
            if (is_streaming) {
                stream_timing_ctx = .{
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
                        .model = effective_model,
                        .temperature = self.temperature,
                        .max_tokens = self.max_tokens,
                        .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                        .timeout_secs = self.message_timeout_secs,
                        .reasoning_effort = self.reasoning_effort,
                    },
                    effective_model,
                    self.temperature,
                    streamCallbackWithTiming,
                    @ptrCast(&stream_timing_ctx.?),
                ) catch |err| retry_stream_blk: {
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
                        .run_id = self.current_run_id,
                    } };
                    self.observer.recordEvent(&fail_event);

                    // S5.3 — streaming context-exhaustion recovery parity.
                    // The blocking path (provider.chat below) already force-
                    // compresses history and re-issues the call once on
                    // ContextLengthExceeded. Long streamed sessions previously
                    // returned the raw error where the blocking counterpart
                    // would have healed. Mirror that behavior here: on
                    // context-exhausted + sufficient history, forceCompress
                    // once, rebuild the messages slice from the compacted
                    // history, and re-issue streamChat exactly once. On retry
                    // failure, propagate as before.
                    const err_name = @errorName(err);
                    if (providers.reliable.isContextExhausted(err_name) and
                        self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and
                        // v1.14.14 Phase 3 — route force-compress through ContextEngine.forceCompact.
                        self.context_engine_state.forceCompact(self).compacted)
                    {
                        log.info("turn.stage stage=stream_context_recovery iteration={d} — force-compressed and retrying stream", .{iteration});

                        // Rebuild messages after compaction — the arena is
                        // still live for this iteration, so buildProviderMessages
                        // reuses it without leaking.
                        const retry_messages = self.buildProviderMessages(arena) catch |build_err| return build_err;
                        // Rebuild re-adds video parts — re-apply video routing.
                        try self.routeVideoForModel(arena, retry_messages, effective_model, iteration);
                        const retry_result = self.provider.streamChat(
                            self.allocator,
                            .{
                                .messages = retry_messages,
                                .model = effective_model,
                                .temperature = self.temperature,
                                .max_tokens = self.max_tokens,
                                .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                                .timeout_secs = self.message_timeout_secs,
                                .reasoning_effort = self.reasoning_effort,
                            },
                            effective_model,
                            self.temperature,
                            streamCallbackWithTiming,
                            @ptrCast(&stream_timing_ctx.?),
                        ) catch |retry_err| {
                            log.warn("llm.call retry failed after stream context-recovery provider={s} model={s} error={s}", .{
                                self.provider.getName(),
                                self.model_name,
                                @errorName(retry_err),
                            });
                            return retry_err;
                        };
                        // MED-2 review fix: emit the paired `llm_response
                        // success=true` event for the retry so dashboards
                        // aggregating llm.response outcomes see the recovery.
                        // Without this, the observer stream carried only the
                        // fail_event above — retry success was invisible.
                        const retry_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
                        const retry_success_event = ObserverEvent{ .llm_response = .{
                            .provider = self.provider.getName(),
                            .model = self.model_name,
                            .duration_ms = retry_duration,
                            .success = true,
                            .error_message = null,
                            .run_id = self.current_run_id,
                        } };
                        self.observer.recordEvent(&retry_success_event);
                        break :retry_stream_blk retry_result;
                    }

                    return err;
                };
                saw_stream_first_token = stream_timing_ctx.?.first_token_recorded;
                if (stream_timing_ctx.?.first_token_ms) |value| {
                    turn_first_token_ms = value;
                }
                response = ChatResponse{
                    .content = stream_result.content,
                    .tool_calls = stream_result.tool_calls,
                    .usage = stream_result.usage,
                    .model = stream_result.model,
                    .reasoning_content = stream_result.reasoning_content,
                };

                // Binding rule: no silent fallback. If the reliable wrapper
                // tagged the result as served by a fallback provider, surface
                // a system_notice so the user sees visible degradation
                // (possibly degraded latency or capability on fallback).
                if (stream_result.used_fallback) |fallback_name| {
                    var detail_buf: [128]u8 = undefined;
                    const detail = std.fmt.bufPrint(&detail_buf, "primary failed; served by {s}", .{fallback_name}) catch fallback_name;
                    const notice_event = ObserverEvent{ .system_notice = .{
                        .kind = "provider_fallback",
                        .severity = "warning",
                        .message = "Primary model provider failed; response served by fallback. Quality or latency may differ.",
                        .detail = detail,
                        .run_id = self.current_run_id,
                    } };
                    self.observer.recordEvent(&notice_event);
                }
            } else {
                response = self.provider.chat(
                    self.allocator,
                    .{
                        .messages = messages,
                        .model = effective_model,
                        .temperature = self.temperature,
                        .max_tokens = self.max_tokens,
                        .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                        .timeout_secs = self.message_timeout_secs,
                        .reasoning_effort = self.reasoning_effort,
                    },
                    effective_model,
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
                        .run_id = self.current_run_id,
                    } };
                    self.observer.recordEvent(&fail_event);

                    // Context exhaustion: compact immediately before first retry
                    const err_name = @errorName(err);
                    if (providers.reliable.isContextExhausted(err_name) and
                        self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and
                        // v1.14.14 Phase 3 — route force-compress through ContextEngine.forceCompact.
                        self.context_engine_state.forceCompact(self).compacted)
                    {
                        turn_retry_attempts += 1;
                        turn_llm_calls += 1;
                        const recovery_msgs = self.buildProviderMessages(arena) catch |prep_err| return prep_err;
                        // Rebuild re-adds video parts — re-apply video routing.
                        try self.routeVideoForModel(arena, recovery_msgs, effective_model, iteration);
                        // effective_model (not self.model_name) — honor the
                        // turn's vision-fallback routing on the recovery call,
                        // matching the initial blocking call and streaming path.
                        break :retry_blk self.provider.chat(
                            self.allocator,
                            .{
                                .messages = recovery_msgs,
                                .model = effective_model,
                                .temperature = self.temperature,
                                .max_tokens = self.max_tokens,
                                .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                                .timeout_secs = self.message_timeout_secs,
                                .reasoning_effort = self.reasoning_effort,
                            },
                            effective_model,
                            self.temperature,
                        ) catch return err;
                    }

                    if (self.provider_reliability_active) return err;

                    // Retry once. **D1.9** — removed the previous
                    // `std.Thread.sleep(500ms)` here per
                    // `P2_agent_turn_loop.md` ugly truth #5: when the
                    // reliable provider wrapper is ACTIVE (production
                    // default) it owns all retry/backoff scheduling and
                    // we returned `err` two lines above before reaching
                    // here. When the wrapper is INACTIVE (tests, dev)
                    // the user has explicitly opted out of automated
                    // retry — a hardcoded magic 500ms blocking the
                    // session thread with no jitter / backoff
                    // contributes nothing useful. If a real backoff is
                    // ever needed on this path, the right move is
                    // exponential-with-jitter via a shared helper, not
                    // a magic-number sleep.
                    turn_retry_attempts += 1;
                    turn_llm_calls += 1;
                    // effective_model (not self.model_name) — `messages` was
                    // already vision/video-routed for effective_model above;
                    // the retry must dispatch to the same model.
                    break :retry_blk self.provider.chat(
                        self.allocator,
                        .{
                            .messages = messages,
                            .model = effective_model,
                            .temperature = self.temperature,
                            .max_tokens = self.max_tokens,
                            .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                            .timeout_secs = self.message_timeout_secs,
                            .reasoning_effort = self.reasoning_effort,
                        },
                        effective_model,
                        self.temperature,
                    ) catch |retry_err| {
                        // Context exhaustion recovery: if we have enough history,
                        // force-compress and retry once more.
                        // v1.14.14 Phase 3 — route force-compress through ContextEngine.forceCompact.
                        if (self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and
                            self.context_engine_state.forceCompact(self).compacted)
                        {
                            turn_retry_attempts += 1;
                            turn_llm_calls += 1;
                            const recovery_msgs = self.buildProviderMessages(arena) catch |prep_err| return prep_err;
                            // Rebuild re-adds video parts — re-apply video routing.
                            try self.routeVideoForModel(arena, recovery_msgs, effective_model, iteration);
                            // effective_model (not self.model_name) — honor the
                            // turn's vision-fallback routing on the recovery call.
                            break :retry_blk self.provider.chat(
                                self.allocator,
                                .{
                                    .messages = recovery_msgs,
                                    .model = effective_model,
                                    .temperature = self.temperature,
                                    .max_tokens = self.max_tokens,
                                    .tools = if (self.provider.supportsNativeTools()) self.tool_specs else null,
                                    .timeout_secs = self.message_timeout_secs,
                                    .reasoning_effort = self.reasoning_effort,
                                },
                                effective_model,
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
                .run_id = self.current_run_id,
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
                    .run_id = self.current_run_id,
                } };
                self.observer.recordEvent(&first_token_bound_event);
            }

            // Track tokens
            self.total_tokens += response.usage.total_tokens;
            self.last_turn_usage = response.usage;

            // V1.14.6 follow-up: structured cache-hit telemetry. Together
            // (vLLM), OpenRouter, and OpenAI-compat all return prompt
            // cache hit count via `usage.cached_prompt_tokens` (parsed by
            // compatible.zig — 3 wire shapes handled). Surface it here so
            // operators can grep `cache.hit` and measure F-PA2's actual
            // impact on the production path without re-running benches.
            // Format mirrors `compaction.notify` for grep-symmetry.
            const cached_tok: u64 = response.usage.cached_prompt_tokens;
            const prompt_tok: u64 = response.usage.prompt_tokens;
            const hit_pct: u8 = if (prompt_tok > 0)
                @intCast(@min(100, (cached_tok * 100) / prompt_tok))
            else
                0;
            log.info("cache.hit provider={s} model={s} prompt_tokens={d} cached_tokens={d} hit_pct={d}%", .{
                self.provider.getName(),
                if (response.model.len > 0) response.model else self.model_name,
                prompt_tok,
                cached_tok,
                hit_pct,
            });
            if (self.usage_rt) |urt| {
                const input: u64 = @intCast(response.usage.prompt_tokens);
                const output: u64 = @intCast(response.usage.completion_tokens);
                // WP5.1: consult the static provider pricing table. When
                // the model is priced, record the USD cost; when the
                // model is unknown we pass 0 and /cost reports
                // "cost unavailable" rather than inventing $0.00.
                const priced_model: []const u8 = if (response.model.len > 0) response.model else self.default_model;
                const cost_usd: f64 = providers.pricing.costFor(
                    self.default_provider,
                    priced_model,
                    input,
                    output,
                ) orelse 0.0;
                urt.recordTurn(
                    priced_model,
                    input,
                    output,
                    cost_usd,
                    0, // Duration refined when timing context available
                );
            }

            const raw_response_text = response.contentOrEmpty();
            var response_text = raw_response_text;
            if (!task_plan_checked) {
                task_plan_checked = true;
                const extracted_plan = task_planner.extractTextAndPlan(raw_response_text);
                if (extracted_plan.plan_xml) |plan_xml| {
                    if (try task_planner.parseTaskPlan(self.allocator, plan_xml)) |parsed_plan| {
                        // v1.14.18-A G4 — replace the retained plan: free the
                        // prior turn's plan before storing this turn's.
                        if (self.active_task_plan) |*old_plan| old_plan.deinit(self.allocator);
                        self.active_task_plan = parsed_plan;
                        if (extracted_plan.text.len > 0 and extracted_plan.text_after.len > 0) {
                            response_text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ extracted_plan.text, extracted_plan.text_after });
                        } else if (extracted_plan.text_after.len > 0) {
                            response_text = extracted_plan.text_after;
                        } else {
                            response_text = extracted_plan.text;
                        }
                    }
                }
            }
            const use_native = response.hasToolCalls();

            // ── Native reasoning_content: kept for model's own context; NOT emitted as narration ──
            // The model's raw reasoning_content remains available downstream
            // (compose_final_reply, history, post-turn summarizer) so the agent
            // keeps its own chain of thought. User-facing narration is now
            // owned exclusively by the sidecar narrator (see
            // narration_thinking_sidecar block below). This avoids two
            // competing narration voices and puts the user's experience in
            // the hands of a smaller, consistent first-person narrator rather
            // than whatever raw shape the main model emits this turn.
            //
            // If you need to restore raw-CoT as narration for diagnostics,
            // emit a narration_frame .thinking here — but expect dedup
            // collisions and voice inconsistency with the sidecar.

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

                // Build history with the STRIPPED text when XML fallback ran — otherwise
                // the raw `<invoke>`/`<tool_call>` XML ends up in assistant history and
                // the model sees its own previous XML emissions on the next turn,
                // reinforcing the fallback pattern until /reset. Use response_text only
                // when no stripping happened (native tool_calls, no XML found).
                const history_text = if (free_parsed_text and parsed_text.len > 0) parsed_text else response_text;
                assistant_history_content = try dispatcher.buildAssistantHistoryWithToolCalls(
                    self.allocator,
                    history_text,
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
                    .run_id = self.current_run_id,
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
                // If parseToolCalls extracted calls (either <tool_call> or
                // <invoke> format), use the STRIPPED text for history so the
                // model doesn't see its own raw XML emissions on subsequent
                // turns — otherwise a single XML-mode turn poisons history
                // and every subsequent turn keeps emitting XML until /reset.
                // When no calls were extracted, keep the full response_text
                // (it's just prose, nothing to strip).
                assistant_history_content = if (parsed_calls.len > 0 and parsed_text.len > 0)
                    parsed_text
                else
                    response_text;
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
                    .run_id = self.current_run_id,
                } };
                self.observer.recordEvent(&parse_stage_event);
            }

            // Determine display text
            const display_text = if (parsed_text.len > 0) parsed_text else response_text;

            // v1.14.18-A F3: Parse goal-loop reflection from LLM response
            // Update active goal state before continuing with tool dispatch
            var should_exit_goal_loop = false;
            // v1.14.18-B G11: set when the model self-reports `stuck`, so the
            // break site can escalate to memory recall before giving up.
            var escalate_on_stuck = false;
            if (self.active_goal_state) |*goal_state| {
                const goal_reflection_verdict = goal_loop.parseReflection(display_text);
                goal_state.status = goal_reflection_verdict;
                goal_state.iteration_count += 1;

                // Mark exit if goal is met or stuck (will break after tool results processed)
                if (goal_reflection_verdict == .met or goal_reflection_verdict == .stuck) {
                    log.info("turn.goal_loop iteration={d} status={s} — will exit after tools", .{
                        goal_state.iteration_count,
                        @tagName(goal_reflection_verdict),
                    });
                    should_exit_goal_loop = true;
                }
                // v1.14.18-B G11 (BRAIN_GRAPH ESCALATION): a `stuck` verdict
                // is not a clean exit — the agent is frequently just missing
                // context that already exists in memory. Flag it so the
                // break site escalates to memory_recall/brain_graph once
                // before the loop actually exits.
                if (goal_reflection_verdict == .stuck) {
                    escalate_on_stuck = true;
                }

                // v1.14.18-B G5: Capture iteration learning to reflection trail
                const learning_summary = try std.fmt.allocPrint(self.allocator, "{d} tool calls processed", .{parsed_calls.len});
                defer self.allocator.free(learning_summary);
                const first_tool_name: ?[]const u8 = if (parsed_calls.len > 0) parsed_calls[0].name else null;
                active_reflection_trail.append(
                    self.allocator,
                    goal_state.iteration_count - 1, // iteration 0-indexed
                    first_tool_name,
                    @tagName(goal_reflection_verdict),
                    learning_summary,
                ) catch |err| {
                    log.warn("reflection_trail.append failed: {s}", .{@errorName(err)});
                };
            }
            if (parsed_calls.len > 0) {
                turn_tool_iterations += 1;
                turn_tool_calls_total += @intCast(@min(parsed_calls.len, std.math.maxInt(u32)));
                self.recordSessionToolNames(parsed_calls);
            }

            if (parsed_calls.len == 0) {
                const malformed_tool_markup = startsWithToolCallMarkup(display_text);
                // Guardrail: if the model promises "I'll try/check now" but emits no
                // tool call, force one follow-up completion to either act now or
                // explicitly state the limitation without deferred promises.
                if (forced_follow_through_count < 2 and
                    iteration + 1 < self.max_tool_iterations and
                    (shouldForceActionFollowThrough(display_text) or malformed_tool_markup))
                {
                    const follow_up_instruction = if (malformed_tool_markup)
                        "SYSTEM: Your previous response started with <tool_call> markup but no valid tool call was executed. " ++
                            "Emit valid, closed <tool_call>...</tool_call> tags now for each tool action. " ++
                            "If no tool is needed, answer in plain text with no <tool_call> tags."
                    else
                        "SYSTEM: You just promised or claimed that you were taking action now " ++
                            "(for example: \"I'll check now\" or \"Executing web search...\"). " ++
                            "Do it in this turn by issuing the appropriate tool call(s). " ++
                            "If no tool can perform it, respond with a clear limitation now and do not promise or imply that work has started.";
                    try self.history.append(self.allocator, .{
                        .role = .assistant,
                        .content = try self.allocator.dupe(u8, display_text),
                    });
                    try self.history.append(self.allocator, .{
                        .role = .user,
                        .content = try self.allocator.dupe(u8, follow_up_instruction),
                    });
                    if (self.compact_context_enabled) {
                        // v1.14.14 Phase 3 — route through ContextEngine.compact.
                        _ = self.context_engine_state.compact(self);
                    }
                    self.freeResponseFields(&response);
                    forced_follow_through_count += 1;
                    continue;
                }

                // No tool calls — final response.
                //
                // Defensive scrub: strip any residual `<tool_call>...</tool_call>`
                // blocks or stray fragments (`tool_call>`, `ool_call>`) that
                // slipped past the streaming hold path. The leak QA T6 found
                // (mid-stream markup landing in the streamed `final_reply`
                // tokens) lives here — flushValidatedReply emits `final_text`
                // verbatim and `final_text` is built from `display_text`, so
                // sanitising display_text before composeFinalReply is the
                // right belt-and-suspenders boundary.
                //
                // The malformed-startup case still routes through the existing
                // safe-text replacement (a clean error message, not the raw
                // markup), so we keep that branch untouched.
                const scrubbed_display_text: []u8 = stripToolCallMarkup(self.allocator, display_text);
                defer if (scrubbed_display_text.ptr != display_text.ptr) self.allocator.free(scrubbed_display_text);

                const safe_display_text = if (malformed_tool_markup)
                    "I hit an internal tool-call formatting error before execution. Please retry."
                else
                    scrubbed_display_text;
                const finalize_start_ms = std.time.milliTimestamp();
                const base_text = if (self.context_was_compacted) blk: {
                    const was_force = self.context_force_compressed;
                    self.context_was_compacted = false;
                    self.context_force_compressed = false;

                    // Emit a system_notice alongside the inline prefix so the
                    // frontend can render a distinct chrome notice (not buried
                    // in reply text). Binding rule: no silent fallback.
                    const notice_event = ObserverEvent{ .system_notice = .{
                        .kind = "compaction",
                        .severity = if (was_force) "warning" else "info",
                        .message = if (was_force)
                            "Older messages were dropped to fit the context window. Some history may be inaccessible."
                        else
                            "Context was compacted to stay within the window. Durable continuity was preserved via memory.",
                        .run_id = self.current_run_id,
                    } };
                    self.observer.recordEvent(&notice_event);

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
                    .run_id = self.current_run_id,
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
                        .run_id = self.current_run_id,
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

                // Dupe from display_text directly (not from final_text) to avoid double-dupe.
                // Carry the model's native reasoning_content so Moonshot's
                // `thinking.keep:"all"` can replay it on the next turn.
                {
                    const hist_content = try self.allocator.dupe(u8, safe_display_text);
                    errdefer self.allocator.free(hist_content);
                    const hist_reasoning: ?[]const u8 = if (response.reasoning_content) |rc|
                        if (rc.len > 0) try self.allocator.dupe(u8, rc) else null
                    else
                        null;
                    errdefer if (hist_reasoning) |r| self.allocator.free(r);
                    try self.history.append(self.allocator, .{
                        .role = .assistant,
                        .content = hist_content,
                        .reasoning = hist_reasoning,
                    });
                }

                const compact_start_ms = std.time.milliTimestamp();
                if (self.compact_context_enabled and !self.last_turn_compacted) {
                    // v1.14.14 Phase 3 — route through ContextEngine.compact.
                    _ = self.context_engine_state.compact(self);
                }
                const compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - compact_start_ms));
                log.info("turn.stage stage=post_reply_compaction iteration={d} duration_ms={d} compacted={}", .{
                    iteration,
                    compact_duration_ms,
                    self.last_turn_compacted,
                });
                // iter34: only emit the observer event (which the frontend
                // turns into "Compacting context window") when compaction
                // actually ran. Previously this fired every turn regardless
                // of whether any work happened, giving the user a phantom
                // "compacting" UI flicker on every reply.
                if (self.last_turn_compacted) {
                    const compact_stage_event = ObserverEvent{ .turn_stage = .{
                        .stage = "post_reply_compaction",
                        .iteration = iteration,
                        .duration_ms = compact_duration_ms,
                        .run_id = self.current_run_id,
                    } };
                    self.observer.recordEvent(&compact_stage_event);
                }

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
                                // Vector sync after auto-save (fire-and-forget
                                // — see user-message autosave above).
                                if (self.mem_rt) |rt| {
                                    _ = rt.syncVectorAfterStore(self.allocator, key, visible_reply);
                                }
                            } else |err| {
                                // S4.3 — durable-write silent catch closed. Assistant
                                // autosave is the cold-transcript tier for the agent's
                                // own replies. Losing one silently means the visible
                                // reply reached the user but was never recorded; /memory
                                // list would omit it without trace.
                                log.warn("autosave.assistant_failed key={s} err={s}", .{ key, @errorName(err) });
                            }
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

                // D1.4 — when the model produced tool/spawn calls but no
                // post-tool assistant text, emit a structured tool_only_turn
                // event so the gateway can render a real frame instead of
                // falling back to EMPTY_TURN_PLACEHOLDER. Detection: tools
                // ran in prior iterations (turn_tool_calls_total > 0) AND
                // the final text is empty. Must fire BEFORE turn_complete
                // so SSE consumers see them in causal order.
                // D1.7: now includes spawned_task_ids — the actual numeric
                // IDs the spawn tool emitted, not just a count. Borrowed
                // view; event handlers don't take ownership.
                if (final_text.len == 0 and turn_tool_calls_total > 0) {
                    const tool_only_event = ObserverEvent{ .tool_only_turn = .{
                        .tool_calls_executed = turn_tool_calls_total,
                        .spawned_task_ids = spawned_task_ids_acc.items,
                        .iterations_used = turn_tool_iterations,
                        .run_id = self.current_run_id,
                    } };
                    self.observer.recordEvent(&tool_only_event);
                }

                // ── Hermes-inspired post-turn maintenance ──
                //
                // **D1.11** — these history writes (memory_nudge,
                // skills_extraction) used to live AFTER turn_complete was
                // emitted. P2_agent_turn_loop.md ugly truth #11:
                // "the added messages sit in history for the next turn
                // but never generate a visible event for this turn."
                // Moved before turn_complete + each gets its own
                // turn_stage event so observers (dashboards, SSE
                // consumers, debug tooling) can see when these prompts
                // are injected — previously they appeared as silent
                // history mutations on the next turn.

                // Track tool usage for skills extraction
                self.last_turn_tool_count = turn_tool_calls_total;

                // V1.14.7 C3 — memory_nudge SITE DELETED.
                //
                // The legacy every-10-turn memory_nudge that injected a SYSTEM
                // message asking the agent to evaluate what to memory_store
                // has been removed. Replaced by:
                //   - Agent-explicit memory_store calls (the agent is the best
                //     judge of what to persist; system prompt R14 covers the
                //     "remember this" verbal-commitment rule)
                //   - Inline structured extraction at compaction (Pass A, Pass C)
                //     and at session end via persistSessionCheckpoint
                //
                // The `turns_since_memory_nudge` counter is retained on Agent
                // for forward compat (any external observer that sampled it
                // continues to see a static 0). Reference: ExtractionConfig
                // docs in config_types.zig.

                // V1.14.7 C3 — per-turn entity_pipeline_enqueue SITE DELETED.
                //
                // The legacy V1.12 every-3-turn enqueue that wrote
                // wiki_link extraction jobs to extraction_queue has been
                // removed. The same edges now land via:
                //   - Pass A drop-window extraction (compaction.zig
                //     extractFromDropWindow, V1.14.7 C2)
                //   - Pass C summary JSON tail (existing V1.6 5b.2 path)
                //   - Inline session-end persistExtracted (commands.zig:1437,
                //     existing V1.9-6 path)
                //
                // The `turns_since_extraction` counter is retained on Agent for
                // forward compat (external observers that sampled it continue
                // to see a static 0). Reference: ExtractionConfig docs in
                // config_types.zig.

                // V1.14.7 C3 — skills_extraction nudge SITE DELETED.
                //
                // The legacy after-≥5-tool-calls nudge that prompted the agent
                // to consider saving a SKILL.md has been removed. Reference
                // agents (Claude Code, Hermes) don't auto-prompt for skills
                // extraction either — when the user wants a procedure saved
                // they ask explicitly, or the agent recognises a clear pattern
                // and proposes it organically. The nudge generated low-value
                // SKILL.md files for one-off task sequences.
                // **D1.11** — turn_complete now fires LAST, after all
                // post-turn maintenance writes have been recorded as
                // visible turn_stage events. Pre-D1.11 turn_complete
                // fired before the maintenance writes so dashboards
                // saw "turn done" while history was still mutating.
                // Maintenance write failures are logged but do NOT skip
                // turn_complete — see the inline catch handlers above.
                const complete_event = ObserverEvent{ .turn_complete = {} };
                self.observer.recordEvent(&complete_event);

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
                    .run_id = self.current_run_id,
                } };
                self.observer.recordEvent(&finalize_stage_event);

                if (tts_audio_reply_text) |audio_reply| {
                    if (stream_timing_ctx) |*ctx| {
                        ctx.flushValidatedReply(audio_reply);
                    }
                    self.allocator.free(final_text);
                    // **D1.7 finding 2 fix (2026-04-26):** mark transferred AFTER
                    // toOwnedSlice succeeds, not before. On success the
                    // accumulator items[] is empty (toOwnedSlice transferred
                    // ownership); on failure items[] still owns the duped
                    // task_id strings — we MUST leave transferred=false so
                    // the defer cleanup frees them. Pre-fix the
                    // `transferred = true` line ran before the catch, so
                    // an OOM at toOwnedSlice would skip cleanup AND return
                    // empty IDs — leaking every duped string.
                    const ids = spawned_task_ids_acc.toOwnedSlice(self.allocator) catch &.{};
                    spawned_task_ids_transferred = (spawned_task_ids_acc.items.len == 0);
                    return TurnOutcome{
                        .text = audio_reply,
                        .tool_only_turn = false,
                        .spawned_task_ids = ids,
                        .iterations_used = turn_tool_iterations,
                    };
                }
                if (stream_timing_ctx) |*ctx| {
                    ctx.flushValidatedReply(final_text);
                }
                // **D1.7 finding 2 fix (2026-04-26):** mark transferred AFTER
                // toOwnedSlice succeeds. See the longer comment at the audio_reply
                // path. Pre-fix would leak duped task_id strings on OOM.
                const ids = spawned_task_ids_acc.toOwnedSlice(self.allocator) catch &.{};
                spawned_task_ids_transferred = (spawned_task_ids_acc.items.len == 0);
                return TurnOutcome{
                    .text = final_text,
                    .tool_only_turn = (final_text.len == 0 and turn_tool_calls_total > 0),
                    .spawned_task_ids = ids,
                    .iterations_used = turn_tool_iterations,
                };
            }

            // ── Adaptive exit: repeated-call detector ─────────────────────
            //
            // **D1.10** — moved BEFORE the assistant-history append +
            // tool execution. Pre-D1.10 this fired AFTER the assistant
            // append + history write + tool execution: the iteration
            // did all the wasted work and exited via the next
            // iteration's top-of-loop check. Per
            // P2_agent_turn_loop.md ugly truth #6 the work was waste.
            //
            // The Anthropic-compat concern (assistant tool_use without
            // paired tool_result errors the provider) is addressed by
            // EXITING BEFORE the assistant message is appended at
            // all — so history stays clean for the exhausted-iter
            // summary call. The model's looped response is dropped
            // from the conversation transcript; the summary prompt
            // ("SYSTEM: You have reached the maximum number of tool
            // iterations…") provides sufficient context for the
            // wrap-up call to succeed.
            //
            // Hash this iteration's tool call set. If the same hash
            // has appeared in every slot of the ring buffer
            // (LOOP_WINDOW consecutive iterations), we're looping —
            // free response, break.
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
                    if (hv != call_set_hash) {
                        all_same = false;
                        break;
                    }
                }
                if (all_same) {
                    loop_detected = true;
                    log.warn("agent.loop_detected iteration={d} hash={x} — same tool_call set repeated {d}x, EARLY EXIT (D1.10)", .{
                        iteration,
                        call_set_hash,
                        LOOP_WINDOW,
                    });
                    self.freeResponseFields(&response);
                    // assistant_history_content / parsed_calls / parsed_text
                    // get freed by the iteration-body defer (the
                    // free_* flags were set during parsing earlier).
                    break;
                }
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

            // Carry the model's native reasoning_content so Moonshot's
            // `thinking.keep:"all"` can replay it on the next turn.
            const assistant_reasoning: ?[]const u8 = if (response.reasoning_content) |rc|
                if (rc.len > 0) try self.allocator.dupe(u8, rc) else null
            else
                null;
            errdefer if (assistant_reasoning) |r| self.allocator.free(r);

            try self.history.append(self.allocator, .{
                .role = .assistant,
                .content = assistant_content,
                .reasoning = assistant_reasoning,
            });

            // Execute tool calls (serial by default, optional parallel dispatcher)
            var results_buf: std.ArrayListUnmanaged(ToolExecutionResult) = .empty;
            defer results_buf.deinit(self.allocator);
            try results_buf.ensureTotalCapacity(self.allocator, parsed_calls.len);
            if (self.active_task_plan) |*plan| {
                for (parsed_calls, 0..) |call, call_idx| {
                    const plan_index = plan.current_step + @as(u32, @intCast(call_idx));
                    task_planner.emitStepProgress(self.observer, plan, plan_index, call.name);
                }
            }
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

            if (self.active_task_plan) |*plan| {
                for (results_buf.items) |result| {
                    if (plan.current_step >= plan.steps.len) break;
                    const step_index = plan.current_step;
                    if (plan.currentStep()) |step| {
                        step.tool_used = result.name;
                    }
                    if (result.success) {
                        plan.markStepDone("completed");
                    } else {
                        plan.markStepFailed();
                    }
                    task_planner.emitStepDone(self.observer, plan, step_index, result.success);
                    plan.advanceStep();
                }
                if (!task_plan_complete_emitted and plan.isComplete()) {
                    task_planner.emitPlanComplete(self.observer, plan);
                    task_plan_complete_emitted = true;
                }
            }

            // **D1.7** — capture spawned task_ids from any `spawn` tool
            // calls in this iteration's results. Spawn's result format
            // is "Subagent '<label>' spawned with task_id=<N> state=
            // queued. ..." (`src/tools/spawn.zig:62-66`). We parse the
            // numeric task_id and accumulate it for the TurnOutcome.
            // `delegate` is intentionally excluded — it runs synchronously
            // and inlines its result, so there's no async task to track.
            // `schedule` similarly creates a cron entry, not a subagent
            // task — its IDs would belong in a separate channel if ever
            // needed.
            for (results_buf.items, 0..) |result, idx| {
                if (idx >= parsed_calls.len) break;
                if (!std.mem.eql(u8, parsed_calls[idx].name, "spawn")) continue;
                if (!result.success) continue;
                const marker = "task_id=";
                const start = std.mem.indexOf(u8, result.output, marker) orelse continue;
                const num_start = start + marker.len;
                var num_end = num_start;
                while (num_end < result.output.len and std.ascii.isDigit(result.output[num_end])) num_end += 1;
                if (num_end == num_start) continue;
                const task_id_str = self.allocator.dupe(u8, result.output[num_start..num_end]) catch |err| {
                    log.warn("D1.7.spawn_task_id_capture_failed err={s}", .{@errorName(err)});
                    continue;
                };
                spawned_task_ids_acc.append(self.allocator, task_id_str) catch |err| {
                    log.warn("D1.7.spawn_task_id_append_failed err={s}", .{@errorName(err)});
                    self.allocator.free(task_id_str);
                };
            }

            if (self.pending_tool_approval) |pending| {
                try self.appendPendingApprovalToolHistory(arena, results_buf.items);
                const approval_text = try std.fmt.allocPrint(
                    self.allocator,
                    "Approval required for tool {s} (id={d}, risk={s}, reason={s}). Use /approve {d} allow-once|deny",
                    .{
                        pending.tool_name,
                        pending.id,
                        pending.risk_level.toSlice(),
                        pending.reason,
                        pending.id,
                    },
                );
                errdefer self.allocator.free(approval_text);

                try self.history.append(self.allocator, .{
                    .role = .assistant,
                    .content = try self.allocator.dupe(u8, approval_text),
                });

                self.freeResponseFields(&response);
                // **D1.7 finding 2 fix (2026-04-26):** mark transferred AFTER
                // toOwnedSlice succeeds. See the longer comment at the audio_reply
                // path. Pre-fix would leak duped task_id strings on OOM.
                const ids = spawned_task_ids_acc.toOwnedSlice(self.allocator) catch &.{};
                spawned_task_ids_transferred = (spawned_task_ids_acc.items.len == 0);
                return TurnOutcome{
                    .text = approval_text,
                    .spawned_task_ids = ids,
                    .iterations_used = turn_tool_iterations,
                };
            }

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

            // v1.14.18-A F3: Inject goal-loop reflection prompt for next iteration
            // This SYSTEM message teaches the model to emit <reflection goal_status="...">
            if (iteration > 0 and self.active_goal_state != null) {
                var last_tool_name: ?[]const u8 = null;
                var last_result_summary: ?[]const u8 = null;

                if (results_buf.items.len > 0) {
                    const last_result = results_buf.items[results_buf.items.len - 1];
                    last_tool_name = last_result.name;
                    // Truncate result to ~400 chars for context
                    const result_len = @min(last_result.output.len, 400);
                    last_result_summary = last_result.output[0..result_len];
                }

                const goal_reflection_prompt = try goal_loop.buildReflectionPrompt(
                    self.allocator,
                    self.active_goal_state.?.goal_text,
                    @intCast(iteration + 1),
                    last_tool_name,
                    last_result_summary,
                );
                defer self.allocator.free(goal_reflection_prompt);

                try self.history.append(self.allocator, .{
                    .role = .system,
                    .content = try self.allocator.dupe(u8, goal_reflection_prompt),
                });
            }

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
                .run_id = self.current_run_id,
            } };
            self.observer.recordEvent(&reflect_stage_event);

            // ── Thinking narration (sidecar-owned, after every tool burst) ──
            // Sidecar is the single source of user-facing narration. It fires
            // after every tool_reflection that produced at least one tool
            // result — one first-person line between tool bursts, Codex-style.
            // Native reasoning_content is preserved in the main model's
            // context but intentionally NOT shown to the user (see the
            // response-parse site above).
            // `narration_interval == 0` still disables narration entirely
            // (kept as a kill switch); any non-zero value means "every burst".
            // v1.14.x NATIVE-COT-NARRATION — the `.thinking` narration frame
            // (which feeds both the UX and, via the ring buffer, the agent's
            // own `<recent_thoughts>`) is sourced from the model's OWN native
            // reasoning / chain-of-thought, not a sidecar ghostwriter.
            //
            // When the model emitted reasoning this iteration (Kimi K2.6 does,
            // every non-trivial turn — live-probed 2026-05-21), emit it
            // directly. The sidecar — a separate cheap LLM that confabulates a
            // first-person narration from the transcript — is now the
            // FALLBACK ONLY: for non-thinking models, or iterations that
            // produced no native reasoning. Either/or, native preferred
            // (per Nova). This is also the §14.7 honesty fix for G3: the
            // agent's `<recent_thoughts>` is now genuinely its own reasoning.
            const native_cot: ?[]const u8 = if (response.reasoning_content) |rc|
                (if (rc.len > 0) rc else null)
            else
                null;
            if (native_cot) |cot| {
                const thinking_event = ObserverEvent{ .narration_frame = .{
                    .message = cot,
                    .frame_type = .thinking,
                } };
                self.observer.recordEvent(&thinking_event);
                log.info("turn.stage stage=narration_native_cot iteration={d} len={d}", .{ iteration, cot.len });
            } else if (self.sidecar_provider != null and self.narration_interval > 0 and
                turn_tool_iterations >= 1 and results_buf.items.len > 0)
            {
                // Fallback: the model emitted no native reasoning this turn.
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
                    log.info("turn.stage stage=narration_sidecar_fallback iteration={d} len={d}", .{ iteration, thinking_text.len });
                }
            } else {
                log.info("narration.skipped reason=no_native_cot_no_sidecar iteration={d}", .{iteration});
            }

            const compact_start_ms = std.time.milliTimestamp();
            if (self.compact_context_enabled) {
                // v1.14.14 Phase 3 — route through ContextEngine.compact. The
                // wrapper preserves variant D's "only set last_turn_compacted
                // to true on success" semantics (compact() never clobbers a
                // prior true to false).
                _ = self.context_engine_state.compact(self);
            }
            const compact_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - compact_start_ms));
            log.info("turn.stage stage=history_maintenance_after_tools iteration={d} duration_ms={d}", .{ iteration, compact_duration_ms });
            const compact_stage_event = ObserverEvent{ .turn_stage = .{
                .stage = "history_maintenance_after_tools",
                .iteration = iteration,
                .duration_ms = compact_duration_ms,
                .run_id = self.current_run_id,
            } };
            self.observer.recordEvent(&compact_stage_event);

            // v1.14.18-B G11 (BRAIN_GRAPH ESCALATION): before exiting on a
            // `stuck` verdict, escalate ONCE — inject a SYSTEM directive to
            // call memory_recall (and brain_graph if relational lookup
            // helps) and continue the loop. An agent that self-reports stuck
            // is frequently missing context already in memory; this turns a
            // dead-end into a recall attempt. One-shot via
            // stuck_escalation_count, so a still-stuck verdict on the next
            // iteration falls through to the normal exit — no infinite loop.
            // The assistant message + tool results for this iteration are
            // already in history (post-dispatch), so only the directive is
            // appended.
            if (shouldEscalateOnStuck(escalate_on_stuck, stuck_escalation_count, iteration, self.max_tool_iterations)) {
                const recall_directive =
                    "SYSTEM: You reported being stuck. Before concluding, you are " ++
                    "likely missing context that already exists in memory. Issue a " ++
                    "`memory_recall` tool call now with a query derived from the " ++
                    "current goal — and if structured/relational lookup would help, " ++
                    "also call `brain_graph`. Use what recall returns to make " ++
                    "progress. If recall genuinely surfaces nothing useful, then " ++
                    "state your conclusion plainly.";
                try self.history.append(self.allocator, .{
                    .role = .user,
                    .content = try self.allocator.dupe(u8, recall_directive),
                });
                log.info("turn.goal_loop stuck-escalation iteration={d} — injected recall directive", .{iteration});
                stuck_escalation_count += 1;
                self.freeResponseFields(&response);
                continue;
            }

            // v1.14.18-A F3: Exit goal loop if goal is met or stuck
            if (should_exit_goal_loop) {
                log.info("turn.goal_loop exiting loop at iteration={d}", .{iteration});
                break;
            }

            // Free provider response fields now that all borrows are consumed.
            self.freeResponseFields(&response);
        }

        // ── Graceful degradation: tool iterations exhausted OR loop detected ──
        //
        // S5.8 — two distinct exit causes land in the same fallback path.
        // The observer event + the log + the user-visible return prefix
        // (below) now differentiate them so operators can tell "model ran
        // out of iterations" from "loop guard tripped early on a repeated
        // tool pattern". Both paths still go through the summary-request
        // flow — the divergence is only in the reported reason.
        if (loop_detected) {
            const loop_event = ObserverEvent{ .loop_detected = .{ .iteration = turn_tool_iterations, .iterations_cap = self.max_tool_iterations } };
            self.observer.recordEvent(&loop_event);
            log.warn("Tool loop detected at iteration {d}/{d} — requesting summary", .{ turn_tool_iterations, self.max_tool_iterations });
        } else {
            const exhausted_event = ObserverEvent{ .tool_iterations_exhausted = .{ .iterations = self.max_tool_iterations } };
            self.observer.recordEvent(&exhausted_event);
            log.warn("Tool iterations exhausted ({d}/{d}), requesting summary", .{ self.max_tool_iterations, self.max_tool_iterations });
        }

        // Append a pseudo-user message forcing a text-only summary
        try self.history.append(self.allocator, .{
            .role = .user,
            .content = try self.allocator.dupe(u8, "SYSTEM: You have reached the maximum number of tool iterations. " ++
                "You MUST NOT call any more tools. Summarize what you have accomplished " ++
                "so far and what remains to be done. Respond in the same language the user used."),
        });

        // Build messages for the summary call.
        //
        // S5.8 — return-prefix distinguishes loop-detected from iterations-
        // exhausted to match the observer event emitted above. Users see
        // "[Tool loop detected at N/N]" vs "[Tool iteration limit: N/N]"
        // and can report accurately which failure mode fired. `{d}/{d}` in
        // the loop-detected prefix shows the iteration the loop tripped at
        // vs the cap, whereas the exhausted prefix uses cap/cap.
        const summary_messages = self.buildMessageSlice() catch {
            const fallback = if (loop_detected)
                try std.fmt.allocPrint(self.allocator, "[Tool loop detected at {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ turn_tool_iterations, self.max_tool_iterations })
            else
                try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ self.max_tool_iterations, self.max_tool_iterations });
            const complete_event = ObserverEvent{ .turn_complete = {} };
            self.observer.recordEvent(&complete_event);
            // **D1.7 finding 2 fix (2026-04-26):** mark transferred AFTER
            // toOwnedSlice succeeds. See longer comment at the audio_reply path.
            const ids = spawned_task_ids_acc.toOwnedSlice(self.allocator) catch &.{};
            spawned_task_ids_transferred = (spawned_task_ids_acc.items.len == 0);
            return TurnOutcome{
                .text = fallback,
                .spawned_task_ids = ids,
                .iterations_used = turn_tool_iterations,
                .loop_detected = loop_detected,
            };
        };
        defer self.allocator.free(summary_messages);

        // **D1.12** — honor vision-fallback consistency for the
        // exhausted-iter summary call. P2_agent_turn_loop.md ugly
        // truth #10: this site previously hardcoded `self.model_name`
        // even when the per-iteration provider calls had been routed
        // to `self.vision_fallback_model` because the messages
        // contained images. The summary inherits the same message
        // history (with image parts intact), so we must inherit the
        // same model selection or risk the non-vision main model
        // failing on the image content. Pre-D1.12, an exhausted-iter
        // turn that had been running on vision-fallback would summarize
        // via the wrong model — likely hallucinating or erroring.
        const summary_model: []const u8 = blk: {
            if (shouldRouteToVisionFallback(
                self.model_name,
                self.vision_fallback_model,
                hasImageContentParts(summary_messages),
            )) {
                break :blk self.vision_fallback_model;
            }
            break :blk self.model_name;
        };

        var summary_response = self.provider.chat(
            self.allocator,
            .{
                .messages = summary_messages,
                .model = summary_model,
                .temperature = self.temperature,
                .max_tokens = self.max_tokens,
                .tools = null, // force text-only
                .timeout_secs = self.message_timeout_secs,
                .reasoning_effort = self.reasoning_effort,
            },
            summary_model,
            self.temperature,
        ) catch {
            const fallback = if (loop_detected)
                try std.fmt.allocPrint(self.allocator, "[Tool loop detected at {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ turn_tool_iterations, self.max_tool_iterations })
            else
                try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ self.max_tool_iterations, self.max_tool_iterations });
            const complete_event = ObserverEvent{ .turn_complete = {} };
            self.observer.recordEvent(&complete_event);
            // **D1.7 finding 2 fix (2026-04-26):** mark transferred AFTER
            // toOwnedSlice succeeds. See longer comment at the audio_reply path.
            const ids = spawned_task_ids_acc.toOwnedSlice(self.allocator) catch &.{};
            spawned_task_ids_transferred = (spawned_task_ids_acc.items.len == 0);
            return TurnOutcome{
                .text = fallback,
                .spawned_task_ids = ids,
                .iterations_used = turn_tool_iterations,
                .loop_detected = loop_detected,
            };
        };
        defer self.freeResponseFields(&summary_response);

        const summary_text = summary_response.contentOrEmpty();
        const prefixed = if (loop_detected)
            try std.fmt.allocPrint(self.allocator, "[Tool loop detected at {d}/{d}]\n\n{s}", .{ turn_tool_iterations, self.max_tool_iterations, summary_text })
        else
            try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}]\n\n{s}", .{ self.max_tool_iterations, self.max_tool_iterations, summary_text });
        errdefer self.allocator.free(prefixed);

        // Store in history (dupe the raw summary, not the prefixed version)
        try self.history.append(self.allocator, .{
            .role = .assistant,
            .content = try self.allocator.dupe(u8, summary_text),
        });

        // Compact history so the next turn can continue from a stable boundary.
        // v1.14.14 Phase 3 — route through ContextEngine.compact.
        if (self.context_engine_state.compact(self).compacted) {
            self.refreshDurableContinuityAfterCompaction();
        }
        const complete_event = ObserverEvent{ .turn_complete = {} };
        self.observer.recordEvent(&complete_event);
        const total_turn_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - turn_start_ms));
        const first_token_ms_i64: i64 = if (turn_first_token_ms) |value| @intCast(value) else -1;
        const first_token_upper_bound_ms_i64: i64 = if (turn_first_token_upper_bound_ms) |value| @intCast(value) else -1;
        // S5.8 — turn.profile kind distinguishes the two exit causes so
        // operator dashboards can aggregate separately.
        const profile_kind: []const u8 = if (loop_detected) "tool_loop_detected" else "tool_exhausted";
        log.info("turn.profile kind={s} llm_calls={d} retries={d} tool_iterations={d} tool_calls={d} first_token_ms={d} first_token_upper_bound_ms={d} memory_enrich_ms={d} pre_compaction_ms={d} autosave_ms=0 outbox_ms=0 cache_put_ms=0 post_reply_maintenance_ms=0 total_turn_ms={d}", .{
            profile_kind,
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

        // v1.14.18-B G5: reflection-trail serialization moved to a function-scoped
        // defer at turn-start (search "G5 coverage fix") so it fires on every
        // turnOutcome exit path, not just this post-tool-loop one. The inline
        // block that lived here is intentionally gone — do not re-add it.
        // **D1.7 finding 2 fix (2026-04-26):** mark transferred AFTER
        // toOwnedSlice succeeds. See longer comment at the audio_reply path.
        const ids = spawned_task_ids_acc.toOwnedSlice(self.allocator) catch &.{};
        spawned_task_ids_transferred = (spawned_task_ids_acc.items.len == 0);
        return TurnOutcome{
            .text = prefixed,
            .spawned_task_ids = ids,
            .iterations_used = turn_tool_iterations,
            .loop_detected = loop_detected,
        };
    }

    /// **D1.2 backward-compatible wrapper.** Calls `turnOutcome` and
    /// extracts just the text. Existing callers (CLI, tests, legacy
    /// session paths) continue to work unchanged. New callers
    /// (gateway, session manager) should use `turnOutcome` directly
    /// to access spawned_task_ids, tool_calls_executed, iterations_used,
    /// and loop_detected — D1.3 + D1.4 migrate them.
    ///
    /// Cost: one extra `dupe(text)` so the wrapper can call
    /// `outcome.deinit` safely without invalidating the returned slice.
    /// New callers avoid this by reading `outcome.text` directly.
    pub fn turn(self: *Agent, user_message: []const u8) ![]const u8 {
        var outcome = try self.turnOutcome(user_message);
        defer outcome.deinit(self.allocator);
        return try self.allocator.dupe(u8, outcome.text);
    }

    /// Execute a tool by name lookup.
    /// Parses arguments_json once into a std.json.ObjectMap and passes it to the tool.
    fn executeTool(self: *Agent, tool_allocator: std.mem.Allocator, call: ParsedToolCall) ToolExecutionResult {
        return switch (self.preflightToolPolicy(call)) {
            .allowed => self.executeToolUnchecked(tool_allocator, call),
            .blocked => |decision| decision.toToolExecutionResult(),
        };
    }

    fn executeToolUnchecked(self: *Agent, tool_allocator: std.mem.Allocator, call: ParsedToolCall) ToolExecutionResult {
        // S5 (2026-05-29, prod-readiness) — per-tool latency + result counter.
        // `observed_result` defaults to "unknown_tool" so the for-loop fall-
        // through (no matching tool name) is correctly labeled. Each exit
        // path mutates it before its `return`:
        //   - "invalid_args" — JSON parse or non-object args
        //   - "err"         — `t.execute` raised OR `result.success == false`
        //                     (covers exec-block-message refusals too)
        //   - "ok"          — happy path
        const start_ms = std.time.milliTimestamp();
        var observed_result: []const u8 = "unknown_tool";
        defer {
            const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_ms));
            observability.recordMetricGlobal(.{ .tool_call_total = .{ .tool = call.name, .result = observed_result } });
            observability.recordMetricGlobal(.{ .tool_call_latency_ms = .{ .tool = call.name, .value = elapsed_ms } });
        }
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name(), call.name)) {
                // Record this dispatch against the session weight budget
                // (S2.8). Fires here rather than in preflightToolPolicy
                // because preflight is also used for dry-run approval
                // checks — we want weight charged only when the tool is
                // actually about to execute. Preflight-Gate-4 reads
                // sessionWeight() on the NEXT dispatch, so this increment
                // is visible to the next tool in the same turn or any
                // subsequent turn of the same session.
                if (self.usage_rt) |urt| {
                    const meta = self.metadataForToolCall(call);
                    urt.recordWeight(@intCast(meta.cost_class.weight()));
                }

                // Parse arguments JSON to ObjectMap ONCE
                const parsed = std.json.parseFromSlice(
                    std.json.Value,
                    tool_allocator,
                    call.arguments_json,
                    .{},
                ) catch {
                    observed_result = "invalid_args";
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
                        observed_result = "invalid_args";
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
                        observed_result = "err";
                        return .{
                            .name = call.name,
                            .output = msg,
                            .success = false,
                            .tool_call_id = call.tool_call_id,
                        };
                    }
                }

                const result = t.execute(tool_allocator, args) catch |err| {
                    observed_result = "err";
                    return .{
                        .name = call.name,
                        .output = @errorName(err),
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                };
                observed_result = if (result.success) "ok" else "err";
                return .{
                    .name = call.name,
                    .output = if (result.success) result.output else (result.error_msg orelse result.output),
                    .success = result.success,
                    .tool_call_id = call.tool_call_id,
                };
            }
        }

        // observed_result stays "unknown_tool" — the defer above emits it.
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

        // Runtime history hygiene: elide assistant replies that look like
        // laundered hallucinations before sending them back to the model.
        // An assistant message is suspect when it carries multiple red-flag
        // patterns (e.g. "is an open-source X", "Based on my earlier search",
        // "already been established as blocked") AND the surrounding turn
        // (between the prior user message and this reply) had NO tool result.
        // Such replies are almost always the agent's own prior hallucination
        // or cached refusal — feeding them back re-anchors the model to the
        // same mistake. Replace their content with a short elision marker so
        // the turn structure survives but the contamination does not.
        elideUnverifiedHistory(m);

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

        // Build the provider-side video uploader for default_provider when it
        // exposes a wired Files API (Moonshot/Kimi for v1). On any setup miss
        // (unknown provider, missing API key, etc.) we pass null and the
        // multimodal loop falls back to the inline / text-note path.
        const uploader = buildProviderVideoUploader(self, arena);

        return multimodal.prepareMessagesForProvider(arena, m, .{
            .allowed_dirs = allowed,
            .provider_video_upload = uploader,
            .experimental_video_upload = self.experimental_video_upload,
        });
    }

    /// Wire `multimodal.VideoUploader` for the agent's default provider when
    /// possible. Returns null if no provider-files backend is wired or if
    /// the credentials can't be resolved — multimodal.zig handles null
    /// gracefully (over-inline videos fall back to the text-note path).
    ///
    /// Allocations land on `arena` so the closure context lives exactly as
    /// long as the prepared-messages slice.
    fn buildProviderVideoUploader(
        self: *Agent,
        arena: std.mem.Allocator,
    ) ?multimodal.VideoUploader {
        const file_upload = providers.file_upload;
        const kind = file_upload.classifyForUpload(self.default_provider) orelse return null;

        // INFO-3 (v1.14.23 review): when classifyForUpload matched but the
        // API key resolves to null/empty, the prior silent return left
        // operators with a "video too large for inline send" fallback and
        // no breadcrumb. An operator who set `MOONSHOT_API_KEY` but
        // mis-named the env var deserves a single info-level line so they
        // can correlate the fallback to the missing credential.
        const api_key_opt: ?[]u8 = providers.resolveApiKeyFromConfig(
            arena,
            self.default_provider,
            self.configured_providers,
        ) catch |err| blk: {
            log.info(
                "video upload disabled — api-key resolution failed for provider '{s}': {s}",
                .{ self.default_provider, @errorName(err) },
            );
            break :blk null;
        };
        const api_key = api_key_opt orelse {
            log.info(
                "video upload disabled — no API key resolved for provider '{s}'",
                .{self.default_provider},
            );
            return null;
        };
        if (api_key.len == 0) {
            log.info(
                "video upload disabled — empty API key for provider '{s}'",
                .{self.default_provider},
            );
            return null;
        }

        // Prefer an operator-overridden base_url from the providers config;
        // fall back to the factory's default for this provider name.
        var base_url: ?[]const u8 = null;
        for (self.configured_providers) |e| {
            if (std.mem.eql(u8, e.name, self.default_provider)) {
                base_url = e.base_url;
                break;
            }
        }
        const resolved_base_url = base_url orelse
            providers.compatibleProviderUrl(self.default_provider) orelse return null;

        switch (kind) {
            .moonshot => {
                const ctx = arena.create(MoonshotUploaderCtx) catch return null;
                ctx.* = .{
                    .api_key = api_key,
                    .base_url = resolved_base_url,
                };
                return .{
                    .ctx = @ptrCast(ctx),
                    .upload = moonshotUploadAdapter,
                };
            },
        }
    }

    const MoonshotUploaderCtx = struct {
        api_key: []const u8,
        base_url: []const u8,
    };

    /// VideoUploader.upload adapter for Moonshot. Bridges multimodal's
    /// generic callback shape to providers/file_upload's typed API.
    ///
    /// INFO-4 (v1.14.23 review): we synthesize the filename from the
    /// validated `media_type` (e.g. `upload-1700000000.mp4`) rather than
    /// passing the source `basename(file_path)`. Some Moonshot client
    /// libraries use the filename extension as a content-type hint; if
    /// the source file landed on disk with a `.bin` extension (a long
    /// tempfile chain, a download cache, the upload-tempfile staging
    /// path itself), the hint mis-aligns with the actual container and
    /// the server can reject with `purpose mismatch`. The synthetic
    /// filename keeps the hint media-aligned for defense in depth. The
    /// raw source file_path is still streamed verbatim.
    fn moonshotUploadAdapter(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        media_type: []const u8,
    ) anyerror![]u8 {
        const c: *MoonshotUploaderCtx = @ptrCast(@alignCast(ctx));
        const filename = try synthMoonshotFilename(allocator, media_type);
        defer allocator.free(filename);
        const file_id = try providers.file_upload.uploadMoonshotFile(
            allocator,
            c.api_key,
            c.base_url,
            file_path,
            filename,
            .video,
            null,
        );
        defer allocator.free(file_id);
        return providers.file_upload.formatMoonshotRef(allocator, file_id);
    }

    /// Build a synthetic filename for the Moonshot upload's multipart
    /// header from the validated `media_type`. `media_type` is the
    /// sniffed container MIME (e.g. `video/mp4`); we strip the leading
    /// `video/` and use the remainder as the file extension. Falls back
    /// to `.mp4` when the MIME is malformed or empty (multimodal's
    /// decideVideoRoute should have rejected unknown formats earlier,
    /// but defense in depth).
    ///
    /// Exposed pub for unit testability — see tests at end of file.
    pub fn synthMoonshotFilename(
        allocator: std.mem.Allocator,
        media_type: []const u8,
    ) ![]u8 {
        const ext = blk: {
            if (std.mem.startsWith(u8, media_type, "video/")) {
                const suffix = media_type["video/".len..];
                // Sanitize: only accept ASCII alnum / dash / underscore.
                var ok = suffix.len > 0 and suffix.len <= 16;
                if (ok) {
                    for (suffix) |c| {
                        const valid = (c >= 'a' and c <= 'z') or
                            (c >= 'A' and c <= 'Z') or
                            (c >= '0' and c <= '9') or
                            c == '-' or c == '_';
                        if (!valid) {
                            ok = false;
                            break;
                        }
                    }
                }
                if (ok) break :blk suffix;
            }
            break :blk "mp4";
        };
        const ts_ms = std.time.milliTimestamp();
        return std.fmt.allocPrint(allocator, "upload-{d}.{s}", .{ ts_ms, ext });
    }

    /// Returns true if any message in the slice has image content_parts.
    /// Used to decide whether to swap to a vision-capable fallback model
    /// for this turn (see agent/root.zig vision_fallback routing).
    fn hasImageContentParts(messages: []const ChatMessage) bool {
        for (messages) |msg| {
            const parts = msg.content_parts orelse continue;
            for (parts) |part| switch (part) {
                .image_url, .image_base64 => return true,
                else => {},
            };
        }
        return false;
    }

    /// Returns true if any message in the slice carries a video content part.
    /// Used to decide whether the turn's effective model needs native video
    /// support (see the video routing in `turn`).
    fn hasVideoContentParts(messages: []const ChatMessage) bool {
        for (messages) |msg| {
            const parts = msg.content_parts orelse continue;
            for (parts) |part| switch (part) {
                .video_base64, .video_file_ref => return true,
                else => {},
            };
        }
        return false;
    }

    /// G11 — whether the goal-loop should escalate a `stuck` verdict to a
    /// memory-recall directive instead of exiting the turn. True only when the
    /// model self-reported `stuck`, the one-shot escalation has not already
    /// fired this turn (`escalation_count < 1`), and at least one tool
    /// iteration remains for the recall to run in. A still-`stuck` verdict on
    /// the next iteration falls through to the normal exit — no infinite loop.
    fn shouldEscalateOnStuck(
        escalate_on_stuck: bool,
        escalation_count: u32,
        iteration: usize,
        max_iterations: usize,
    ) bool {
        return escalate_on_stuck and escalation_count < 1 and iteration + 1 < max_iterations;
    }

    /// Whether an image-bearing turn must be diverted to the configured
    /// vision sidecar (reliability.vision_fallback).
    ///
    /// True only when ALL hold: images are present, a sidecar is configured,
    /// the active model is not already that sidecar, AND the active model has
    /// no native vision. A vision-capable primary (e.g. Kimi K2.6) keeps the
    /// image and handles it directly — full agent context + tools, one
    /// provider, no hop. An unknown model is treated as text-only (routes
    /// through the sidecar) so images are never silently dropped.
    fn shouldRouteToVisionFallback(
        model_name: []const u8,
        vision_fallback_model: []const u8,
        has_images: bool,
    ) bool {
        if (!has_images) return false;
        if (vision_fallback_model.len == 0) return false;
        if (std.mem.eql(u8, model_name, vision_fallback_model)) return false;
        const model_capabilities = @import("model_capabilities.zig");
        if (model_capabilities.modelSupportsVision(model_name)) return false;
        return true;
    }

    /// Remove every `video_base64` content part from `messages`, replacing
    /// each affected `content_parts` array with an arena-allocated copy that
    /// omits the video. A message left with no parts drops back to
    /// `content_parts = null` so the provider serializes the plain `content`
    /// string instead of an empty array. Returns true if any part was removed.
    fn stripVideoContentParts(arena: std.mem.Allocator, messages: []ChatMessage) !bool {
        var stripped = false;
        for (messages) |*msg| {
            const parts = msg.content_parts orelse continue;
            var has_video = false;
            for (parts) |p| {
                if (p == .video_base64 or p == .video_file_ref) {
                    has_video = true;
                    break;
                }
            }
            if (!has_video) continue;

            var kept: std.ArrayListUnmanaged(providers.ContentPart) = .empty;
            for (parts) |p| {
                if (p == .video_base64 or p == .video_file_ref) {
                    stripped = true;
                    continue;
                }
                try kept.append(arena, p);
            }
            msg.content_parts = if (kept.items.len == 0) null else try kept.toOwnedSlice(arena);
        }
        return stripped;
    }

    /// Video routing for a turn's provider messages. Unlike images — which
    /// can divert to the vision sidecar — there is no video sidecar (the
    /// vision fallback model is image-only). So when `effective_model` has
    /// no native video understanding, the video content parts are dropped
    /// from `messages` (via `stripVideoContentParts`) and the user is told
    /// via a `system_notice`; the turn is never errored. A video-capable
    /// model (Kimi K2.6, Gemini) keeps the video parts untouched.
    fn routeVideoForModel(
        self: *Agent,
        arena: std.mem.Allocator,
        messages: []ChatMessage,
        effective_model: []const u8,
        iteration: usize,
    ) !void {
        const model_capabilities = @import("model_capabilities.zig");
        if (!hasVideoContentParts(messages)) return;
        if (model_capabilities.modelSupportsVideo(effective_model)) return;

        // hasVideoContentParts was true and the model is not video-capable,
        // so this strips at least one part — drop them and notify the user.
        _ = try stripVideoContentParts(arena, messages);

        log.info("turn.stage stage=video_unsupported iteration={d} model={s}", .{ iteration, effective_model });
        const notice = ObserverEvent{ .system_notice = .{
            .kind = "video_unsupported",
            .severity = "info",
            .message = "Video attachment dropped — the active model has no native video support.",
            .detail = effective_model,
            .run_id = self.current_run_id,
        } };
        self.observer.recordEvent(&notice);
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

    /// Elide assistant replies that look like laundered hallucinations before
    /// sending them back to the provider. Mutates `messages` in place.
    ///
    /// An assistant message is elided when:
    ///   1. Its content contains >=2 red-flag patterns from the summarizer
    ///      heuristic (e.g. "is an open-source", "Based on my earlier
    ///      search", "already been established as blocked"), AND
    ///   2. The enclosing turn (between the prior user message and this
    ///      reply, inclusive) contains NO messages with role == .tool.
    ///
    /// Messages that meet both conditions have their content replaced with
    /// a short elision marker; their role remains .assistant so the turn
    /// shape is preserved. Messages backed by a tool result in the same
    /// turn are trusted and left untouched.
    ///
    /// This is the runtime companion to the summarizer-side `C` heuristic
    /// that prevents NEW hallucinations from becoming canonical continuity.
    /// Together they bound both incoming (new) and outgoing (replay) paths
    /// for agent-laundered fabrications.
    fn elideUnverifiedHistory(messages: []ChatMessage) void {
        const elision = "[prior unverified claim elided — re-verify with a tool this turn]";

        // V1 close-out 2026-04-30: was O(N²) — per assistant message with
        // red flags, walked backward to find prior user/tool boundary.
        // Now O(N) single forward pass: track whether a .tool message
        // has fired since the last .user turn boundary.
        //
        // Semantics preserved: a reply is "tool-grounded" iff any .tool
        // message sits between the last .user message and this .assistant
        // message. User-turn boundary RESETS the tool-grounded flag so
        // each turn is evaluated independently.
        //
        // Verified equivalent for: empty history, assistant-only, multi-
        // turn, system-message-interleaved, tool-then-assistant,
        // user-then-assistant patterns. See test "elideUnverifiedHistory
        // forward-sweep matches backward-walk semantics" below.
        var tool_grounded_since_user = false;

        for (messages) |*msg| {
            switch (msg.role) {
                .user => tool_grounded_since_user = false,
                .tool => tool_grounded_since_user = true,
                .assistant => {
                    if (msg.content.len == 0) continue;
                    if (memory_mod.countRedFlagMatches(msg.content) < 2) continue;
                    if (tool_grounded_since_user) continue;
                    msg.content = elision;
                },
                // .system, .developer, etc. — don't change grounding state;
                // pass through unchanged (matches old code's `else => continue`
                // in the backward walk).
                else => {},
            }
        }
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

    // v1.14.14 Phase 3: promoted to `pub` so ContextEngine.compact +
    // ContextEngine.forceCompact can call these from `agent: anytype` paths
    // (Zig 0.15 method dispatch requires pub on anytype call sites).
    pub fn recordAutoCompaction(self: *Agent, history_before: usize, history_after: usize) void {
        context_builder.recordAutoCompaction(&self.last_turn_context, history_before, history_after);
    }

    pub fn recordForceCompression(self: *Agent, history_before: usize, history_after: usize) void {
        context_builder.recordForceCompression(&self.last_turn_context, history_before, history_after);
    }

    fn refreshDurableContinuityAfterCompaction(self: *Agent) void {
        if (!self.last_turn_compacted) return;
        // V1.14.10 A — async: this used to block the turn return for
        // 30-180s on dense sessions (legacy lifecycle path fires
        // 50-100+ contradiction-judge + entity-coref calls per
        // compaction). The full battery on 2026-05-18 saw 9 of ~100
        // session-load turns hit the 180s HTTP read timeout because
        // of this — sample 4 dropped from 88% to 67% as a result.
        //
        // V1.14.10 A review fix (M-03): `durable_continuity_refreshed`
        // now reflects ACTUAL spawn success — true only when the
        // async worker accepted the job. When the in-flight guard
        // skips the trigger (prior worker still running with stale
        // data), telemetry no longer lies; downstream consumers see
        // the truth and the next legitimate trigger picks it up.
        self.last_turn_context.durable_continuity_refreshed =
            commands.persistSessionCheckpointAsync(self, "compaction:auto");
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

        // V1.14.10 A — async (see refreshDurableContinuityAfterCompaction
        // above for rationale). summary_seed fires every turn that
        // would have no summary yet — making it sync was extra
        // contention on a path that didn't need to block. No truth-
        // flag to update on this path (caller doesn't read a return
        // value), so we just discard the spawn success bool.
        _ = commands.persistSessionCheckpointAsync(self, "summary_seed:auto");
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

/// V1.12 — build a recent-turn-text string for the entity_pipeline
/// per-3-turn trigger. Walks back from the end of history collecting
/// the most recent user + assistant pair(s).
///
/// V1.13: cap raised 3KB → 12KB. Pairs with entity_pipeline's 16KB
/// MAX_INPUT_BYTES — leaves ~4KB of headroom for prompt formatting
/// (the extractor wraps the text in a system-prompt + delimiter
/// envelope before sending to the LLM). With 12KB we capture the
/// last 8-12 user+assistant turns instead of the last 2-3, so
/// entities discussed across a longer arc don't get clipped.
///
// V1.14.7 cleanup: buildRecentTurnText DELETED. Sole caller was the
// per-turn entity_pipeline_enqueue site removed in V1.14.7 C3. The
// session-end path uses buildSessionEndTranscriptText (commands.zig:183),
// and Pass A drop-window extraction uses buildCompactionTranscript
// (compaction.zig). Keeping the function as zero-caller dead code would
// invite future drift; deleted.

pub const cli = @import("cli.zig");

/// CLI entry point — re-exported for backward compatibility.
pub const run = cli.run;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "shouldRouteToVisionFallback: native-vision primary keeps the image" {
    // Kimi K2.6 is vision-capable — image stays on the primary, no sidecar hop.
    try std.testing.expect(!Agent.shouldRouteToVisionFallback("kimi-k2.6", "llama-vision", true));
    try std.testing.expect(!Agent.shouldRouteToVisionFallback("moonshot/kimi-k2.6", "llama-vision", true));
    // Text-only primary (K2.5) with images → divert to the configured sidecar.
    try std.testing.expect(Agent.shouldRouteToVisionFallback("kimi-k2.5", "llama-vision", true));
    // No images → never divert, regardless of model.
    try std.testing.expect(!Agent.shouldRouteToVisionFallback("kimi-k2.5", "llama-vision", false));
    // No sidecar configured → cannot divert (image rides the primary as-is).
    try std.testing.expect(!Agent.shouldRouteToVisionFallback("kimi-k2.5", "", true));
    // Primary already IS the sidecar → no-op (no self-swap).
    try std.testing.expect(!Agent.shouldRouteToVisionFallback("llama-vision", "llama-vision", true));
}

test "shouldEscalateOnStuck: G11 one-shot stuck-escalation gate" {
    // Stuck verdict, not yet escalated, iterations remain → escalate.
    try std.testing.expect(Agent.shouldEscalateOnStuck(true, 0, 0, 10));
    // Not a stuck verdict → never escalate.
    try std.testing.expect(!Agent.shouldEscalateOnStuck(false, 0, 0, 10));
    // One-shot: an escalation already fired this turn → no second escalation.
    try std.testing.expect(!Agent.shouldEscalateOnStuck(true, 1, 0, 10));
    // Last iteration (iteration + 1 == max) → no iteration left to recall in.
    try std.testing.expect(!Agent.shouldEscalateOnStuck(true, 0, 9, 10));
    // Penultimate iteration → one iteration remains, escalate.
    try std.testing.expect(Agent.shouldEscalateOnStuck(true, 0, 8, 10));
}

test "hasVideoContentParts detects video parts" {
    const text_parts = [_]providers.ContentPart{.{ .text = "hi" }};
    const no_video = [_]ChatMessage{
        ChatMessage.user("plain"),
        .{ .role = .user, .content = "", .content_parts = &text_parts },
    };
    try std.testing.expect(!Agent.hasVideoContentParts(&no_video));

    const video_parts = [_]providers.ContentPart{
        .{ .text = "watch" },
        .{ .video_base64 = .{ .data = "AAAA", .media_type = "video/mp4" } },
    };
    const with_video = [_]ChatMessage{
        .{ .role = .user, .content = "", .content_parts = &video_parts },
    };
    try std.testing.expect(Agent.hasVideoContentParts(&with_video));
}

test "stripVideoContentParts removes video, keeps other parts" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const parts = [_]providers.ContentPart{
        .{ .text = "describe" },
        .{ .image_base64 = .{ .data = "img", .media_type = "image/png" } },
        .{ .video_base64 = .{ .data = "vid", .media_type = "video/mp4" } },
    };
    var msgs = [_]ChatMessage{
        .{ .role = .user, .content = "describe", .content_parts = &parts },
    };
    try std.testing.expect(try Agent.stripVideoContentParts(arena, &msgs));
    try std.testing.expect(msgs[0].content_parts != null);
    try std.testing.expectEqual(@as(usize, 2), msgs[0].content_parts.?.len);
    for (msgs[0].content_parts.?) |p| {
        try std.testing.expect(p != .video_base64);
    }
}

test "stripVideoContentParts video-only message drops to null content_parts" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const parts = [_]providers.ContentPart{
        .{ .video_base64 = .{ .data = "vid", .media_type = "video/mp4" } },
    };
    var msgs = [_]ChatMessage{
        .{ .role = .user, .content = "[VIDEO:/tmp/c.mp4]", .content_parts = &parts },
    };
    try std.testing.expect(try Agent.stripVideoContentParts(arena, &msgs));
    // Video-only message: no parts remain, falls back to plain content.
    try std.testing.expect(msgs[0].content_parts == null);
}

test "stripVideoContentParts no-op when no video present" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const parts = [_]providers.ContentPart{
        .{ .text = "describe" },
        .{ .image_base64 = .{ .data = "img", .media_type = "image/png" } },
    };
    var msgs = [_]ChatMessage{
        .{ .role = .user, .content = "describe", .content_parts = &parts },
    };
    const stripped = try Agent.stripVideoContentParts(arena, &msgs);
    try std.testing.expect(!stripped);
    try std.testing.expect(msgs[0].content_parts != null);
    try std.testing.expectEqual(@as(usize, 2), msgs[0].content_parts.?.len);
}

test "Agent.OwnedMessage toChatMessage" {
    const msg = Agent.OwnedMessage{
        .role = .user,
        .content = "hello",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .user);
    try std.testing.expectEqualStrings("hello", chat.content);
    // User messages carry no reasoning.
    try std.testing.expect(chat.reasoning_content == null);
}

test "Agent.OwnedMessage carries reasoning through toChatMessage" {
    const msg = Agent.OwnedMessage{
        .role = .assistant,
        .content = "answer",
        .reasoning = "let me think step by step",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .assistant);
    try std.testing.expectEqualStrings("answer", chat.content);
    try std.testing.expect(chat.reasoning_content != null);
    try std.testing.expectEqualStrings("let me think step by step", chat.reasoning_content.?);
}

test "Agent.OwnedMessage deinit frees reasoning without leaking" {
    const allocator = std.testing.allocator;
    const msg = Agent.OwnedMessage{
        .role = .assistant,
        .content = try allocator.dupe(u8, "answer"),
        .reasoning = try allocator.dupe(u8, "reasoning trace"),
    };
    // deinit must free both content and reasoning — leak-checked by the
    // testing allocator.
    msg.deinit(allocator);
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

test "memory_loader accessible as internal stage of context_engine" {
    _ = context_engine.memory_loader.loadContext;
    _ = context_engine.memory_loader.loadTurnMemorySlot;
}

test "context_builder accessible as internal stage of context_engine" {
    _ = context_engine.builder.buildSnapshot;
    _ = context_engine.builder.buildPromptRefreshPlan;
    _ = context_engine.builder.buildLastTurnContext;
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

test "Agent provider messages emit raw user content (context v2, no enrichment substitution)" {
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
    // Context v2: current_turn_enriched_user is never set. Memory lives in the
    // volatile portion of the system prompt via PromptContext.memory_slot, not
    // prepended to the user message. Provider emissions must equal raw history.

    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const provider_messages = try agent.buildProviderMessages(arena);
    try std.testing.expectEqual(@as(usize, 1), provider_messages.len);
    try std.testing.expectEqualStrings("raw user text", provider_messages[0].content);
    try std.testing.expectEqualStrings("raw user text", agent.history.items[0].content);

    const flat_messages = try agent.buildMessageSlice();
    defer allocator.free(flat_messages);
    try std.testing.expectEqual(@as(usize, 1), flat_messages.len);
    try std.testing.expectEqualStrings("raw user text", flat_messages[0].content);
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

test "recordSessionToolNames stores owned tool manifest" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const calls = [_]ParsedToolCall{
        .{ .name = "memory_recall", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "web_search", .arguments_json = "{}", .tool_call_id = null },
    };

    agent.recordSessionToolNames(&calls);

    try std.testing.expectEqual(@as(usize, 2), agent.session_tool_names.items.len);
    try std.testing.expectEqualStrings("memory_recall", agent.session_tool_names.items[0]);
    try std.testing.expectEqualStrings("web_search", agent.session_tool_names.items[1]);

    agent.clearSessionToolNames();
    try std.testing.expectEqual(@as(usize, 0), agent.session_tool_names.items.len);
}

test "snapshotAndClearActiveGoalState retains status for session capture" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var goal_state = goal_loop.GoalState{
        .goal_text = "ship the audit fixes",
        .status = .met,
        .progress_notes = .empty,
    };
    try goal_state.progress_notes.append(allocator, try allocator.dupe(u8, "tests passed"));
    agent.active_goal_state = goal_state;

    agent.snapshotAndClearActiveGoalState();

    try std.testing.expect(agent.active_goal_state == null);
    try std.testing.expectEqual(goal_loop.GoalStatus.met, agent.session_last_goal_status.?);
}

test "deinitWithTimeout leaves agent intact when lifecycle worker is active" {
    var agent = try makeTestAgent(std.testing.allocator);
    agent.model_name = try std.testing.allocator.dupe(u8, "owned-model");
    agent.model_name_owned = true;

    agent.lifecycle_in_flight.store(true, .release);
    try std.testing.expect(!agent.deinitWithTimeout(0));
    try std.testing.expect(agent.model_name_owned);
    try std.testing.expectEqualStrings("owned-model", agent.model_name);

    agent.lifecycle_in_flight.store(false, .release);
    agent.deinit();
}

test "waitForLifecycleIdle joins completed lifecycle worker" {
    var agent = try makeTestAgent(std.testing.allocator);
    defer agent.deinit();

    const Worker = struct {
        fn run(done: *std.atomic.Value(bool)) void {
            done.store(true, .release);
        }
    };

    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&done});
    agent.lifecycle_thread_mu.lock();
    agent.lifecycle_thread = thread;
    agent.lifecycle_thread_mu.unlock();

    try std.testing.expect(agent.waitForLifecycleIdle(1_000));
    try std.testing.expect(done.load(.acquire));
    try std.testing.expect(agent.lifecycle_thread == null);
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

test "slash /new clears procedural session capture state" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.session_total_tool_count = 3;
    try agent.session_tool_names.append(allocator, try allocator.dupe(u8, "shell"));
    agent.session_last_goal_status = .stuck;

    const response = (try agent.handleSlashCommand("/new")).?;
    defer allocator.free(response);

    try std.testing.expectEqual(@as(u32, 0), agent.session_total_tool_count);
    try std.testing.expectEqual(@as(usize, 0), agent.session_tool_names.items.len);
    try std.testing.expect(agent.session_last_goal_status == null);
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
        // F-PA2: Pass A switched from in-place rewrite to drop-from-middle.
        // Drop is more aggressive — under the prior 4_000 token_limit +
        // keep_recent=2 fixture the post-drop pressure fell below 90% AND
        // Pass C's internal cap_keep=4 left nothing to compact, so Pass C
        // never fired and the user-facing turn call returned "compaction
        // summary" (call #1) instead of "ok" (call #2). Tuned both:
        //   - token_limit=1_000 → post-drop pressure stays >90% (Pass C trigger)
        //   - keep_recent=4    → Pass A leaves 5 msgs (Pass C has 1 to summarize)
        // Preserves the test's intent (Pass C fires + turn call completes).
        .token_limit = 1_000,
        .max_tokens = 512,
        .compaction_keep_recent = 4,
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

test "thrash guard skips compaction when prior 2 firings each saved <10%" {
    // V1.14.6 follow-up: cover the existing anti-thrash guard at
    // root.zig:899-973. The guard prevents repeated expensive Pass C
    // calls on tightly-packed sessions that can't release more bytes.
    // Test contract: with the savings ring pre-loaded with two below-
    // threshold entries, autoCompactHistory must short-circuit BEFORE
    // touching any provider, even when token pressure would otherwise
    // trigger Pass A or Pass C.
    const NoCallProvider = struct {
        called: bool = false,
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.called = true;
            return .{
                .content = try allocator.dupe(u8, "should-not-be-called"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }
        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "no-call-provider";
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state = NoCallProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = NoCallProvider.chatWithSystem,
        .chat = NoCallProvider.chat,
        .supportsNativeTools = NoCallProvider.supportsNativeTools,
        .getName = NoCallProvider.getName,
        .deinit = NoCallProvider.deinitFn,
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
        .token_limit = 1_000,
        .max_tokens = 512,
        .compaction_keep_recent = 4,
        .compact_context_enabled = true,
        .auto_save = false,
        .history = .empty,
        // The under-test condition: prior two firings each saved 5%
        // (well under the 10% COMPACTION_MIN_SAVINGS_PERCENT floor).
        .compaction_savings_ring = .{ 5, 5 },
    };
    defer agent.deinit();

    // Build heavy history that would otherwise trigger Pass A + Pass C.
    for (0..5) |_| {
        const u = try allocator.alloc(u8, 2_500);
        @memset(u, 'u');
        try agent.history.append(allocator, .{ .role = .user, .content = u });
        const a = try allocator.alloc(u8, 2_500);
        @memset(a, 'a');
        try agent.history.append(allocator, .{ .role = .assistant, .content = a });
    }

    const compacted = try agent.autoCompactHistory();
    try std.testing.expect(!compacted);
    // Provider must NOT have been called — the guard short-circuits
    // before Pass C's summarization call would fire.
    try std.testing.expect(!provider_state.called);
    // Ring is unchanged (recordCompactionSavings only fires after a
    // successful compaction).
    try std.testing.expectEqual(@as(u8, 5), agent.compaction_savings_ring[0]);
    try std.testing.expectEqual(@as(u8, 5), agent.compaction_savings_ring[1]);
}

test "thrash guard releases when a recent firing exceeded the floor" {
    // Inverse of the above: ring [5, 30] (one entry over 10%) should
    // NOT skip — the guard requires BOTH entries to be under-threshold.
    const TrackProvider = struct {
        called: bool = false,
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.called = true;
            return .{
                .content = try allocator.dupe(u8, "summary"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }
        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "track-provider";
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    var provider_state = TrackProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = TrackProvider.chatWithSystem,
        .chat = TrackProvider.chat,
        .supportsNativeTools = TrackProvider.supportsNativeTools,
        .getName = TrackProvider.getName,
        .deinit = TrackProvider.deinitFn,
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
        .token_limit = 1_000,
        .max_tokens = 512,
        .compaction_keep_recent = 4,
        .compact_context_enabled = true,
        .auto_save = false,
        .history = .empty,
        .compaction_savings_ring = .{ 5, 30 },
    };
    defer agent.deinit();

    for (0..5) |_| {
        const u = try allocator.alloc(u8, 2_500);
        @memset(u, 'u');
        try agent.history.append(allocator, .{ .role = .user, .content = u });
        const a = try allocator.alloc(u8, 2_500);
        @memset(a, 'a');
        try agent.history.append(allocator, .{ .role = .assistant, .content = a });
    }

    _ = try agent.autoCompactHistory();
    // Provider was called for Pass C summarization — guard did NOT fire.
    try std.testing.expect(provider_state.called);
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
    // F-PA2: keep_recent bumped from 2 → 4 and token_limit dropped from
    // 4_000 → 1_000 — both same rationale as the sibling "turn
    // auto-compacts on token pressure" test above. The more aggressive
    // drop-from-middle leaves only first_user + tail; with keep_recent=2
    // that's 3 messages, less than Pass C's internal cap_keep floor of 4,
    // so Pass C exits early with no work and never refreshes continuity.
    agent.compaction_keep_recent = 4;
    agent.token_limit = 1_000;
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

    // V1.14.10 A — lifecycle persist is async; wait for it before
    // asserting on the resulting memory write.
    try std.testing.expect(agent.waitForLifecycleIdle(30_000));
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

    // V1.14.10 A — lifecycle persist is async; wait before asserting on
    // the memory side-effects (anchor + latest summary).
    try std.testing.expect(agent.waitForLifecycleIdle(30_000));

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

    // V1.14.10 A — lifecycle persist is async; wait before asserting on
    // the memory writes.
    try std.testing.expect(agent.waitForLifecycleIdle(30_000));

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
        "runtime_info",    "file_read", "memory_recall", "memory_list",
        "memory_timeline", "web_fetch", "web_search",    "task_list",
        "task_get",
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
        "shell",    "file_write", "file_edit", "memory_store",
        "delegate", "spawn",      "message",
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

test "preflight allowed exposes read-only metadata for file_read in plan mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;
    const call = ParsedToolCall{ .name = "file_read", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .allowed);
    try std.testing.expect(result.allowed.metadata.flags.read_only);
    try std.testing.expect(!result.allowed.metadata.flags.mutating);
    try std.testing.expectEqualStrings("file_read", result.allowed.metadata.name);
}

test "preflight blocked shell in plan mode carries execution_mode source and critical risk" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;
    const call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.execution_mode, result.blocked.source);
    try std.testing.expectEqual(tool_metadata.RiskLevel.critical, result.blocked.risk_level);
    try std.testing.expectEqual(ExecutionMode.plan, result.blocked.mode);
    try std.testing.expectEqualStrings("mode_requires_read_only", result.blocked.reason);
    try std.testing.expect(result.blocked.metadata.flags.mutating);
}

test "preflight blocked shell in review mode carries execution_mode source" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .review;
    const call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.execution_mode, result.blocked.source);
    try std.testing.expectEqual(ExecutionMode.review, result.blocked.mode);
    try std.testing.expectEqualStrings("mode_requires_read_only", result.blocked.reason);
}

test "preflight unknown tool in plan mode blocks with conservative mutating metadata" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;
    const call = ParsedToolCall{ .name = "mcp_unknown_tool", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.execution_mode, result.blocked.source);
    try std.testing.expectEqual(tool_metadata.RiskLevel.high, result.blocked.risk_level);
    try std.testing.expect(result.blocked.metadata.flags.mutating);
    try std.testing.expect(!result.blocked.metadata.flags.read_only);
    try std.testing.expectEqualStrings("mcp_unknown_tool", result.blocked.metadata.name);
}

test "preflight unknown tool in execute mode is allowed with conservative metadata" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .execute;
    const call = ParsedToolCall{ .name = "mcp_unknown_tool", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .allowed);
    try std.testing.expect(result.allowed.metadata.flags.mutating);
    try std.testing.expectEqual(tool_metadata.RiskLevel.high, result.allowed.metadata.risk_level);
    try std.testing.expectEqualStrings("mcp_unknown_tool", result.allowed.metadata.name);
}

test "preflight action budget exhaustion reports action_budget source" {
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

    const call = ParsedToolCall{ .name = "runtime_info", .arguments_json = "{}", .tool_call_id = null };
    _ = agent.preflightToolPolicy(call); // consume the single-action budget
    const second = agent.preflightToolPolicy(call);
    try std.testing.expect(second == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.action_budget, second.blocked.source);
    try std.testing.expectEqualStrings("action_budget_exhausted", second.blocked.reason);
    try std.testing.expectEqualStrings("Action budget exhausted", second.blocked.output);
}

test "preflight security read-only policy reports security_read_only source" {
    const allocator = std.testing.allocator;
    var tracker = RateTracker.init(allocator, 1);
    defer tracker.deinit();
    var policy = SecurityPolicy{
        .autonomy = .read_only,
        .workspace_dir = "/tmp",
        .max_actions_per_hour = 100,
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

    const call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.security_read_only, result.blocked.source);
    try std.testing.expectEqualStrings("security_policy_read_only", result.blocked.reason);
    try std.testing.expectEqualStrings("Action blocked: agent is in read-only mode", result.blocked.output);
}

test "preflight blocked decision conversion preserves tool_call_id" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.execution_mode = .plan;
    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{}",
        .tool_call_id = "call_abc123",
    };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    const converted = result.blocked.toToolExecutionResult();
    try std.testing.expect(!converted.success);
    try std.testing.expectEqualStrings("shell", converted.name);
    try std.testing.expectEqualStrings(result.blocked.output, converted.output);
    try std.testing.expect(converted.tool_call_id != null);
    try std.testing.expectEqualStrings("call_abc123", converted.tool_call_id.?);
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

test "Agent parses task_plan and emits step narration frames during tool loop" {
    const PlanProbeTool = struct {
        const Self = @This();
        pub const tool_name = "plan_probe";
        pub const tool_description = "Synthetic tool for task-plan narration testing";
        pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
        pub const vtable = tools_mod.ToolVTable(Self);

        fn tool(self: *Self) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(_: *Self, allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
            return .{
                .success = true,
                .output = try allocator.dupe(u8, "ok"),
            };
        }
    };

    const PlannedProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            if (self.call_count <= 3) {
                const tool_calls = try allocator.alloc(providers.ToolCall, 1);
                tool_calls[0] = .{
                    .id = try std.fmt.allocPrint(allocator, "call-{d}", .{self.call_count}),
                    .name = try allocator.dupe(u8, "plan_probe"),
                    .arguments = try std.fmt.allocPrint(allocator, "{{\"step\":{d}}}", .{self.call_count}),
                };
                const content = if (self.call_count == 1)
                    try allocator.dupe(u8,
                        \\<task_plan>
                        \\<summary>Run the synthetic three-step task</summary>
                        \\<step>Run alpha probe</step>
                        \\<step>Run beta probe</step>
                        \\<step>Run gamma probe</step>
                        \\</task_plan>
                    )
                else
                    try std.fmt.allocPrint(allocator, "step {d}", .{self.call_count});
                return .{
                    .content = content,
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
            return "planned-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const CaptureObserver = struct {
        const Self = @This();
        plan_step_count: u32 = 0,
        step_done_count: u32 = 0,
        plan_complete_count: u32 = 0,
        generic_tool_start_count: u32 = 0,
        step_indices: [3]u32 = .{ 99, 99, 99 },

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
                .narration_frame => |frame| {
                    if (frame.frame_type == .tool_start and frame.step_total == null) {
                        self.generic_tool_start_count += 1;
                    }
                    if (frame.step_total != null and frame.step_total.? == 3) {
                        switch (frame.frame_type) {
                            .plan_step => {
                                if (self.plan_step_count < self.step_indices.len) {
                                    self.step_indices[self.plan_step_count] = frame.step_index orelse 99;
                                }
                                self.plan_step_count += 1;
                            },
                            .tool_done => self.step_done_count += 1,
                            .thinking => {
                                if (frame.step_index != null and frame.step_index.? == 3) {
                                    self.plan_complete_count += 1;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
        fn flush(_: *anyopaque) void {}
        fn name(_: *anyopaque) []const u8 {
            return "task-plan-capture";
        }
    };

    const allocator = std.testing.allocator;

    var provider_state = PlannedProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = PlannedProvider.chatWithSystem,
        .chat = PlannedProvider.chat,
        .supportsNativeTools = PlannedProvider.supportsNativeTools,
        .getName = PlannedProvider.getName,
        .deinit = PlannedProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var tool_impl = PlanProbeTool{};
    const tool_list = [_]Tool{tool_impl.tool()};

    const specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |t, i| {
        specs[i] = .{
            .name = t.name(),
            .description = t.description(),
            .parameters_json = t.parametersJson(),
        };
    }

    var capture = CaptureObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &tool_list,
        .tool_specs = specs,
        .mem = null,
        .observer = capture.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 6,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("run the planned task");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("done", response);
    try std.testing.expectEqual(@as(usize, 4), provider_state.call_count);
    try std.testing.expectEqual(@as(u32, 3), capture.plan_step_count);
    try std.testing.expectEqual(@as(u32, 3), capture.step_done_count);
    try std.testing.expectEqual(@as(u32, 1), capture.plan_complete_count);
    try std.testing.expectEqual(@as(u32, 0), capture.step_indices[0]);
    try std.testing.expectEqual(@as(u32, 1), capture.step_indices[1]);
    try std.testing.expectEqual(@as(u32, 2), capture.step_indices[2]);
    try std.testing.expect(capture.generic_tool_start_count >= 3);
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

test "isParallelSafeToolCall derives from metadata, not a hardcoded allowlist" {
    // Regression lock: before this refactor, parallel-dispatch eligibility
    // was a hardcoded name/action allowlist that drifted from the metadata
    // registry. Several tools (memory_recall, task_list, context_snapshot,
    // etc.) carried concurrency_safe=true but were never parallel-dispatched.
    // After the fix, the metadata flag is the single source of truth.
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
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Read-only + concurrency_safe → parallel-safe.
    try std.testing.expect(agent.isParallelSafeToolCall(.{
        .name = "memory_recall",
        .arguments_json = "{\"query\":\"x\"}",
        .tool_call_id = null,
    }));
    try std.testing.expect(agent.isParallelSafeToolCall(.{
        .name = "context_snapshot",
        .arguments_json = "{}",
        .tool_call_id = null,
    }));
    try std.testing.expect(agent.isParallelSafeToolCall(.{
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
        .tool_call_id = null,
    }));
    try std.testing.expect(agent.isParallelSafeToolCall(.{
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com\"}",
        .tool_call_id = null,
    }));

    // Read-only self-control but explicitly concurrency_safe=false — must NOT parallel.
    try std.testing.expect(!agent.isParallelSafeToolCall(.{
        .name = "set_execution_mode",
        .arguments_json = "{\"mode\":\"plan\",\"reason\":\"x\"}",
        .tool_call_id = null,
    }));

    // Mutating base tool — never parallel.
    try std.testing.expect(!agent.isParallelSafeToolCall(.{
        .name = "shell",
        .arguments_json = "{\"command\":\"ls\"}",
        .tool_call_id = null,
    }));
    try std.testing.expect(!agent.isParallelSafeToolCall(.{
        .name = "file_write",
        .arguments_json = "{\"path\":\"x\",\"content\":\"y\"}",
        .tool_call_id = null,
    }));

    // Args-aware refinement: schedule.list/get/runs → parallel-safe; schedule.create → not.
    try std.testing.expect(agent.isParallelSafeToolCall(.{
        .name = "schedule",
        .arguments_json = "{\"action\":\"list\"}",
        .tool_call_id = null,
    }));
    try std.testing.expect(agent.isParallelSafeToolCall(.{
        .name = "schedule",
        .arguments_json = "{\"action\":\"get\",\"id\":\"x\"}",
        .tool_call_id = null,
    }));
    try std.testing.expect(!agent.isParallelSafeToolCall(.{
        .name = "schedule",
        .arguments_json = "{\"action\":\"create\",\"expression\":\"* * * * *\"}",
        .tool_call_id = null,
    }));

    // Composio: list → parallel-safe, execute → not.
    try std.testing.expect(agent.isParallelSafeToolCall(.{
        .name = "composio",
        .arguments_json = "{\"action\":\"list\"}",
        .tool_call_id = null,
    }));
    try std.testing.expect(!agent.isParallelSafeToolCall(.{
        .name = "composio",
        .arguments_json = "{\"action\":\"execute\",\"action_name\":\"gmail.send\"}",
        .tool_call_id = null,
    }));

    // Unknown tool → conservative (mutating=true, concurrency_safe=false).
    try std.testing.expect(!agent.isParallelSafeToolCall(.{
        .name = "no_such_tool",
        .arguments_json = "{}",
        .tool_call_id = null,
    }));
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

test "Agent streaming follow-through retries false in-progress claims" {
    const StreamingFollowThroughProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "unexpected chat path"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn streamChat(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            _: providers.ChatRequest,
            _: []const u8,
            _: f64,
            callback: providers.StreamCallback,
            callback_ctx: *anyopaque,
        ) anyerror!providers.StreamChatResult {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            const content = if (self.call_count == 1)
                "Executing the next step now:"
            else
                "done";
            callback(callback_ctx, providers.StreamChunk.textDelta(content));
            callback(callback_ctx, providers.StreamChunk.finalChunk());
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

        fn supportsStreaming(_: *anyopaque) bool {
            return true;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "streaming-follow-through-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const StreamRecorder = struct {
        chunks: std.ArrayListUnmanaged(u8) = .empty,

        fn onChunk(ctx: *anyopaque, chunk: providers.StreamChunk) void {
            if (chunk.delta.len == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.chunks.appendSlice(std.testing.allocator, chunk.delta) catch {};
        }

        fn deinit(self: *@This()) void {
            self.chunks.deinit(std.testing.allocator);
        }
    };

    const allocator = std.testing.allocator;
    var provider_state = StreamingFollowThroughProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = StreamingFollowThroughProvider.chatWithSystem,
        .chat = StreamingFollowThroughProvider.chat,
        .supportsNativeTools = StreamingFollowThroughProvider.supportsNativeTools,
        .getName = StreamingFollowThroughProvider.getName,
        .deinit = StreamingFollowThroughProvider.deinitFn,
        .supports_streaming = StreamingFollowThroughProvider.supportsStreaming,
        .stream_chat = StreamingFollowThroughProvider.streamChat,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var recorder = StreamRecorder{};
    defer recorder.deinit();
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
        .stream_callback = StreamRecorder.onChunk,
        .stream_ctx = @ptrCast(&recorder),
    };
    defer agent.deinit();

    const response = try agent.turn("do the thing");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("done", response);
    try std.testing.expectEqual(@as(usize, 2), provider_state.call_count);
    try std.testing.expect(std.mem.indexOf(u8, recorder.chunks.items, "Executing the next step now:") == null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.chunks.items, "done") != null);
}

test "Agent shouldForceActionFollowThrough detects english deferred promise" {
    try std.testing.expect(Agent.shouldForceActionFollowThrough("I'll try again with a different filename now."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("let me check that and get back in a moment"));
}

test "Agent shouldForceActionFollowThrough detects generic in-progress status claims" {
    try std.testing.expect(Agent.shouldForceActionFollowThrough("Executing the next step now:"));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("Checking the environment for you now."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("Running a verification pass before I answer."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("Actually executing web_search NOW:)"));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("Okay, searching the web for that now."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("**Actually executing tool discovery - no memory, no context, just real system calls**"));
}

test "Agent shouldForceActionFollowThrough ignores neutral gerund phrasing" {
    try std.testing.expect(!Agent.shouldForceActionFollowThrough("Using tools is not necessary here."));
    try std.testing.expect(!Agent.shouldForceActionFollowThrough("Running code locally is unsupported in this environment."));
    try std.testing.expect(!Agent.shouldForceActionFollowThrough("**Using the old cache format is unsupported in this environment.**"));
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

test "Agent looksLikeToolCallMarkupPrefix holds streaming tool-call markup" {
    // Full opener and every partial prefix must trigger the streaming hold —
    // the leak (`ool_call>` in a reply) happened because a partial `<tool…`
    // chunk flushed before the full `<tool_call>` accumulated.
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("<tool_call>"));
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("<tool_call>\n{\"name\":\"memory_recall\"}"));
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("<"));
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("<t"));
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("<tool_c"));

    // Residue shapes from upstream normalisers eating the leading bytes —
    // QA 2026-05-23 T4a/T6 leak. Each must hold so the user never sees them.
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("tool_call>"));
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("tool_call>\n{\"name\":\"spawn\"}"));
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("ool_call>"));
    try std.testing.expect(Agent.looksLikeToolCallMarkupPrefix("ool_call>\nGot it..."));
}

test "Agent looksLikeToolCallMarkupPrefix lets normal replies stream" {
    try std.testing.expect(!Agent.looksLikeToolCallMarkupPrefix("From memory, I can confirm"));
    try std.testing.expect(!Agent.looksLikeToolCallMarkupPrefix("<3 a heart, not a tool"));
    try std.testing.expect(!Agent.looksLikeToolCallMarkupPrefix("Here is the answer."));
    try std.testing.expect(!Agent.looksLikeToolCallMarkupPrefix(""));
    // Residue substrings mid-line must NOT hold — only exact-prefix matches.
    try std.testing.expect(!Agent.looksLikeToolCallMarkupPrefix("Use tool_call> markup like this in docs."));
    try std.testing.expect(!Agent.looksLikeToolCallMarkupPrefix("see ool_call> appendix"));
}

// D53 third defense layer (2026-05-24): the streaming pass_through path
// must hold trailing bytes that could be the start of a markup sentinel
// so a split-across-chunks markup reassembles cleanly.
test "Agent trailingMarkupPrefixLen holds full canonical opener prefix" {
    // Chunk ends with the full `<tool_call>` opener prefix bytes (10 of 11).
    try std.testing.expectEqual(@as(usize, 10), Agent.trailingMarkupPrefixLen("Some text <tool_call"));
    // Ends with just `<` — the smallest possible prefix.
    try std.testing.expectEqual(@as(usize, 1), Agent.trailingMarkupPrefixLen("Hello <"));
    // Ends with `<t` — 2-byte prefix of `<tool_call>`.
    try std.testing.expectEqual(@as(usize, 2), Agent.trailingMarkupPrefixLen("Hello <t"));
    // Ends with residue-prefix `ool` (start of `ool_call>`).
    try std.testing.expectEqual(@as(usize, 3), Agent.trailingMarkupPrefixLen("Hi ool"));
}

test "Agent trailingMarkupPrefixLen returns 0 for clean prose" {
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen("This is a complete sentence."));
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen(""));
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen("ends with a number 42"));
    // `<` followed by content that's NOT a markup prefix — only the last
    // bytes matter, and "/>" isn't the start of any sentinel we track.
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen("XML-ish <foo>"));
}

test "Agent trailingMarkupPrefixLen does not hold a complete sentinel" {
    // A complete sentinel is upstream's responsibility (stripToolCallMarkup
    // ate it). The helper only holds STRICT prefixes shorter than the
    // shortest matching sentinel. `<tool_call>` is the full opener (11
    // bytes); it's not a prefix of `</tool_call>` because index 1 differs
    // (`<t` vs `</`). So the helper returns 0 — and the emit path moves
    // those bytes downstream. If for some reason a complete sentinel got
    // past stripToolCallMarkup, that's a strip bug, not a hold bug.
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen("Before <tool_call>"));
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen("Before </tool_call>"));
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen("Before tool_call>"));
    try std.testing.expectEqual(@as(usize, 0), Agent.trailingMarkupPrefixLen("Before ool_call>"));
}

test "Agent stripToolCallMarkup removes complete blocks" {
    const allocator = std.testing.allocator;
    const out = Agent.stripToolCallMarkup(allocator, "Before <tool_call>{\"name\":\"x\"}</tool_call> After");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</tool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "After") != null);
}

test "Agent stripToolCallMarkup removes the ool_call> partial residue (QA T6 leak)" {
    const allocator = std.testing.allocator;
    // QA T6 captured this exact shape: model emitted markup, streaming
    // held the leading `<t`, flushValidatedReply emitted final_text which
    // started with the rest of the opener.
    const leak = "ool_call>\n\nThe subagent (`sum_1_to_100`) completed successfully";
    const out = Agent.stripToolCallMarkup(allocator, leak);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "The subagent") != null);
}

test "Agent stripToolCallMarkup is a noop on clean text" {
    const allocator = std.testing.allocator;
    const clean = "Here is the answer. Nothing fancy here.";
    const out = Agent.stripToolCallMarkup(allocator, clean);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(clean, out);
}

test "Agent stripToolCallMarkup removes multiple stray fragments" {
    const allocator = std.testing.allocator;
    // QA T4a had TWO leaked markup blocks (one per memory_store call) followed
    // by the final answer. Strip all of them, keep the answer.
    const leak = "ool_call>\nool_call>\nGot it, alaa.";
    const out = Agent.stripToolCallMarkup(allocator, leak);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Got it, alaa.") != null);
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
    // v1.14.22: Claude 4.x ships 1M context natively at standard pricing.
    const ct = @import("context_tokens.zig");
    try std.testing.expectEqual(@as(?u64, 1_000_000), ct.lookupContextTokens("claude-sonnet-4.6"));
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

test "ttsAudioChannelSupported routes through voice_mode (S7.9 — telegram only today)" {
    // S7.9 — previous version asserted discord + whatsapp also returned
    // true; voice_mode.zig's capability table was flipped because only
    // telegram has a real audio-send path in the channel implementations.
    // This test now proves the indirection through voice_mode still
    // fires correctly (the routing refactor from the telegram-only
    // hardcode hasn't regressed) AND reflects the current honest state.
    try std.testing.expect(voice_mode.channelSupportsAudio("telegram"));
    try std.testing.expect(!voice_mode.channelSupportsAudio("discord"));
    try std.testing.expect(!voice_mode.channelSupportsAudio("whatsapp"));
    try std.testing.expect(!voice_mode.channelSupportsAudio("slack"));
}

test "ttsAudioChannelSupported returns false for cli via voice_mode" {
    try std.testing.expect(!voice_mode.channelSupportsAudio("cli"));
    try std.testing.expect(!voice_mode.channelSupportsAudio("unknown"));
}

// ── WP1.4 approval-required tests ──────────────────────────────────

const ApprovalEventCapture = struct {
    tool: []const u8,
    reason: []const u8,
    risk_level: []const u8,
    raw_data: []u8,
    run_id: ?[]u8 = null,
};

const CapturingApprovalObserver = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(ApprovalEventCapture),

    const vtable_impl = observability.Observer.VTable{
        .record_event = recordEventImpl,
        .record_metric = recordMetricImpl,
        .flush = flushImpl,
        .name = nameImpl,
    };

    fn init(allocator: std.mem.Allocator) CapturingApprovalObserver {
        return .{ .allocator = allocator, .events = .empty };
    }

    fn deinit(self: *CapturingApprovalObserver) void {
        for (self.events.items) |e| {
            self.allocator.free(e.raw_data);
            if (e.run_id) |rid| self.allocator.free(rid);
        }
        self.events.deinit(self.allocator);
    }

    fn observer(self: *CapturingApprovalObserver) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    fn recordEventImpl(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *CapturingApprovalObserver = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .approval_required => |e| {
                // Capture a JSON-shaped blob mirroring what the SSE frame
                // will carry, so downstream tests can assert non-sensitivity.
                const blob = std.fmt.allocPrint(
                    self.allocator,
                    "{{\"tool\":\"{s}\",\"reason\":\"{s}\",\"risk_level\":\"{s}\"}}",
                    .{ e.tool, e.reason, e.risk_level },
                ) catch return;
                const run_id_copy: ?[]u8 = if (e.run_id) |rid|
                    self.allocator.dupe(u8, rid) catch null
                else
                    null;
                self.events.append(self.allocator, .{
                    .tool = e.tool,
                    .reason = e.reason,
                    .risk_level = e.risk_level,
                    .raw_data = blob,
                    .run_id = run_id_copy,
                }) catch {
                    self.allocator.free(blob);
                    if (run_id_copy) |rid| self.allocator.free(rid);
                };
            },
            else => {},
        }
    }

    fn recordMetricImpl(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flushImpl(_: *anyopaque) void {}
    fn nameImpl(_: *anyopaque) []const u8 {
        return "capturing_approval";
    }
};

const ToolEventCapture = struct {
    kind: enum { start, result },
    tool: []u8,
    tool_use_id: ?[]u8 = null,
    run_id: ?[]u8 = null,
};

const CapturingToolEventObserver = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(ToolEventCapture),

    const vtable_impl = observability.Observer.VTable{
        .record_event = recordEventImpl,
        .record_metric = recordMetricImpl,
        .flush = flushImpl,
        .name = nameImpl,
    };

    fn init(allocator: std.mem.Allocator) CapturingToolEventObserver {
        return .{ .allocator = allocator, .events = .empty };
    }

    fn deinit(self: *CapturingToolEventObserver) void {
        for (self.events.items) |e| {
            self.allocator.free(e.tool);
            if (e.tool_use_id) |id| self.allocator.free(id);
            if (e.run_id) |rid| self.allocator.free(rid);
        }
        self.events.deinit(self.allocator);
    }

    fn observer(self: *CapturingToolEventObserver) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    fn recordEventImpl(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *CapturingToolEventObserver = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .tool_call_start => |e| {
                const tool_copy = self.allocator.dupe(u8, e.tool) catch return;
                const id_copy: ?[]u8 = if (e.tool_use_id) |id| self.allocator.dupe(u8, id) catch null else null;
                const rid_copy: ?[]u8 = if (e.run_id) |rid| self.allocator.dupe(u8, rid) catch null else null;
                self.events.append(self.allocator, .{
                    .kind = .start,
                    .tool = tool_copy,
                    .tool_use_id = id_copy,
                    .run_id = rid_copy,
                }) catch {
                    self.allocator.free(tool_copy);
                    if (id_copy) |id| self.allocator.free(id);
                    if (rid_copy) |rid| self.allocator.free(rid);
                };
            },
            .tool_call => |e| {
                const tool_copy = self.allocator.dupe(u8, e.tool) catch return;
                const id_copy: ?[]u8 = if (e.tool_use_id) |id| self.allocator.dupe(u8, id) catch null else null;
                const rid_copy: ?[]u8 = if (e.run_id) |rid| self.allocator.dupe(u8, rid) catch null else null;
                self.events.append(self.allocator, .{
                    .kind = .result,
                    .tool = tool_copy,
                    .tool_use_id = id_copy,
                    .run_id = rid_copy,
                }) catch {
                    self.allocator.free(tool_copy);
                    if (id_copy) |id| self.allocator.free(id);
                    if (rid_copy) |rid| self.allocator.free(rid);
                };
            },
            else => {},
        }
    }

    fn recordMetricImpl(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flushImpl(_: *anyopaque) void {}
    fn nameImpl(_: *anyopaque) []const u8 {
        return "capturing_tool_events";
    }
};

fn makeSupervisedAgent(
    allocator: std.mem.Allocator,
    policy: *const SecurityPolicy,
    obs: observability.Observer,
) !Agent {
    return Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = obs,
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .policy = policy,
    };
}

test "approval gate: supervised mutating tool registers pending + emits event" {
    const allocator = std.testing.allocator;
    var capture = CapturingApprovalObserver.init(allocator);
    defer capture.deinit();
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, capture.observer());
    defer agent.deinit();

    // shell is mutating + critical risk; default registry covers it.
    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hi\"}",
        .tool_call_id = "call_xyz",
    };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.approval_required, result.blocked.source);
    try std.testing.expectEqualStrings("supervised_mutating_requires_approval", result.blocked.reason);

    // Pending approval state is set with owned, duped strings.
    try std.testing.expect(agent.pending_tool_approval != null);
    const pending = agent.pending_tool_approval.?;
    try std.testing.expectEqualStrings("shell", pending.tool_name);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", pending.arguments_json);
    try std.testing.expect(pending.tool_call_id != null);
    try std.testing.expectEqualStrings("call_xyz", pending.tool_call_id.?);
    try std.testing.expectEqual(tool_metadata.RiskLevel.critical, pending.risk_level);
    try std.testing.expect(pending.id != 0);

    // Approval event was emitted with only safe fields.
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const evt = capture.events.items[0];
    try std.testing.expectEqualStrings("shell", evt.tool);
    try std.testing.expectEqualStrings("critical", evt.risk_level);
    // The emitted payload must not leak raw argument content.
    try std.testing.expect(std.mem.indexOf(u8, evt.raw_data, "echo hi") == null);
    try std.testing.expect(std.mem.indexOf(u8, evt.raw_data, "command") == null);
}

test "approval gate: supervised read-only tool auto-approves without pending" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    const call = ParsedToolCall{ .name = "file_read", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .allowed);
    try std.testing.expect(agent.pending_tool_approval == null);
}

test "approval gate: operator-only tool denies under supervised" {
    const meta = tool_metadata.ToolMetadata{
        .name = "admin_ops",
        .flags = .{ .operator_only = true },
        .risk_level = .high,
    };
    try std.testing.expectEqual(
        Agent.ApprovalGateOutcome.deny,
        Agent.resolveApprovalGateOutcome(meta, .supervised),
    );
    // Sanity: under full autonomy the same meta auto-approves.
    try std.testing.expectEqual(
        Agent.ApprovalGateOutcome.allow,
        Agent.resolveApprovalGateOutcome(meta, .full),
    );
}

test "canonical policy boundary: preflight and SecurityPolicy.resolveApproval agree for known tools" {
    // Parity regression: the /permissions report path calls
    // `pol.resolveApproval(canonical_meta)` and the preflight path calls
    // `resolveApprovalGateOutcome(meta, autonomy)`. Both must see identical
    // metadata and resolve to identical verdicts — if the empty-registry
    // drift returns, this test breaks.
    const allocator = std.testing.allocator;
    const pol = SecurityPolicy{ .autonomy = .supervised };

    // file_read: declared read_only in the default registry.
    {
        const meta = tools_mod.canonicalMetadataForCall(allocator, "file_read", "{}");
        try std.testing.expect(meta.flags.read_only);
        try std.testing.expectEqual(ApprovalPolicy.auto_approve, pol.resolveApproval(meta));
        try std.testing.expectEqual(Agent.ApprovalGateOutcome.allow, Agent.resolveApprovalGateOutcome(meta, pol.autonomy));
    }

    // shell: declared mutating in the default registry.
    {
        const meta = tools_mod.canonicalMetadataForCall(allocator, "shell", "{}");
        try std.testing.expect(meta.flags.mutating);
        try std.testing.expectEqual(ApprovalPolicy.confirm_once, pol.resolveApproval(meta));
        try std.testing.expectEqual(Agent.ApprovalGateOutcome.require_confirm, Agent.resolveApprovalGateOutcome(meta, pol.autonomy));
    }

    // schedule.list: refined from mutating → read_only by args-aware path.
    {
        const meta = tools_mod.canonicalMetadataForCall(allocator, "schedule", "{\"action\":\"list\"}");
        try std.testing.expect(meta.flags.read_only);
        try std.testing.expectEqual(ApprovalPolicy.auto_approve, pol.resolveApproval(meta));
        try std.testing.expectEqual(Agent.ApprovalGateOutcome.allow, Agent.resolveApprovalGateOutcome(meta, pol.autonomy));
    }

    // unknown tool: must stay conservative (confirm_once under supervised).
    {
        const meta = tools_mod.canonicalMetadataForCall(allocator, "mcp_unknown", "{}");
        try std.testing.expect(meta.flags.mutating);
        try std.testing.expectEqual(ApprovalPolicy.confirm_once, pol.resolveApproval(meta));
    }
}

test "approval gate: full autonomy allows mutating without approval" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .full, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    const call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .allowed);
    try std.testing.expect(agent.pending_tool_approval == null);
}

test "/approve deny clears pending tool approval and does not execute" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    const call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    _ = agent.preflightToolPolicy(call);
    try std.testing.expect(agent.pending_tool_approval != null);

    const resp = (try agent.handleSlashCommand("/approve deny")).?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "denied") != null);
    try std.testing.expect(agent.pending_tool_approval == null);
    // Legacy shell pending was never registered via this path.
    try std.testing.expect(agent.pending_exec_command == null);
}

test "/approve with wrong id leaves pending tool approval untouched" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    const call = ParsedToolCall{ .name = "shell", .arguments_json = "{}", .tool_call_id = null };
    _ = agent.preflightToolPolicy(call);
    const original_id = agent.pending_tool_approval.?.id;

    const wrong_cmd = try std.fmt.allocPrint(allocator, "/approve {d} allow-once", .{original_id + 99});
    defer allocator.free(wrong_cmd);
    const resp = (try agent.handleSlashCommand(wrong_cmd)).?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "mismatch") != null);
    try std.testing.expect(agent.pending_tool_approval != null);
    try std.testing.expectEqual(original_id, agent.pending_tool_approval.?.id);
}

/// Trivial deterministic test tool: echoes a single "value" argument. No I/O
/// so tests stay hermetic. Registered as mutating so the approval gate fires.
const EchoTool = struct {
    pub const tool_name = "test_echo_tool";
    pub const tool_description = "Test echo tool";
    pub const tool_params = "{}";
    pub const tool_metadata: @import("../tools/metadata.zig").ToolMetadata = .{
        .name = "test_echo_tool",
        .flags = .{ .mutating = true },
        .risk_level = .medium,
    };

    pub const vtable = tools_mod.ToolVTable(EchoTool);

    pub fn tool(self: *EchoTool) tools_mod.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *EchoTool, allocator: std.mem.Allocator, args: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        _ = self;
        const value: []const u8 = blk: {
            if (args.get("value")) |v| {
                if (v == .string) break :blk v.string;
            }
            break :blk "default";
        };
        const out = try std.fmt.allocPrint(allocator, "echoed:{s}", .{value});
        return .{ .success = true, .output = out };
    }
};

const StaticFailTool = struct {
    pub const tool_name = "test_static_fail_tool";
    pub const tool_description = "Test tool with a static failure";
    pub const tool_params = "{}";
    pub const vtable = tools_mod.ToolVTable(@This());

    pub fn tool(self: *@This()) tools_mod.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *@This(), _: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        _ = self;
        return tools_mod.ToolResult.fail("static failure");
    }
};

const CountingRuntimeInfoTool = struct {
    call_count: usize = 0,

    pub const tool_name = "runtime_info";
    pub const tool_description = "Test runtime_info tool";
    pub const tool_params = "{}";
    pub const vtable = tools_mod.ToolVTable(@This());

    pub fn tool(self: *@This()) tools_mod.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *@This(), allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        self.call_count += 1;
        return .{
            .success = true,
            .output = try allocator.dupe(u8, "runtime-info"),
        };
    }
};

test "V1.14.4 booth-readiness: approval_continues_turn defaults to true (regression lock)" {
    // Lock the production default at root.zig:507. The "approval drops
    // after click" bug (2026-04-18) was fixed by adding the
    // continue-turn synthetic message in commands.zig::handleGenericToolApprove
    // (lines 2711-2802). That fix is gated on this flag being `true`.
    //
    // If a future refactor accidentally flips the default to `false`,
    // every production approval would return raw tool output as the
    // /approve reply text — the agent's turn loop never sees the result,
    // never produces its next reasoning step, and the user sees the
    // same "approve drops instead of executing" symptom from 2026-04-18.
    //
    // Test-only sites at lines 10494, 10540, 10590, 10647 explicitly
    // set false to preserve legacy "tool output as reply" behavior in
    // tests that don't have a live provider.
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const tools_arr = [_]Tool{};
    const policy = SecurityPolicy{ .autonomy = .full, .workspace_dir = "/tmp" };

    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = tools_arr[0..],
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        // Note: NO explicit approval_continues_turn — relying on default.
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .policy = &policy,
    };
    defer allocator.free(agent.tool_specs);
    defer agent.history.deinit(allocator);

    try std.testing.expect(agent.approval_continues_turn);
}

test "/approve allow-once executes pending tool exactly once" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var echo_impl = EchoTool{};
    const echo_tool = echo_impl.tool();
    const tools_arr = [_]Tool{echo_tool};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };

    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = tools_arr[0..],
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .approval_continues_turn = false,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .policy = &policy,
    };
    defer agent.deinit();

    // test_echo_tool is unknown to the default registry — falls back to
    // conservative mutating metadata, so supervised requires approval.
    const call = ParsedToolCall{
        .name = "test_echo_tool",
        .arguments_json = "{\"value\":\"hello\"}",
        .tool_call_id = null,
    };
    const preflight = agent.preflightToolPolicy(call);
    try std.testing.expectEqual(Agent.ToolPreflightSource.approval_required, preflight.blocked.source);
    try std.testing.expect(agent.pending_tool_approval != null);

    const resp = (try agent.handleSlashCommand("/approve allow-once")).?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "echoed:hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "success=true") != null);
    try std.testing.expect(agent.pending_tool_approval == null);
    try std.testing.expect(!agent.approval_bypass_active);
}

test "/approve allow-once handles static failure output without freeing literals" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var fail_impl = StaticFailTool{};
    const fail_tool = fail_impl.tool();
    const tools_arr = [_]Tool{fail_tool};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };

    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = tools_arr[0..],
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .approval_continues_turn = false,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .policy = &policy,
    };
    defer agent.deinit();

    const call = ParsedToolCall{
        .name = "test_static_fail_tool",
        .arguments_json = "{}",
        .tool_call_id = null,
    };
    const preflight = agent.preflightToolPolicy(call);
    try std.testing.expectEqual(Agent.ToolPreflightSource.approval_required, preflight.blocked.source);
    try std.testing.expect(agent.pending_tool_approval != null);

    const resp = (try agent.handleSlashCommand("/approve allow-once")).?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "success=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "static failure") != null);
    try std.testing.expect(agent.pending_tool_approval == null);
}

test "approval gate does not consume budget until allow-once executes the tool" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var echo_impl = EchoTool{};
    const echo_tool = echo_impl.tool();
    const tools_arr = [_]Tool{echo_tool};
    var tracker = RateTracker.init(allocator, 1);
    defer tracker.deinit();
    const policy = SecurityPolicy{
        .autonomy = .supervised,
        .workspace_dir = "/tmp",
        .max_actions_per_hour = 1,
        .tracker = &tracker,
    };

    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = tools_arr[0..],
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .approval_continues_turn = false,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .policy = &policy,
    };
    defer agent.deinit();

    const call = ParsedToolCall{
        .name = "test_echo_tool",
        .arguments_json = "{\"value\":\"hello\"}",
        .tool_call_id = null,
    };

    const preflight = agent.preflightToolPolicy(call);
    try std.testing.expectEqual(Agent.ToolPreflightSource.approval_required, preflight.blocked.source);
    try std.testing.expect(agent.pending_tool_approval != null);
    try std.testing.expectEqual(@as(usize, 0), tracker.count());

    const resp = (try agent.handleSlashCommand("/approve allow-once")).?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "echoed:hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "success=true") != null);
    try std.testing.expectEqual(@as(usize, 1), tracker.count());

    const second = agent.preflightToolPolicy(call);
    try std.testing.expect(second == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.action_budget, second.blocked.source);
    try std.testing.expect(agent.pending_tool_approval == null);
}

test "approval-required tool stops serial dispatch before later safe tools run" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var echo_impl = EchoTool{};
    var runtime_impl = CountingRuntimeInfoTool{};
    const tools_arr = [_]Tool{ echo_impl.tool(), runtime_impl.tool() };
    var tracker = RateTracker.init(allocator, 1);
    defer tracker.deinit();
    const policy = SecurityPolicy{
        .autonomy = .supervised,
        .workspace_dir = "/tmp",
        .max_actions_per_hour = 1,
        .tracker = &tracker,
    };

    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = tools_arr[0..],
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .approval_continues_turn = false,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .policy = &policy,
    };
    defer agent.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const calls = [_]ParsedToolCall{
        .{
            .name = "test_echo_tool",
            .arguments_json = "{\"value\":\"hello\"}",
            .tool_call_id = "call-1",
        },
        .{
            .name = "runtime_info",
            .arguments_json = "{}",
            .tool_call_id = "call-2",
        },
    };
    var results_buf: std.ArrayListUnmanaged(ToolExecutionResult) = .empty;
    defer results_buf.deinit(allocator);
    try results_buf.ensureTotalCapacity(allocator, calls.len);
    try agent.executeToolCallsSerial(arena.allocator(), 0, calls[0..], &results_buf);

    try std.testing.expectEqual(@as(usize, 1), results_buf.items.len);
    try std.testing.expect(agent.pending_tool_approval != null);
    try std.testing.expect(std.mem.indexOf(u8, results_buf.items[0].output, "Approval required") != null);
    try std.testing.expectEqual(@as(usize, 0), tracker.count());
    try std.testing.expectEqual(@as(usize, 0), runtime_impl.call_count);
}

test "turn returns approval prompt without another provider roundtrip" {
    const ApprovalPendingProvider = struct {
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
                    .id = try allocator.dupe(u8, "call-approval"),
                    .name = try allocator.dupe(u8, "test_echo_tool"),
                    .arguments = try allocator.dupe(u8, "{\"value\":\"hello\"}"),
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
            return "approval-pending-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var provider_state = ApprovalPendingProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ApprovalPendingProvider.chatWithSystem,
        .chat = ApprovalPendingProvider.chat,
        .supportsNativeTools = ApprovalPendingProvider.supportsNativeTools,
        .getName = ApprovalPendingProvider.getName,
        .deinit = ApprovalPendingProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var echo_impl = EchoTool{};
    const tool_list = [_]Tool{echo_impl.tool()};
    const specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |tool, i| {
        specs[i] = .{
            .name = tool.name(),
            .description = tool.description(),
            .parameters_json = tool.parametersJson(),
        };
    }

    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
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
        .policy = &policy,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("run tool");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Approval required for tool test_echo_tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/approve 1 allow-once|deny") != null);
    try std.testing.expectEqual(@as(usize, 1), provider_state.call_count);
    try std.testing.expect(agent.pending_tool_approval != null);
}

test "turn preserves prior tool results in history before approval prompt" {
    const ApprovalAfterSafeToolProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            const tool_calls = try allocator.alloc(providers.ToolCall, 2);
            tool_calls[0] = .{
                .id = try allocator.dupe(u8, "call-safe"),
                .name = try allocator.dupe(u8, "runtime_info"),
                .arguments = try allocator.dupe(u8, "{}"),
            };
            tool_calls[1] = .{
                .id = try allocator.dupe(u8, "call-approval"),
                .name = try allocator.dupe(u8, "test_echo_tool"),
                .arguments = try allocator.dupe(u8, "{\"value\":\"hello\"}"),
            };
            return .{
                .content = try allocator.dupe(u8, "running"),
                .tool_calls = tool_calls,
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return true;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "approval-after-safe-tool-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var provider_state = ApprovalAfterSafeToolProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ApprovalAfterSafeToolProvider.chatWithSystem,
        .chat = ApprovalAfterSafeToolProvider.chat,
        .supportsNativeTools = ApprovalAfterSafeToolProvider.supportsNativeTools,
        .getName = ApprovalAfterSafeToolProvider.getName,
        .deinit = ApprovalAfterSafeToolProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var echo_impl = EchoTool{};
    var runtime_impl = CountingRuntimeInfoTool{};
    const tool_list = [_]Tool{ runtime_impl.tool(), echo_impl.tool() };
    const specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |tool, i| {
        specs[i] = .{
            .name = tool.name(),
            .description = tool.description(),
            .parameters_json = tool.parametersJson(),
        };
    }

    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
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
        .policy = &policy,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("run tool");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Approval required for tool test_echo_tool") != null);
    try std.testing.expectEqual(@as(usize, 1), provider_state.call_count);
    try std.testing.expectEqual(@as(usize, 1), runtime_impl.call_count);
    try std.testing.expect(agent.history.items.len >= 2);

    const tool_history = agent.history.items[agent.history.items.len - 2];
    try std.testing.expectEqual(providers.Role.user, tool_history.role);
    try std.testing.expect(std.mem.indexOf(u8, tool_history.content, "runtime-info") != null);

    const approval_history = agent.history.items[agent.history.items.len - 1];
    try std.testing.expectEqual(providers.Role.assistant, approval_history.role);
    try std.testing.expect(std.mem.indexOf(u8, approval_history.content, "Approval required for tool test_echo_tool") != null);
}

test "approval gate checks exhausted budget before registering pending approval" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var tracker = RateTracker.init(allocator, 1);
    defer tracker.deinit();
    const policy = SecurityPolicy{
        .autonomy = .supervised,
        .workspace_dir = "/tmp",
        .max_actions_per_hour = 1,
        .tracker = &tracker,
    };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    const consume_call = ParsedToolCall{
        .name = "runtime_info",
        .arguments_json = "{}",
        .tool_call_id = null,
    };
    try std.testing.expect(agent.preflightToolPolicy(consume_call) == .allowed);
    try std.testing.expectEqual(@as(usize, 1), tracker.count());

    const mutating_call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hi\"}",
        .tool_call_id = null,
    };
    const blocked = agent.preflightToolPolicy(mutating_call);
    try std.testing.expect(blocked == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.action_budget, blocked.blocked.source);
    try std.testing.expect(agent.pending_tool_approval == null);
}

test "approval gate: second pending request does not overwrite the first" {
    const allocator = std.testing.allocator;
    var capture = CapturingApprovalObserver.init(allocator);
    defer capture.deinit();
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, capture.observer());
    defer agent.deinit();

    const first_call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo first\"}",
        .tool_call_id = "call_first",
    };
    const first_result = agent.preflightToolPolicy(first_call);
    try std.testing.expect(first_result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.approval_required, first_result.blocked.source);
    try std.testing.expectEqualStrings("supervised_mutating_requires_approval", first_result.blocked.reason);

    const first_pending_id = agent.pending_tool_approval.?.id;
    const first_args = agent.pending_tool_approval.?.arguments_json;
    try std.testing.expectEqualStrings("{\"command\":\"echo first\"}", first_args);
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);

    // Second supervised mutating call must NOT overwrite the first pending.
    const second_call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo second\"}",
        .tool_call_id = "call_second",
    };
    const second_result = agent.preflightToolPolicy(second_call);
    try std.testing.expect(second_result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.approval_required, second_result.blocked.source);
    try std.testing.expectEqualStrings("approval_already_pending", second_result.blocked.reason);
    try std.testing.expect(std.mem.indexOf(u8, second_result.blocked.output, "already pending") != null);

    // First pending is unchanged — id and arguments preserved verbatim.
    try std.testing.expect(agent.pending_tool_approval != null);
    try std.testing.expectEqual(first_pending_id, agent.pending_tool_approval.?.id);
    try std.testing.expectEqualStrings(
        "{\"command\":\"echo first\"}",
        agent.pending_tool_approval.?.arguments_json,
    );
    try std.testing.expectEqualStrings("call_first", agent.pending_tool_approval.?.tool_call_id.?);

    // No second approval_required event was emitted.
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
}

test "/approve <id> does not cross namespace from generic to legacy shell when generic is null" {
    // S2 audit regression. `pending_exec_id` and
    // `pending_tool_approval_id_counter` are independent u64 counters,
    // so a numeric id captured by the gateway for a generic-namespace
    // approval can coincidentally match a legacy shell pending. Pre-fix
    // the canonical handler would fall through to the legacy branch
    // and execute the shell command — the user clicked "Approve Tool X"
    // and a shell command they never saw approved would run. The fix
    // refuses to fall through when an id was supplied; the legacy plain
    // form `/approve allow-once` still resolves shell approvals.
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

    // Force the cross-namespace collision setup: generic is null, but
    // a legacy shell pending exists with pending_exec_id=42 — the same
    // id the gateway would have captured from a generic apr-42.
    const exec_resp = (try agent.handleSlashCommand("/exec ask=always")).?;
    defer allocator.free(exec_resp);
    const pending_resp = (try agent.handleSlashCommand("/bash echo cross-namespace-canary")).?;
    defer allocator.free(pending_resp);
    try std.testing.expect(agent.pending_exec_command != null);
    agent.pending_exec_id = 42;
    try std.testing.expect(agent.pending_tool_approval == null);

    // Gateway-style id-qualified slash (the fixed gateway always builds
    // this form when the FE supplied approval_id) must NOT resolve the
    // legacy pending, even though the numeric ids match by coincidence.
    const approve_resp = (try agent.handleSlashCommand("/approve 42 allow-once")).?;
    defer allocator.free(approve_resp);
    try std.testing.expect(std.mem.startsWith(u8, approve_resp, "Approval id mismatch"));
    // Legacy pending stays intact — the canonical handler did not run
    // the shell command. The next plain `/approve allow-once` (no id)
    // is the user's escape hatch to resolve the legacy slot.
    try std.testing.expect(agent.pending_exec_command != null);
    try std.testing.expectEqualStrings("echo cross-namespace-canary", agent.pending_exec_command.?);
    try std.testing.expectEqual(@as(u64, 42), agent.pending_exec_id);
}

test "legacy shell /approve flow preserved when no generic pending approval" {
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

    // No generic pending — legacy shell approval path must still work.
    try std.testing.expect(agent.pending_tool_approval == null);

    const exec_resp = (try agent.handleSlashCommand("/exec ask=always")).?;
    defer allocator.free(exec_resp);

    const pending_resp = (try agent.handleSlashCommand("/bash echo legacy-check")).?;
    defer allocator.free(pending_resp);
    try std.testing.expect(agent.pending_exec_command != null);

    // The generic pending slot was never populated.
    try std.testing.expect(agent.pending_tool_approval == null);

    const approve_resp = (try agent.handleSlashCommand("/approve allow-once")).?;
    defer allocator.free(approve_resp);
    try std.testing.expect(std.mem.indexOf(u8, approve_resp, "Approved exec") != null);
    try std.testing.expect(agent.pending_exec_command == null);
}

// ── WP1.3 Run ID + tool event correlation tests ────────────────────

test "approval_required event carries run_id when current_run_id is set" {
    const allocator = std.testing.allocator;
    var capture = CapturingApprovalObserver.init(allocator);
    defer capture.deinit();
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, capture.observer());
    defer agent.deinit();

    // Simulate the run-ID lifecycle that turn() establishes.
    agent.run_id_counter = 1;
    const rid_slice = try std.fmt.bufPrint(&agent.current_run_id_buf, "r-{d}-{d}", .{
        @as(i64, 12345),
        agent.run_id_counter,
    });
    agent.current_run_id = rid_slice;
    defer agent.current_run_id = null;

    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hi\"}",
        .tool_call_id = "call_abc",
    };
    const result = agent.preflightToolPolicy(call);
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(Agent.ToolPreflightSource.approval_required, result.blocked.source);

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const evt = capture.events.items[0];
    try std.testing.expect(evt.run_id != null);
    try std.testing.expectEqualStrings(rid_slice, evt.run_id.?);
}

test "approval_required event has null run_id when none active" {
    const allocator = std.testing.allocator;
    var capture = CapturingApprovalObserver.init(allocator);
    defer capture.deinit();
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, capture.observer());
    defer agent.deinit();

    try std.testing.expect(agent.current_run_id == null);
    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hi\"}",
        .tool_call_id = "call_xyz",
    };
    _ = agent.preflightToolPolicy(call);
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    try std.testing.expect(capture.events.items[0].run_id == null);
}

test "tool dispatch emits tool_start and tool_result with matching run_id and tool_use_id" {
    const allocator = std.testing.allocator;
    var capture = CapturingToolEventObserver.init(allocator);
    defer capture.deinit();

    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = capture.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    // Establish a turn-scoped run ID.
    agent.run_id_counter = 7;
    const rid_slice = try std.fmt.bufPrint(&agent.current_run_id_buf, "r-{d}-{d}", .{
        @as(i64, 99999),
        agent.run_id_counter,
    });
    agent.current_run_id = rid_slice;
    defer agent.current_run_id = null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // No tool registered → executeTool returns "Unknown tool" but the
    // start/result events still fire and must carry the run_id.
    const call = ParsedToolCall{
        .name = "ghost_tool",
        .arguments_json = "{}",
        .tool_call_id = "call_match_1",
    };
    const calls = [_]ParsedToolCall{call};
    var results_buf: std.ArrayListUnmanaged(ToolExecutionResult) = .empty;
    defer results_buf.deinit(allocator);
    try results_buf.ensureTotalCapacity(allocator, calls.len);
    try agent.executeToolCallsSerial(arena.allocator(), 0, calls[0..], &results_buf);

    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    const start_evt = capture.events.items[0];
    const result_evt = capture.events.items[1];
    try std.testing.expectEqual(@as(@TypeOf(start_evt.kind), .start), start_evt.kind);
    try std.testing.expectEqual(@as(@TypeOf(result_evt.kind), .result), result_evt.kind);
    try std.testing.expect(start_evt.run_id != null);
    try std.testing.expect(result_evt.run_id != null);
    try std.testing.expectEqualStrings(rid_slice, start_evt.run_id.?);
    try std.testing.expectEqualStrings(rid_slice, result_evt.run_id.?);
    try std.testing.expect(start_evt.tool_use_id != null);
    try std.testing.expect(result_evt.tool_use_id != null);
    try std.testing.expectEqualStrings("call_match_1", start_evt.tool_use_id.?);
    try std.testing.expectEqualStrings("call_match_1", result_evt.tool_use_id.?);
}

test "Agent.run_id_counter increments and remains stable across event emit sites" {
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
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    try std.testing.expectEqual(@as(u64, 0), agent.run_id_counter);
    try std.testing.expect(agent.current_run_id == null);
}

test "/permissions without policy reports not-configured and exec posture" {
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
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const resp = (try agent.handleSlashCommand("/permissions")).?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "not configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Gate 1 — Execution mode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Gate 2 — Generic tool approval:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Gate 3 — Legacy shell /exec:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "host:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "security:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ask:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Execution mode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Pending approvals: none") != null);
}

test "/permissions with supervised policy reports autonomy and approval rules" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{
        .autonomy = .supervised,
        .workspace_dir = "/tmp/work",
        .workspace_only = true,
        .max_actions_per_hour = 42,
    };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    const resp = (try agent.handleSlashCommand("/permissions")).?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "status: configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "autonomy: supervised") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "/tmp/work") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "workspace_only: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "max_actions_per_hour: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "rate_limited: no") != null);
    // Approval rules under supervised
    try std.testing.expect(std.mem.indexOf(u8, resp, "read-only tools:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "auto_approve") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "confirm_once") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "allow-always is not persistent in v1") != null);
}

test "/permissions reports pending tool approval and does not clear it" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    // shell is mutating + critical risk; supervised => registers pending approval.
    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo secret-arg\"}",
        .tool_call_id = "call_xyz",
    };
    _ = agent.preflightToolPolicy(call);
    try std.testing.expect(agent.pending_tool_approval != null);
    const pending_id = agent.pending_tool_approval.?.id;

    const resp = (try agent.handleSlashCommand("/permissions")).?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "Pending tool approval:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "tool: shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "risk: critical") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "supervised_mutating_requires_approval") != null);
    const id_str = try std.fmt.allocPrint(allocator, "id: {d}", .{pending_id});
    defer allocator.free(id_str);
    try std.testing.expect(std.mem.indexOf(u8, resp, id_str) != null);

    // Raw generic arguments must never leak.
    try std.testing.expect(std.mem.indexOf(u8, resp, "secret-arg") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "arguments_json") == null);

    // Report is read-only: the pending approval must still be present.
    try std.testing.expect(agent.pending_tool_approval != null);
    try std.testing.expectEqual(pending_id, agent.pending_tool_approval.?.id);
}

test "/permissions reports pending exec command and does not clear it" {
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
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    // Register a legacy pending exec command by hand (mirrors setPendingExecCommand).
    agent.pending_exec_command = try allocator.dupe(u8, "ls -la /tmp");
    agent.pending_exec_command_owned = true;
    agent.pending_exec_id = 7;

    const resp = (try agent.handleSlashCommand("/permissions")).?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "Pending exec approval:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "id: 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "command: ls -la /tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "allow-once|allow-always|deny") != null);

    // Report is read-only: the pending exec must still be present.
    try std.testing.expect(agent.pending_exec_command != null);
    try std.testing.expectEqualStrings("ls -la /tmp", agent.pending_exec_command.?);
    try std.testing.expectEqual(@as(u64, 7), agent.pending_exec_id);
}

test "/perm alias returns same class of report as /permissions" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    const policy = SecurityPolicy{ .autonomy = .supervised, .workspace_dir = "/tmp" };
    var agent = try makeSupervisedAgent(allocator, &policy, noop.observer());
    defer agent.deinit();

    const long_form = (try agent.handleSlashCommand("/permissions")).?;
    defer allocator.free(long_form);
    const alias_form = (try agent.handleSlashCommand("/perm")).?;
    defer allocator.free(alias_form);

    // Both reports start with the same header and mention the configured autonomy.
    try std.testing.expect(std.mem.startsWith(u8, long_form, "Permissions (read-only report)"));
    try std.testing.expect(std.mem.startsWith(u8, alias_form, "Permissions (read-only report)"));
    try std.testing.expect(std.mem.indexOf(u8, alias_form, "autonomy: supervised") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_form, "Gate 1 — Execution mode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_form, "Gate 2 — Generic tool approval:") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_form, "Gate 3 — Legacy shell /exec:") != null);
}

test "TurnOutcome.justText constructs text-only outcome with empty defaults" {
    const text = try std.testing.allocator.dupe(u8, "hello");
    var outcome = Agent.TurnOutcome.justText(text);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", outcome.text);
    try std.testing.expect(!outcome.tool_only_turn);
    try std.testing.expectEqual(@as(usize, 0), outcome.tool_calls_executed.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.spawned_task_ids.len);
    try std.testing.expectEqual(@as(u32, 0), outcome.iterations_used);
    try std.testing.expect(!outcome.loop_detected);
}

test "TurnOutcome.deinit frees text + tool_calls_executed + spawned_task_ids" {
    // This test exists to pin the ownership contract. If a future
    // change adds an owned slice to TurnOutcome but forgets to free
    // it in deinit, std.testing.allocator's leak detector catches it.
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "tool-only result text");

    const tool_names = try allocator.alloc([]const u8, 2);
    tool_names[0] = try allocator.dupe(u8, "memory_recall");
    tool_names[1] = try allocator.dupe(u8, "web_search");

    const task_ids = try allocator.alloc([]const u8, 1);
    task_ids[0] = try allocator.dupe(u8, "task-42");

    const outcome = Agent.TurnOutcome{
        .text = text,
        .tool_only_turn = true,
        .tool_calls_executed = tool_names,
        .spawned_task_ids = task_ids,
        .iterations_used = 3,
        .loop_detected = false,
    };
    outcome.deinit(allocator);
    // No expect — the assertion is the absence of leaks.
}

test "TurnOutcome tool_only_turn flag distinguishes empty-text-with-spawns from nothing-happened" {
    // When the model emits spawn calls but no post-tool text, gateway
    // needs a signal richer than `text.len == 0` to render the right
    // UI (today the gateway falls back to EMPTY_TURN_PLACEHOLDER; the
    // structured tool_only_turn frame from D1.4 will check this flag).
    const allocator = std.testing.allocator;

    // Case A: text-only, NOT a tool-only turn even though no spawns.
    var case_a = Agent.TurnOutcome.justText(try allocator.dupe(u8, "ok"));
    defer case_a.deinit(allocator);
    try std.testing.expect(!case_a.tool_only_turn);

    // Case B: empty text + spawned task → tool-only turn.
    const empty_text = try allocator.dupe(u8, "");
    const tasks = try allocator.alloc([]const u8, 1);
    tasks[0] = try allocator.dupe(u8, "task-1");
    const case_b = Agent.TurnOutcome{
        .text = empty_text,
        .tool_only_turn = true,
        .spawned_task_ids = tasks,
    };
    defer case_b.deinit(allocator);
    try std.testing.expect(case_b.tool_only_turn);
    try std.testing.expectEqualStrings("", case_b.text);
    try std.testing.expectEqual(@as(usize, 1), case_b.spawned_task_ids.len);
    try std.testing.expectEqualStrings("task-1", case_b.spawned_task_ids[0]);
}

// ═══════════════════════════════════════════════════════════════════════════
// V1.14.7 C1 — extraction trigger gates
// ═══════════════════════════════════════════════════════════════════════════

test "ExtractionConfig defaults disable all per-turn legacy triggers (V1.14.7 C3)" {
    // C3 contract: defaults are all FALSE — per-turn extraction is the legacy
    // path; new architecture extracts at compaction + session-end + agent-
    // explicit moments. Operators can flip true to re-enable legacy triggers,
    // but the trigger SITES were deleted in C3 — flipping true is a no-op
    // unless C3 is reverted.
    const cfg = config_types.ExtractionConfig{};
    try std.testing.expect(!cfg.per_turn_enqueue_enabled);
    try std.testing.expect(!cfg.memory_nudge_enabled);
    try std.testing.expect(!cfg.skills_nudge_enabled);
}

test "AgentConfig.extraction defaults to ExtractionConfig{}" {
    // Plumbing: AgentConfig carries an ExtractionConfig field with its
    // default-initialized value. Defaults updated to false in C3.
    const cfg = config_types.AgentConfig{};
    try std.testing.expect(!cfg.extraction.per_turn_enqueue_enabled);
    try std.testing.expect(!cfg.extraction.memory_nudge_enabled);
    try std.testing.expect(!cfg.extraction.skills_nudge_enabled);

    // Operator can flip individual flags via TOML [agent.extraction] —
    // the FIELD remains writable for forward compat.
    const operator_set = config_types.AgentConfig{
        .extraction = .{ .memory_nudge_enabled = true },
    };
    try std.testing.expect(!operator_set.extraction.per_turn_enqueue_enabled);
    try std.testing.expect(operator_set.extraction.memory_nudge_enabled);
    try std.testing.expect(!operator_set.extraction.skills_nudge_enabled);
}

test "memory_nudge gate disables append when memory_nudge_enabled=false" {
    // C1 behavior verification: with the gate flipped to false, the
    // turn-loop's memory_nudge site short-circuits — the counter resets
    // (so we don't burst-fire on a flag flip mid-session) but no
    // SYSTEM message is appended to history. Reference: turn loop site
    // at root.zig:4014 area.
    //
    // We exercise just the gate's bookkeeping by driving the counter
    // directly on an Agent struct. A full turn-loop integration is
    // covered in the autoCompactHistory test suite.
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
        .temperature = 0.0,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 1,
        .max_history_messages = 0,
        .token_limit = 1_000,
        .max_tokens = 64,
        .compact_context_enabled = false,
        .auto_save = false,
        .history = .empty,
        .extraction_cfg = .{ .memory_nudge_enabled = false },
        .turns_since_memory_nudge = 9,
    };
    defer agent.deinit();

    // Simulate the gate's counter logic from the turn loop:
    //   self.turns_since_memory_nudge += 1;
    //   if (>=10 and !enabled) { reset; log "extraction.gated"; return }
    //   if (>=10 and enabled)  { reset; append nudge to history; ... }
    agent.turns_since_memory_nudge += 1;
    const at_threshold = agent.turns_since_memory_nudge >= 10;
    const gated = at_threshold and !agent.extraction_cfg.memory_nudge_enabled;
    if (gated) agent.turns_since_memory_nudge = 0;

    try std.testing.expect(at_threshold);
    try std.testing.expect(gated);
    try std.testing.expectEqual(@as(u32, 0), agent.turns_since_memory_nudge);
    // No nudge appended → history stays empty.
    try std.testing.expectEqual(@as(usize, 0), agent.history.items.len);
}

test "per_turn_enqueue gate skips enqueue when per_turn_enqueue_enabled=false" {
    // Same shape as the memory_nudge test, for the per-3-turn entity_pipeline
    // enqueue trigger at root.zig:4088 area.
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
        .temperature = 0.0,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 1,
        .max_history_messages = 0,
        .token_limit = 1_000,
        .max_tokens = 64,
        .compact_context_enabled = false,
        .auto_save = false,
        .history = .empty,
        .extraction_cfg = .{ .per_turn_enqueue_enabled = false },
        .turns_since_extraction = 2,
    };
    defer agent.deinit();

    agent.turns_since_extraction += 1;
    const at_threshold = agent.turns_since_extraction >= 3;
    const gated = at_threshold and !agent.extraction_cfg.per_turn_enqueue_enabled;
    if (gated) agent.turns_since_extraction = 0;

    try std.testing.expect(at_threshold);
    try std.testing.expect(gated);
    try std.testing.expectEqual(@as(u32, 0), agent.turns_since_extraction);
    // Counter reset prevents burst-fire on a flag flip; no enqueue happened
    // (extraction_state_mgr is null so even at default-true this test would
    // skip the enqueue body — the assertion that matters is the gated branch).
}

test "skills_nudge gate predicate evaluates correctly across enabled states" {
    // C3 contract: skills_nudge_enabled defaults to false (legacy site
    // deleted). The SHAPE of the predicate is preserved for any future
    // re-enable, even though the trigger code path is gone. This test
    // exercises only the predicate calculation, not the deleted site.
    const turn_tool_calls_total: u32 = 7;
    const last_turn_tool_count: u32 = 0;
    const workspace_set = true;

    // Default config (skills_nudge_enabled=false post-C3) → predicate false.
    const cfg_default = config_types.ExtractionConfig{};
    try std.testing.expect(!cfg_default.skills_nudge_enabled);
    const default_would_fire = turn_tool_calls_total >= 5 and workspace_set and
        last_turn_tool_count < 5 and cfg_default.skills_nudge_enabled;
    try std.testing.expect(!default_would_fire);

    // Operator-overridden true → predicate true (counterfactual).
    const cfg_legacy = config_types.ExtractionConfig{ .skills_nudge_enabled = true };
    const legacy_would_fire = turn_tool_calls_total >= 5 and workspace_set and
        last_turn_tool_count < 5 and cfg_legacy.skills_nudge_enabled;
    try std.testing.expect(legacy_would_fire);
}

// INFO-4 (v1.14.23 review): synthMoonshotFilename derives a filename
// from the validated media_type so Moonshot's filename-based
// content-type hint stays media-aligned even when the source file_path
// is a tempfile with a `.bin` extension.

test "synthMoonshotFilename uses media_type subtype as extension" {
    const allocator = std.testing.allocator;
    const name = try Agent.synthMoonshotFilename(allocator, "video/mp4");
    defer allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "upload-"));
    try std.testing.expect(std.mem.endsWith(u8, name, ".mp4"));
}

test "synthMoonshotFilename handles webm and quicktime subtypes" {
    const allocator = std.testing.allocator;
    const webm = try Agent.synthMoonshotFilename(allocator, "video/webm");
    defer allocator.free(webm);
    try std.testing.expect(std.mem.endsWith(u8, webm, ".webm"));

    const qt = try Agent.synthMoonshotFilename(allocator, "video/quicktime");
    defer allocator.free(qt);
    try std.testing.expect(std.mem.endsWith(u8, qt, ".quicktime"));
}

test "synthMoonshotFilename falls back to mp4 on malformed media_type" {
    const allocator = std.testing.allocator;
    const malformed_cases = [_][]const u8{
        "",
        "not-a-mime",
        "image/png", // not video/* prefix
        "video/",
        "video/mp4; codecs=avc1", // illegal characters in subtype
        "video/../../etc/passwd", // path traversal attempt
        "video/" ++ ("x" ** 32), // overlong subtype
    };
    for (malformed_cases) |mt| {
        const name = try Agent.synthMoonshotFilename(allocator, mt);
        defer allocator.free(name);
        try std.testing.expect(std.mem.endsWith(u8, name, ".mp4"));
    }
}
