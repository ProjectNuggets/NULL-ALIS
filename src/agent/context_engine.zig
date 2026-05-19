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
const working_memory = @import("working_memory.zig");
const observability = @import("../observability.zig");

// v1.14.14 Phase 1: scope `.agent` preserves the operator-grep contract for
// `turn.stage stage=memory_enrich`, `recall.metrics`, and `recall.zero_candidates`
// log lines that were emitted from root.zig under this same scope (root.zig:9).
const log = std.log.scoped(.agent);

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

/// Stats projection of the ingest phase — slim, owns nothing, safe to
/// embed in `TurnContextResult` and to pass to `afterTurn`.
pub const IngestResult = struct {
    memory_enriched: bool = false,
    memory_context_bytes: usize = 0,
    memory_enrich_ms: u64 = 0,
};

/// Heap-owning ingest output — produced by `ContextEngine.ingest`, consumed
/// by the assemble phase, freed at end of turn via `deinit`.
///
/// Lifetime contract (Phase 1 v1.14.14):
///   - `memory_slot.fenced_content` is heap-allocated (always, even on the
///     "no memory backend" path which dupes the empty string).
///   - `wm_render_set` owns its slot vector when non-null.
///   - `wm_block` owns its rendered byte buffer when non-null.
/// The caller (turnOutcome) must `defer ingest_out.deinit(allocator)` so the
/// memory_slot survives into the assemble phase (which borrows
/// `memory_slot.fenced_content` into `PromptContext.memory_slot`) and is
/// freed exactly once at end of turn.
pub const IngestOutput = struct {
    result: IngestResult,
    memory_slot: memory_loader.MemorySlot,
    wm_render_set: ?working_memory.RenderSet,
    wm_block: ?[]u8,
    wm_owns_identity: bool,

    pub fn deinit(self: *IngestOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.memory_slot.fenced_content);
        if (self.wm_render_set) |s| s.deinit(allocator);
        if (self.wm_block) |b| allocator.free(b);
    }
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

    /// Phase 1: Ingest — load Working Memory + memory_slot + recall-side
    /// telemetry for this turn.
    ///
    /// v1.14.14 Phase 1 (CONTEXT-ENGINE audit-ledger row): owns the
    /// memory-enrichment block that previously lived inline in
    /// `Agent.turnOutcome` (root.zig:2798–2960 at HEAD 555039ac). Migrated
    /// archaeology: V1.13 DUP-1, V1.14.3 G-08, V1.14.3 HIGH-1, V1.14.9 #6.
    ///
    /// Call site contract (preserved byte-identical from the inline block):
    ///   - State-reset (context_was_compacted/force_compressed/last_turn_context),
    ///     `turn_start` observer event, and `turn_start` hooks are NOT ingest
    ///     business — they remain in turnOutcome's turn-frame above this call.
    ///   - On exit, the agent's observer has received exactly one
    ///     `turn_stage{stage="memory_enrich", duration_ms}` event.
    ///   - On exit, three log lines have fired under the `.agent` scope:
    ///     `turn.stage stage=memory_enrich ...`,
    ///     `recall.metrics ...`,
    ///     and (when applicable) `recall.zero_candidates ...`.
    ///
    /// Returns `IngestOutput` — caller MUST `defer ingest_out.deinit(allocator)`.
    pub fn ingest(
        self: *ContextEngine,
        allocator: std.mem.Allocator,
        agent: anytype,
        user_message: []const u8,
    ) error{OutOfMemory}!IngestOutput {
        self.phase = .ingesting;
        defer self.phase = .idle;

        const enrich_start_ms = std.time.milliTimestamp();

        // V1.13 DUP-1 RE-ENABLED (safe path).
        //
        // session.zig::getOrCreateInternal now calls
        // working_memory.pinIdentityFromUserState at session creation,
        // which pins the user's identity facts to slot 0. The
        // <working_memory> block in the volatile prompt renders that
        // slot. So skipping the legacy <active_identity> block here
        // is now safe — identity is rendered once via working_memory,
        // not twice.
        //
        // Gate: only skip when ALL working_memory infrastructure is
        // wired (state_mgr + user_id + session_id + the agent has
        // a memory_runtime — without mem_rt, working_memory.loadForRender
        // can't fetch the slots). Otherwise fall back to legacy
        // <active_identity> for safety.
        //
        // V1.14.3 (G-08 closure) — Load Working Memory FIRST so
        // skip_legacy_identity is gated on ACTUAL wm content, not
        // predicted infrastructure presence.
        //
        // Pre-V1.14.3: the gate was 4 conditions (state_mgr + user_id
        // + session_id + mem_rt all non-null). It said "if WM
        // infrastructure is wired, skip legacy <active_identity>" —
        // assuming pinIdentitySlot ran successfully and slot 0 holds
        // identity content. But the gate didn't VERIFY the assumption.
        // If pinIdentityFromUserState returned 0 facts (truly empty
        // user, or postgres flake during session creation, or future
        // refactor breaking the chain silently), the agent ended up
        // with neither legacy <active_identity> NOR a usable
        // <working_memory> identity block.
        //
        // V1.14.3: load wm here, render the block, THEN compute
        // skip_legacy_identity from actual slot content. Identity is
        // rendered exactly once: via WM if available, via legacy
        // <active_identity> otherwise. No silent identity loss.
        //
        // Cost: WM load was already happening per turn (just later in
        // the function). Moving it earlier is free (~50ms either way).
        const wm_render_set: ?working_memory.RenderSet = blk: {
            if (agent.extraction_state_mgr) |smgr| {
                if (agent.extraction_user_id) |uid| {
                    const sid = agent.memory_session_id orelse break :blk null;
                    break :blk working_memory.loadForRender(allocator, smgr, uid, sid);
                }
            }
            break :blk null;
        };
        errdefer if (wm_render_set) |s| s.deinit(allocator);

        const wm_block: ?[]u8 = blk: {
            const set = wm_render_set orelse break :blk null;
            if (set.slots.len == 0) break :blk null;
            break :blk working_memory.renderBlock(allocator, set.slots) catch |err| {
                log.warn("working_memory.render_failed err={s}", .{@errorName(err)});
                break :blk null;
            };
        };
        errdefer if (wm_block) |b| allocator.free(b);

        // The actual gate: WM owns identity iff a slot with
        // slot_type == "identity" actually exists in the rendered set.
        //
        // V1.14.3 review HIGH-1 fix — the prior version checked only
        // `wm_block.len > 0`, but extraction can promote `open_loop` /
        // `active_goal` / `recent_entity` slots without ever pinning
        // an identity slot (extraction_persist.zig:863, 899-911 fire
        // promoteSlot for those types unconditionally). A user with
        // empty pinIdentityFromUserState output AND extracted goals
        // would have wm_block non-empty (containing the goals) but
        // zero identity content, then skip_legacy_identity=true
        // would suppress the legacy <active_identity> block —
        // resulting in an agent prompt with NO identity at all.
        //
        // Iterating slot_type checks the actual presence of identity
        // content. Ordering: working_memory.SlotType.identity matches
        // the constant the writer side uses (working_memory.zig:59).
        const wm_owns_identity: bool = blk: {
            const set = wm_render_set orelse break :blk false;
            for (set.slots) |s| {
                if (std.mem.eql(u8, s.slot_type, working_memory.SlotType.identity)) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        const memory_slot: memory_loader.MemorySlot = if (agent.mem) |mem|
            memory_loader.loadTurnMemorySlotOpts(
                allocator,
                mem,
                agent.mem_rt,
                user_message,
                agent.memory_session_id,
                agent.extraction_state_mgr,
                agent.extraction_user_id,
                .{ .skip_legacy_identity = wm_owns_identity },
            ) catch |err| blk: {
                log.warn("memory.enrichment_failed error={s} — proceeding without memory slot", .{@errorName(err)});
                break :blk memory_loader.MemorySlot{
                    .fenced_content = try allocator.dupe(u8, ""),
                    .stats = .{},
                };
            }
        else
            memory_loader.MemorySlot{
                .fenced_content = try allocator.dupe(u8, ""),
                .stats = .{},
            };
        errdefer allocator.free(memory_slot.fenced_content);

        const enrich_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - enrich_start_ms));
        log.info("turn.stage stage=memory_enrich duration_ms={d}", .{enrich_duration_ms});

        // V1.14.9 #6 — Retrieval-side telemetry symmetric to R1
        // boundary.metrics. R1 measures EXTRACTION (write side); this
        // measures RECALL (read side). One structured log line per turn
        // captures: did we serve any memory at all (available), how many
        // candidates considered (candidate_count), how that decomposed
        // by retrieval kind (durable_fact / timeline / search-match /
        // global), and how many bytes/entries each bucket contributed.
        // Operators can grep `recall.metrics` to spot per-user retrieval
        // collapse (available=false on a populated user = R3 graph
        // traversal opportunity OR R4 BM25 fusion gap).
        const rstats = memory_slot.stats;
        log.info(
            "recall.metrics available={} candidates={d} global_candidates={d} durable_facts={d} timeline_summaries={d} search_matches={d} global_fallbacks={d} summary_latest_used={} context_anchor_used={} continuity_entries={d} continuity_bytes={d} semantic_entries={d} semantic_bytes={d} fallback_entries={d} fallback_bytes={d} enrich_ms={d}",
            .{
                rstats.available,
                rstats.candidate_count,
                rstats.global_candidate_count,
                rstats.durable_fact_count,
                rstats.timeline_summary_count,
                rstats.search_match_count,
                rstats.global_fallback_count,
                rstats.summary_latest_used,
                rstats.context_anchor_used,
                rstats.continuity_bucket_entries,
                rstats.continuity_bucket_bytes,
                rstats.semantic_bucket_entries,
                rstats.semantic_bucket_bytes,
                rstats.fallback_bucket_entries,
                rstats.fallback_bucket_bytes,
                enrich_duration_ms,
            },
        );
        // Retrieval-side alert (mirror of R1 boundary.zero_density):
        // user has memory available but retrieval returned 0 candidates
        // on a non-trivial user message. Surfaces stale embeddings,
        // missing entity coref, or graph layer not yet populated.
        if (agent.mem != null and user_message.len > 32 and rstats.available and rstats.candidate_count == 0) {
            log.warn(
                "recall.zero_candidates user_msg_len={d} — retrieval pipeline returned no matches on a substantive query; check embeddings / coref / graph",
                .{user_message.len},
            );
        }

        const memory_stage_event = observability.ObserverEvent{ .turn_stage = .{
            .stage = "memory_enrich",
            .duration_ms = enrich_duration_ms,
            .run_id = agent.current_run_id,
        } };
        agent.observer.recordEvent(&memory_stage_event);

        return IngestOutput{
            .result = .{
                .memory_enriched = rstats.available,
                .memory_context_bytes = memory_slot.fenced_content.len,
                .memory_enrich_ms = enrich_duration_ms,
            },
            .memory_slot = memory_slot,
            .wm_render_set = wm_render_set,
            .wm_block = wm_block,
            .wm_owns_identity = wm_owns_identity,
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
    /// Note: anti-thrash guard is implemented inside Agent.autoCompactHistory
    /// (the actual call site used by the turn loop). The gate here is just a
    /// thin pass-through for callers that prefer the ContextEngine lifecycle.
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

// v1.14.14 Phase 1: helper shared by ingest tests below. Builds a fake-agent
// struct whose field types match the concrete types ContextEngine.ingest
// reaches through the agent: anytype parameter. Values are all-null so the
// memory-backend and WM-loader branches early-return; the body never actually
// invokes loadForRender/loadTurnMemorySlotOpts at runtime, but their call
// sites must still type-check at compile time.
fn FakeIngestAgent(comptime ObserverT: type) type {
    const zaki_state = @import("../zaki_state.zig");
    const memory_root = @import("../memory/root.zig");
    return struct {
        mem: ?memory_root.Memory = null,
        mem_rt: ?*memory_root.MemoryRuntime = null,
        memory_session_id: ?[]const u8 = null,
        extraction_state_mgr: ?*zaki_state.Manager = null,
        extraction_user_id: ?i64 = null,
        observer: ObserverT,
        current_run_id: ?[]const u8 = null,
    };
}

test "ingest with null backends produces empty slot, no leaks, idle phase" {
    var engine = ContextEngine{};
    var noop = observability.NoopObserver{};
    var fake_agent = FakeIngestAgent(observability.Observer){
        .observer = noop.observer(),
    };
    var output = try engine.ingest(std.testing.allocator, &fake_agent, "hello");
    defer output.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), output.memory_slot.fenced_content.len);
    try std.testing.expect(output.wm_render_set == null);
    try std.testing.expect(output.wm_block == null);
    try std.testing.expect(!output.wm_owns_identity);
    try std.testing.expect(!output.result.memory_enriched);
    try std.testing.expectEqual(@as(usize, 0), output.result.memory_context_bytes);
    try std.testing.expectEqual(LifecyclePhase.idle, engine.phase);
}

test "ingest emits exactly one memory_enrich observer event" {
    const RecordingObserver = struct {
        events: std.ArrayListUnmanaged(EventCopy) = .empty,
        allocator: std.mem.Allocator,

        const EventCopy = struct { stage: []u8, duration_ms: ?u64 };
        const Self = @This();

        fn record(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            switch (event.*) {
                .turn_stage => |e| {
                    const stage_copy = self.allocator.dupe(u8, e.stage) catch return;
                    self.events.append(self.allocator, .{
                        .stage = stage_copy,
                        .duration_ms = e.duration_ms,
                    }) catch {
                        self.allocator.free(stage_copy);
                        return;
                    };
                },
                else => {},
            }
        }
        fn noopMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
        fn noopFlush(_: *anyopaque) void {}
        fn nameStr(_: *anyopaque) []const u8 {
            return "recording";
        }

        const vtable_const = observability.Observer.VTable{
            .record_event = record,
            .record_metric = noopMetric,
            .flush = noopFlush,
            .name = nameStr,
        };

        fn deinit(self: *Self) void {
            for (self.events.items) |e| self.allocator.free(e.stage);
            self.events.deinit(self.allocator);
        }

        fn observer(self: *Self) observability.Observer {
            return .{ .ptr = self, .vtable = &vtable_const };
        }
    };

    var engine = ContextEngine{};
    var recorder = RecordingObserver{ .allocator = std.testing.allocator };
    defer recorder.deinit();

    var fake_agent = FakeIngestAgent(observability.Observer){
        .observer = recorder.observer(),
    };

    var output = try engine.ingest(std.testing.allocator, &fake_agent, "hello world this is a test message");
    defer output.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), recorder.events.items.len);
    try std.testing.expectEqualStrings("memory_enrich", recorder.events.items[0].stage);
    try std.testing.expect(recorder.events.items[0].duration_ms != null);
    // The reported duration must equal what ingest stored in result.memory_enrich_ms.
    try std.testing.expectEqual(output.result.memory_enrich_ms, recorder.events.items[0].duration_ms.?);
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
