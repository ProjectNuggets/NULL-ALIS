//! Context Engine — per-turn lifecycle for context management.
//!
//! Formalizes the 4-phase context lifecycle:
//!   1. ingest   — accept new user input + memory context
//!   2. assemble — build prompt refresh plan, resolve stable prefix
//!   3. compact  — trigger compaction if token pressure exceeded
//!   4. afterTurn — record stats, persist checkpoint if needed
//!
//! The engine is stateless between turns. Each turn creates a fresh
//! TurnContext that flows through the phases.

const std = @import("std");
const context_builder = @import("context_builder.zig");
const context_cache = @import("context_cache.zig");
const compaction = @import("compaction.zig");

// ── Internal stages (W1.2) ─────────────────────────────────────────────────
// `context_engine` is the single public entry point for turn-packet assembly.
// The two modules below were previously public peers; they are now re-exported
// as internals of context_engine. External consumers should reach them via
// `agent.context_engine.builder` and `agent.context_engine.memory_loader`.
// Behavior is unchanged; this is a public-surface collapse only.

pub const builder = context_builder;
pub const memory_loader = @import("memory_loader.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Phase Enum
// ═══════════════════════════════════════════════════════════════════════════

pub const LifecyclePhase = enum {
    idle,
    ingesting,
    assembling,
    compacting,
    after_turn,

    pub fn toSlice(self: LifecyclePhase) []const u8 {
        return switch (self) {
            .idle => "idle",
            .ingesting => "ingesting",
            .assembling => "assembling",
            .compacting => "compacting",
            .after_turn => "after_turn",
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Result Types
// ═══════════════════════════════════════════════════════════════════════════

/// Output of the ingest phase.
pub const IngestResult = struct {
    memory_enriched: bool = false,
    memory_context_bytes: usize = 0,
    memory_enrich_ms: u64 = 0,
    message_count_before: usize = 0,
    message_count_after: usize = 0,
};

/// Output of the assemble phase.
pub const AssembleResult = struct {
    prompt_refreshed: bool = false,
    workspace_prompt_changed: bool = false,
    time_bucket_changed: bool = false,
    conversation_context_changed: bool = false,
    stable_prefix_state: context_cache.StablePrefixState = .{},
    token_estimate: u64 = 0,
    context_pressure_percent: u8 = 0,
    compaction_recommended: bool = false,
};

/// Output of the compact phase.
pub const CompactResult = struct {
    compacted: bool = false,
    messages_before: usize = 0,
    messages_after: usize = 0,
    method: CompactMethod = .none,

    pub const CompactMethod = enum {
        none,
        auto,
        force_compress,
    };
};

/// Aggregated output of all 4 lifecycle phases.
pub const TurnContextResult = struct {
    ingest: IngestResult = .{},
    assemble: AssembleResult = .{},
    compact: CompactResult = .{},
    last_turn: context_builder.LastTurnContext = .{},
    total_duration_ms: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════
// ContextEngine
// ═══════════════════════════════════════════════════════════════════════════

/// ContextEngine coordinates the per-turn context lifecycle.
///
/// The engine is stateless between turns — it holds only the current phase
/// indicator (for diagnostics/assertions). Create one per Agent; call the
/// four lifecycle methods in order each turn.
pub const ContextEngine = struct {
    phase: LifecyclePhase = .idle,

    /// Phase 1: Ingest — record what came in this turn.
    ///
    /// Called after the user message is added to history but before the LLM
    /// call. Reads last_turn_context from the agent to capture memory
    /// enrichment stats that were written during the current turn setup.
    pub fn ingest(self: *ContextEngine, agent: anytype) IngestResult {
        self.phase = .ingesting;
        defer self.phase = .idle;

        const AgentType = @TypeOf(agent.*);
        const history_count = if (@hasField(AgentType, "history")) agent.history.items.len else 0;
        const memory_enriched = if (@hasField(AgentType, "last_turn_context"))
            agent.last_turn_context.memory_context_injected
        else
            false;
        const memory_bytes = if (@hasField(AgentType, "last_turn_context"))
            agent.last_turn_context.memory_context_bytes
        else
            0;
        const memory_ms = if (@hasField(AgentType, "last_turn_context"))
            agent.last_turn_context.memory_enrich_ms
        else
            0;

        return .{
            .memory_enriched = memory_enriched,
            .memory_context_bytes = memory_bytes,
            .memory_enrich_ms = memory_ms,
            .message_count_before = if (history_count > 0) history_count - 1 else 0,
            .message_count_after = history_count,
        };
    }

    /// Phase 2: Assemble — evaluate prompt refresh plan and token pressure.
    ///
    /// Called before building the LLM request to determine whether the
    /// system prompt needs refresh and whether compaction is recommended.
    pub fn assemble(self: *ContextEngine, agent: anytype) AssembleResult {
        self.phase = .assembling;
        defer self.phase = .idle;

        const AgentType = @TypeOf(agent.*);
        const snapshot = context_builder.buildSnapshot(agent);
        const has_system_prompt = snapshot.has_system_prompt;

        const refresh_plan = if (@hasField(AgentType, "has_system_prompt"))
            context_builder.buildPromptRefreshPlan(agent)
        else
            context_builder.PromptRefreshPlan{
                .current_time_bucket_min = -1,
                .workspace_prompt_fingerprint = null,
                .conversation_context_present = false,
                .conversation_context_fingerprint = 0,
                .workspace_prompt_changed = false,
                .time_bucket_changed = false,
                .conversation_context_changed = false,
                .should_refresh_system_prompt = !has_system_prompt,
            };

        const stable_prefix = context_cache.buildStablePrefixState(refresh_plan, has_system_prompt);

        return .{
            .prompt_refreshed = refresh_plan.should_refresh_system_prompt,
            .workspace_prompt_changed = refresh_plan.workspace_prompt_changed,
            .time_bucket_changed = refresh_plan.time_bucket_changed,
            .conversation_context_changed = refresh_plan.conversation_context_changed,
            .stable_prefix_state = stable_prefix,
            .token_estimate = snapshot.token_estimate,
            .context_pressure_percent = snapshot.context_pressure_percent,
            .compaction_recommended = snapshot.token_compaction_triggered,
        };
    }

    /// Phase 3: Compact — trigger compaction if token pressure requires it.
    ///
    /// Caller should check assemble_result.compaction_recommended first.
    /// Tries auto-compaction first; falls back to force-compress if needed.
    pub fn compact(self: *ContextEngine, agent: anytype) CompactResult {
        self.phase = .compacting;
        defer self.phase = .idle;

        const AgentType = @TypeOf(agent.*);
        const before = if (@hasField(AgentType, "history")) agent.history.items.len else 0;

        // Try auto-compaction first.
        if (@hasDecl(AgentType, "autoCompactHistory")) {
            if (agent.autoCompactHistory() catch false) {
                const after = agent.history.items.len;
                return .{
                    .compacted = true,
                    .messages_before = before,
                    .messages_after = after,
                    .method = .auto,
                };
            }
        }

        // Fall back to force-compress if auto did not help.
        if (@hasDecl(AgentType, "forceCompressHistory")) {
            if (agent.forceCompressHistory()) {
                const after = agent.history.items.len;
                return .{
                    .compacted = true,
                    .messages_before = before,
                    .messages_after = after,
                    .method = .force_compress,
                };
            }
        }

        return .{
            .compacted = false,
            .messages_before = before,
            .messages_after = before,
            .method = .none,
        };
    }

    /// Phase 4: After Turn — record lifecycle stats for reporting.
    ///
    /// Called after the LLM response has been received and processed.
    /// Aggregates results from the three earlier phases into a
    /// TurnContextResult which can be stored as last_turn_context.
    pub fn afterTurn(
        self: *ContextEngine,
        ingest_result: IngestResult,
        assemble_result: AssembleResult,
        compact_result: CompactResult,
        start_ms: i64,
    ) TurnContextResult {
        self.phase = .after_turn;
        defer self.phase = .idle;

        const now = std.time.milliTimestamp();
        const duration: u64 = @intCast(@max(0, now - start_ms));

        const auto_compacted = compact_result.method == .auto;
        const force_compressed = compact_result.method == .force_compress;
        const messages_delta = if (compact_result.messages_before > compact_result.messages_after)
            compact_result.messages_before - compact_result.messages_after
        else
            0;

        return .{
            .ingest = ingest_result,
            .assemble = assemble_result,
            .compact = compact_result,
            .last_turn = .{
                .available = true,
                .prompt_refreshed = assemble_result.prompt_refreshed,
                .workspace_prompt_changed = assemble_result.workspace_prompt_changed,
                .time_bucket_changed = assemble_result.time_bucket_changed,
                .conversation_context_changed = assemble_result.conversation_context_changed,
                .memory_context_injected = ingest_result.memory_enriched,
                .memory_context_bytes = ingest_result.memory_context_bytes,
                .memory_enrich_ms = ingest_result.memory_enrich_ms,
                .auto_compaction_events = if (auto_compacted) 1 else 0,
                .auto_compacted_messages = if (auto_compacted) messages_delta else 0,
                .force_compression_events = if (force_compressed) 1 else 0,
                .force_compressed_messages = if (force_compressed) messages_delta else 0,
                .history_messages_after_trim = compact_result.messages_after,
            },
            .total_duration_ms = duration,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "LifecyclePhase.toSlice returns expected strings" {
    try std.testing.expectEqualStrings("idle", LifecyclePhase.idle.toSlice());
    try std.testing.expectEqualStrings("ingesting", LifecyclePhase.ingesting.toSlice());
    try std.testing.expectEqualStrings("assembling", LifecyclePhase.assembling.toSlice());
    try std.testing.expectEqualStrings("compacting", LifecyclePhase.compacting.toSlice());
    try std.testing.expectEqualStrings("after_turn", LifecyclePhase.after_turn.toSlice());
}

test "ContextEngine starts in idle phase" {
    const engine = ContextEngine{};
    try std.testing.expectEqual(LifecyclePhase.idle, engine.phase);
}

test "IngestResult defaults to all-zero" {
    const r = IngestResult{};
    try std.testing.expect(!r.memory_enriched);
    try std.testing.expectEqual(@as(usize, 0), r.memory_context_bytes);
    try std.testing.expectEqual(@as(u64, 0), r.memory_enrich_ms);
    try std.testing.expectEqual(@as(usize, 0), r.message_count_before);
    try std.testing.expectEqual(@as(usize, 0), r.message_count_after);
}

test "AssembleResult defaults compaction_recommended to false" {
    const r = AssembleResult{};
    try std.testing.expect(!r.compaction_recommended);
    try std.testing.expect(!r.prompt_refreshed);
}

test "CompactMethod enum has 3 variants" {
    const none = CompactResult.CompactMethod.none;
    const auto = CompactResult.CompactMethod.auto;
    const force = CompactResult.CompactMethod.force_compress;
    try std.testing.expectEqual(CompactResult.CompactMethod.none, none);
    try std.testing.expectEqual(CompactResult.CompactMethod.auto, auto);
    try std.testing.expectEqual(CompactResult.CompactMethod.force_compress, force);
}

test "ingest returns idle phase after completion" {
    var engine = ContextEngine{};
    const FakeHistory = struct {
        items: []const u8 = "",
    };
    const fake_agent = struct {
        history: FakeHistory = .{},
        last_turn_context: context_builder.LastTurnContext = .{},
    }{};
    _ = engine.ingest(&fake_agent);
    try std.testing.expectEqual(LifecyclePhase.idle, engine.phase);
}

test "assemble returns idle phase after completion" {
    var engine = ContextEngine{};
    // Minimal agent with no system prompt
    const fake_agent = struct {
        history: struct {
            const FakeMessage = struct { role: enum { system, user, assistant, tool }, content: []const u8 };
            items: []const FakeMessage,
        },
        token_limit: u64,
        max_tokens: u32,
    }{
        .history = .{ .items = &.{} },
        .token_limit = 0,
        .max_tokens = 0,
    };
    _ = engine.assemble(&fake_agent);
    try std.testing.expectEqual(LifecyclePhase.idle, engine.phase);
}

test "compact with no-op agent returns compacted=false and method=none" {
    var engine = ContextEngine{};
    const NoOpAgent = struct {
        history: struct {
            const FakeMsg = struct { role: enum { user }, content: []const u8 };
            items: []const FakeMsg = &.{},
        } = .{},
    };
    var fake_agent = NoOpAgent{};
    const result = engine.compact(&fake_agent);
    try std.testing.expect(!result.compacted);
    try std.testing.expectEqual(CompactResult.CompactMethod.none, result.method);
    try std.testing.expectEqual(@as(usize, 0), result.messages_before);
    try std.testing.expectEqual(@as(usize, 0), result.messages_after);
}

test "afterTurn aggregates results and sets last_turn.available=true" {
    var engine = ContextEngine{};
    const ingest_result = IngestResult{
        .memory_enriched = true,
        .memory_context_bytes = 128,
        .memory_enrich_ms = 5,
        .message_count_before = 2,
        .message_count_after = 3,
    };
    const assemble_result = AssembleResult{
        .prompt_refreshed = true,
        .workspace_prompt_changed = false,
        .time_bucket_changed = true,
        .conversation_context_changed = false,
        .token_estimate = 500,
        .context_pressure_percent = 50,
        .compaction_recommended = false,
    };
    const compact_result = CompactResult{
        .compacted = false,
        .messages_before = 3,
        .messages_after = 3,
        .method = .none,
    };
    const start_ms = std.time.milliTimestamp() - 10;
    const result = engine.afterTurn(ingest_result, assemble_result, compact_result, start_ms);

    try std.testing.expect(result.last_turn.available);
    try std.testing.expect(result.last_turn.prompt_refreshed);
    try std.testing.expect(result.last_turn.time_bucket_changed);
    try std.testing.expect(result.last_turn.memory_context_injected);
    try std.testing.expectEqual(@as(usize, 128), result.last_turn.memory_context_bytes);
    try std.testing.expectEqual(@as(u64, 5), result.last_turn.memory_enrich_ms);
    try std.testing.expectEqual(@as(usize, 0), result.last_turn.auto_compaction_events);
    try std.testing.expect(result.total_duration_ms >= 10);
}

test "afterTurn records auto compaction events" {
    var engine = ContextEngine{};
    const ingest_result = IngestResult{};
    const assemble_result = AssembleResult{};
    const compact_result = CompactResult{
        .compacted = true,
        .messages_before = 20,
        .messages_after = 10,
        .method = .auto,
    };
    const result = engine.afterTurn(ingest_result, assemble_result, compact_result, std.time.milliTimestamp());

    try std.testing.expectEqual(@as(usize, 1), result.last_turn.auto_compaction_events);
    try std.testing.expectEqual(@as(usize, 10), result.last_turn.auto_compacted_messages);
    try std.testing.expectEqual(@as(usize, 0), result.last_turn.force_compression_events);
    try std.testing.expectEqual(@as(usize, 10), result.last_turn.history_messages_after_trim);
}

test "afterTurn records force_compress events" {
    var engine = ContextEngine{};
    const ingest_result = IngestResult{};
    const assemble_result = AssembleResult{};
    const compact_result = CompactResult{
        .compacted = true,
        .messages_before = 15,
        .messages_after = 4,
        .method = .force_compress,
    };
    const result = engine.afterTurn(ingest_result, assemble_result, compact_result, std.time.milliTimestamp());

    try std.testing.expectEqual(@as(usize, 0), result.last_turn.auto_compaction_events);
    try std.testing.expectEqual(@as(usize, 1), result.last_turn.force_compression_events);
    try std.testing.expectEqual(@as(usize, 11), result.last_turn.force_compressed_messages);
    try std.testing.expectEqual(@as(usize, 4), result.last_turn.history_messages_after_trim);
}
