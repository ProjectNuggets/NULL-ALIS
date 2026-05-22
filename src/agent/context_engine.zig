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
const working_memory = @import("working_memory.zig");
const observability = @import("../observability.zig");
const Config = @import("../config.zig").Config;
const capabilities_mod = @import("../capabilities.zig");
const prompt = @import("prompt.zig");
const dispatcher = @import("dispatcher.zig");
const procedural_memory = @import("procedural_memory.zig");
const narration = @import("narration.zig");
const bench_self = @import("bench_self.zig");
const task_planner = @import("task_planner.zig");
// v1.14.14 Phase 3 originally added `const compaction = @import("compaction.zig");`
// here, but the new `compact`/`forceCompact` methods reach compaction via the
// agent's own `autoCompactHistory`/`forceCompressHistory` rather than calling
// `compaction.*` directly — so the import had no code references (only a
// comment mention). Removed in the self-review pass; the comment-only
// reference is documentation and doesn't need the module bound.

// v1.14.14 Phase 1: scope `.agent` preserves the operator-grep contract for
// `turn.stage stage=memory_enrich`, `recall.metrics`, `recall.zero_candidates`,
// `prefix.stable`, `prefix.tail`, `working_memory.render_failed`, and
// `procedural_memory.render_failed` log lines that were emitted from root.zig
// under this same scope (root.zig:9).
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
///
/// v1.14.14 Phase 2 added `stable_prefix_hash` + `stable_prefix_bytes` so
/// callers and tests can assert byte-stability of the assembled system-prompt
/// prefix without parsing log lines. The hash is unconditionally computed (FNV-1a
/// 64-bit is cheap); the log line is still emitted only when
/// `NULLALIS_LOG_PREFIX_HASH=1` (honest config surface, §14.6).
///
/// v1.14.14.1 Finding 2 (PREFIX-TAIL-SURFACE) added `tail_hash` + `tail_bytes`.
/// The kept-history TAIL (last ≤4 non-system messages) is also part of the
/// provider-cacheable prompt — F-PA2's drop-from-middle pattern preserves
/// these bytes across turns when no Pass C summarization fires. Both halves
/// must stay byte-stable for KV-cache hits on long sessions. The Phase 5
/// drift assertion in `.spike/run.sh` now covers BOTH hashes; either drifting
/// mid-session is a cache-collapse regression.
pub const AssembleResult = struct {
    prompt_refreshed: bool = false,
    workspace_prompt_changed: bool = false,
    time_bucket_changed: bool = false,
    conversation_context_changed: bool = false,
    stable_prefix_state: context_cache.StablePrefixState = .{},
    token_estimate: u64 = 0,
    context_pressure_percent: u8 = 0,
    compaction_recommended: bool = false,
    /// FNV-1a 64-bit hash of `[stable_prompt][tool_instructions]` — the
    /// provider-cacheable prefix bytes of the just-assembled system prompt.
    /// 0 if assemble did not run (e.g., no system prompt rebuild required).
    stable_prefix_hash: u64 = 0,
    /// Byte count covered by `stable_prefix_hash`. 0 if hash is 0.
    stable_prefix_bytes: usize = 0,
    /// FNV-1a 64-bit hash of the kept-history tail (last ≤4 non-system
    /// messages) at assemble time. v1.14.14.1 Finding 2.
    tail_hash: u64 = 0,
    /// Byte count covered by `tail_hash`. 0 when no non-system history.
    tail_bytes: usize = 0,
};

/// Output of the compact phase.
///
/// v1.14.14.1 Finding 4 (COMPACT-SENTINEL-RESOLVE): the original design
/// carried `messages_before` + `messages_after` here so afterTurn could
/// derive a per-call messages_delta into the returned TurnContextResult.
/// Two facts made this redundant:
///   1. The 11 compact callsites in turnOutcome are scattered across the
///      tool loop; the Phase 4 defer-synthesis pattern doesn't have access
///      to per-site counts (it had to hardcode `messages_before = 0` as a
///      sentinel lie — see commit 843ca622 self-review).
///   2. The source of truth for per-site counts already exists:
///      `recordAutoCompaction` / `recordForceCompression` (called from
///      ContextEngine.compact / forceCompact themselves) write
///      `auto_compacted_messages` / `force_compressed_messages` /
///      `history_messages_after_trim` DIRECTLY onto `agent.last_turn_context`.
///      That populates `/context` reports + observer telemetry via the live
///      agent state, never via the afterTurn return value (which production
///      discards as `_ = ...afterTurn(...)`).
/// Removed the two fields. The `.compacted` boolean + `.method` enum are
/// the only signals callers actually inspect.
pub const CompactResult = struct {
    compacted: bool = false,
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

/// v1.14.14 Phase 4: per-phase wall-clock durations captured by turnOutcome,
/// piped through `afterTurn` into the stability snapshot.
///
/// v1.14.14.1 Finding 3 (COMPACT-MS-AGGREGATE) — honesty fix:
/// The `compact_ms` field here still receives `turn_compaction_ms` from
/// turnOutcome (caller in root.zig unchanged — Agent E owns root.zig for
/// v1.14.18-A GOAL-LOOP work). What changes is the OPERATOR-FACING surface:
/// the StabilityRecord field + JSONL key are renamed to
/// `compact_ms_main_site_only` so operators reading the JSONL see the
/// partial-coverage honestly. Production has 11 compact callsites inside
/// `Agent.turnOutcome` (cache-hit branches, response-cache hit branch,
/// main flow, tool-loop sites, exhausted-iteration recovery, force-compress
/// recovery × 3, final compact); only the main-flow site at root.zig:3064
/// measures its duration into `turn_compaction_ms`. The other 10 sites
/// don't track timing.
///
/// Full aggregation across all 11 sites (option (a) per spawn brief) is
/// blocked by the v1.14.14.1 hot-file lock: `turn_compaction_ms` is a
/// stack-local in turnOutcome (root.zig:2739), and aggregation requires
/// either promoting it to an Agent field or modifying each callsite —
/// both touch src/agent/root.zig, which Agent E owns. Aggregation lands
/// in v1.14.14.2 (or later slice) once the lock releases. This commit
/// applies option (b): rename the operator surface to surface the truth.
pub const PhaseDurations = struct {
    ingest_ms: u64 = 0,
    assemble_ms: u64 = 0,
    /// Main-flow site only. Caller in turnOutcome passes
    /// `turn_compaction_ms` (unchanged from v1.14.14 — single-site
    /// instrumentation at root.zig:3064). The other 10 compact callsites
    /// (tool-loop, cache-hit, force-compress) are not yet aggregated;
    /// the StabilityRecord renames this field to `compact_ms_main_site_only`
    /// when it crosses the operator boundary so the JSONL surface is
    /// honest about the partial coverage.
    compact_ms: u64 = 0,
};

/// v1.14.14 Phase 4: one-line JSON record appended to
/// `NULLALIS_STABILITY_JSON_PATH` per turn (when the env var is set).
/// Operator dashboards can `jq -c .stable_prefix_hash` on the file to verify
/// byte-stability across consecutive turns of the same session.
///
/// v1.14.14.1 Finding 2: `tail_hash` + `tail_bytes` added so the Phase 5
/// drift assertion covers BOTH halves of the provider-cacheable prompt.
/// `prefix.stable` drift = provider re-tokenizes the system prompt;
/// `prefix.tail` drift = provider re-tokenizes the kept history. Either
/// is a cache-collapse regression mid-session.
pub const StabilityRecord = struct {
    turn_start_ms: i64,
    ingest_ms: u64,
    assemble_ms: u64,
    /// v1.14.14.1 Finding 3: only the main-flow auto-compaction site's
    /// duration. 10 other compact callsites aren't aggregated yet — see
    /// PhaseDurations.compact_ms_main_site_only doc.
    compact_ms_main_site_only: u64,
    after_turn_ms: u64,
    total_turn_ms: u64,
    stable_prefix_hash: u64,
    stable_prefix_bytes: usize,
    tail_hash: u64,
    tail_bytes: usize,
    session: []const u8,
};

/// v1.14.14 Phase 4 helper. Appends one JSONL record to the path in
/// `NULLALIS_STABILITY_JSON_PATH` if the env var is set and non-empty;
/// otherwise no-ops. All filesystem errors are silently swallowed —
/// stability emission is best-effort diagnostic, not a turn-blocking
/// dependency. The operator is responsible for ensuring the parent
/// directory exists (the helper does not call makePath).
///
/// Self-review fix (post-Phase-5): the pre-fix path opened the file without
/// a lock, then did `seekFromEnd(0)` + `writeAll(line)` as TWO separate
/// syscalls. Two concurrent writers (different sessions in the same gateway
/// process, or two processes both pointed at the same file) would each
/// seekFromEnd to position N before either's write completed → both write
/// at offset N → second overwrites first → silent JSONL corruption.
/// Bench-only sequential use was safe; multi-tenant / future-parallel use
/// would race. Acquiring `.lock = .exclusive` at open serializes writers
/// across processes on macOS/Linux (the lock is taken atomically with the
/// file descriptor). The lock releases on `close()`. Serialization is fine
/// here because stability emission is off-the-hot-path and env-gated.
pub fn writeStabilityJsonl(allocator: std.mem.Allocator, record: StabilityRecord) void {
    const env_path = std.process.getEnvVarOwned(allocator, "NULLALIS_STABILITY_JSON_PATH") catch return;
    defer allocator.free(env_path);
    if (env_path.len == 0) return;

    const line = formatStabilityJsonlLine(allocator, record) catch return;
    defer allocator.free(line);

    const file = std.fs.cwd().createFile(env_path, .{
        .truncate = false,
        .read = false,
        .lock = .exclusive,
    }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    _ = file.writeAll(line) catch return;
}

fn formatStabilityJsonlLine(allocator: std.mem.Allocator, record: StabilityRecord) ![]u8 {
    const stable_prefix_hash = try std.fmt.allocPrint(allocator, "{x}", .{record.stable_prefix_hash});
    defer allocator.free(stable_prefix_hash);
    const tail_hash = try std.fmt.allocPrint(allocator, "{x}", .{record.tail_hash});
    defer allocator.free(tail_hash);

    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .turn_start_ms = record.turn_start_ms,
        .ingest_ms = record.ingest_ms,
        .assemble_ms = record.assemble_ms,
        .compact_ms_main_site_only = record.compact_ms_main_site_only,
        .after_turn_ms = record.after_turn_ms,
        .total_turn_ms = record.total_turn_ms,
        .stable_prefix_hash = stable_prefix_hash,
        .stable_prefix_bytes = record.stable_prefix_bytes,
        .tail_hash = tail_hash,
        .tail_bytes = record.tail_bytes,
        .session = record.session,
    }, .{});
    defer allocator.free(json);

    return try std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

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

        if (rstats.available) {
            const summary = bucketSummary(allocator, rstats) catch null;
            defer if (summary) |s| allocator.free(s);
            const retrieval_event = observability.ObserverEvent{ .memory_retrieval = .{
                .run_id = agent.current_run_id,
                .status = if (summary) |s| s else "unavailable",
                .success = rstats.injected,
                .usage_tokens = @intCast(rstats.context_bytes),
                .iteration = @intCast(rstats.candidate_count),
                .duration_ms = enrich_duration_ms,
            } };
            agent.observer.recordEvent(&retrieval_event);
        }

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

    /// Phase 2: Assemble — build prompt refresh plan, write last_turn_context,
    /// assemble the stable + tool_instructions + volatile system prompt,
    /// transfer ownership of the assembled buffer into history[0], and update
    /// the agent's prompt-state fields.
    ///
    /// v1.14.14 Phase 2 (CONTEXT-ENGINE audit-ledger row): owns the
    /// prompt-rebuild block that previously lived inline in
    /// `Agent.turnOutcome` (root.zig 2962-3166 at v1.14.13 HEAD, then
    /// 2819-3023 after Phase 1 landed). Migrated archaeology: S5.7 memoized
    /// Config cache, V1.14.3 G-08 + G-07 closures, iter22 errdefer reasoning,
    /// V1.14.6 prefix.tail diagnostic.
    ///
    /// Side-effect contract (preserved byte-identical from the inline block):
    ///   - On exit, `agent.last_turn_context` has been rewritten from
    ///     `buildLastTurnContext(refresh_plan, ingest_out.memory_slot.stats,
    ///     ingest_out.result.memory_enrich_ms)`.
    ///   - On exit, `agent.history[0]` is the canonical system prompt
    ///     `[stable][tool_instructions][volatile]` — replaced in place if a
    ///     prior system slot existed, otherwise inserted at index 0 (or
    ///     appended on empty history).
    ///   - On exit, the five prompt-state fields are written:
    ///     `agent.has_system_prompt = true`, plus
    ///     `system_prompt_has_conversation_context`,
    ///     `system_prompt_conversation_context_fingerprint`,
    ///     `workspace_prompt_fingerprint`,
    ///     `system_prompt_time_bucket_min`.
    ///   - `AssembleResult.stable_prefix_hash` is the FNV-1a 64-bit hash of
    ///     `[stable_prompt][tool_instructions]` (the cacheable prefix).
    ///     Unconditional. Tests assert byte-stability across consecutive
    ///     assemble() calls. The same hash is also logged when
    ///     `NULLALIS_LOG_PREFIX_HASH=1` (operator diagnostic only).
    pub fn assemble(
        self: *ContextEngine,
        allocator: std.mem.Allocator,
        agent: anytype,
        ingest_out: *const IngestOutput,
    ) !AssembleResult {
        self.phase = .assembling;
        defer self.phase = .idle;

        const snapshot = context_builder.buildSnapshot(agent);

        // Build prompt refresh plan for diagnostics + last_turn_context.
        // In context v2 we always rebuild the system prompt (volatile block
        // changes per turn — datetime, conversation context, memory). The
        // refresh plan no longer gates rebuild; it only feeds stats.
        const refresh_plan = context_builder.buildPromptRefreshPlan(agent);
        agent.last_turn_context = context_builder.buildLastTurnContext(
            refresh_plan,
            ingest_out.memory_slot.stats,
            ingest_out.result.memory_enrich_ms,
        );

        const stable_prefix_state = context_cache.buildStablePrefixState(refresh_plan, snapshot.has_system_prompt);

        // S5.7 — memoized Config fetch. Replaces a per-turn
        // `Config.load` + JSON parse + deinit triad. The cached_config
        // lives on the Agent until deinit; see `cachedConfigForCaps`.
        const cfg_for_caps_ptr: ?*const Config = agent.cachedConfigForCaps();

        const capabilities_section = capabilities_mod.buildPromptSection(
            allocator,
            cfg_for_caps_ptr,
            agent.tools,
        ) catch null;
        defer if (capabilities_section) |section| allocator.free(section);

        // Resolve persona from SOUL.md front-matter (REQ-022). Falls back to defaults when absent.
        const persona_profile_opt = prompt.resolvePersonaFromFile(allocator, agent.workspace_dir);
        defer if (persona_profile_opt) |p| {
            if (p.voice) |v| allocator.free(v);
        };
        const persona_section: ?prompt.PersonaSection = if (persona_profile_opt) |p| .{
            .warmth = p.warmth,
            .proactivity = p.proactivity,
            .voice_style = p.voice,
            .twin_mode = p.twin_mode,
        } else null;

        // V1.14.3 (G-08 closure) — wm_block was hoisted above the
        // memory_slot load (now in ingest) so skip_legacy_identity gates
        // on actual content. We reuse that hoisted value here instead of
        // re-loading. Renamed to local alias for the prompt_ctx
        // builder below.
        const wm_block: ?[]u8 = ingest_out.wm_block;

        // V1.14.3 (G-07 closure) — Procedural memory recall block.
        //
        // V1.13 shipped capture (skill_executions table + insertSkillExecution
        // in commands.zig at session_end). The reader (listRecentSkillExecutions)
        // and renderer (procedural_memory.renderBlock) also shipped in V1.13
        // but were never wired into the volatile prompt — agent saw no prior
        // traces. G-07 was the half-loop bug. This block closes it.
        //
        // Skill name: GENERIC_SKILL_NAME (V1.13 capture is coarse-grained,
        // one row per multi-tool turn). Future refinement: detect specific
        // skill invocations and recall per-skill. For now, the agent sees
        // the last 3 substantive turns regardless of skill name.
        //
        // Failure-soft on every layer: missing state_mgr or user_id → null;
        // postgres error → empty traces; OOM on render → null. Same shape
        // as wm_block above so the prompt builder treats both uniformly.
        const skill_traces_block: ?[]u8 = blk: {
            const smgr = agent.extraction_state_mgr orelse break :blk null;
            const uid = agent.extraction_user_id orelse break :blk null;
            const set = procedural_memory.loadForRender(
                allocator,
                smgr,
                uid,
                procedural_memory.GENERIC_SKILL_NAME,
            );
            defer set.deinit(allocator);
            if (set.traces.len == 0) break :blk null;
            break :blk procedural_memory.renderBlock(
                allocator,
                procedural_memory.GENERIC_SKILL_NAME,
                set.traces,
            ) catch |err| {
                log.warn("procedural_memory.render_failed err={s}", .{@errorName(err)});
                break :blk null;
            };
        };

        // v1.14.18-B G7 — Bench self-knowledge block from recent bench results.
        const known_weakness_block: ?[]u8 = blk: {
            break :blk bench_self.readKnownWeakness(allocator, ".spike/results.tsv") catch |err| {
                log.debug("bench_self.readKnownWeakness failed: {s}", .{@errorName(err)});
                break :blk null;
            };
        };
        defer if (known_weakness_block) |b| allocator.free(b);

        defer if (skill_traces_block) |b| allocator.free(b);

        // v1.14.18-B G3 (NARRATION-AS-CONTEXT) — recent thoughts block.
        //
        // Pulls the last 3 narration frames the agent emitted (across
        // iterations of this turn AND the prior turn's tail, since the
        // ring buffer is Agent-owned and persists between turns until
        // RING_BUFFER_CAPACITY=16 entries evict it). Closes the loop:
        // v1.14.13 NarrationObserver fired events to channel UIs but the
        // agent itself never saw its own narration in the next iteration's
        // prompt. Now `recallRecent` surfaces it as `<recent_thoughts>`.
        //
        // Failure-soft: missing ring buffer (Agent built without
        // `narration_ring_buffer` initialized) → null block, recall is a
        // no-op. recallRecent error → drop the block, log a warn. Render
        // error → drop the block, log a warn.
        //
        // Iteration count: agent.iteration_counter (Agent field, bumped
        // by the agent loop) reflects the iteration this assemble call
        // is preparing for. The frames carry their own `iteration` field
        // stamped at push time so the block renders the historical iter
        // numbers, not the current one.
        const recent_thoughts_block: ?[]u8 = blk: {
            const rb_ptr: ?*narration.NarrationRingBuffer = if (@hasField(@TypeOf(agent.*), "narration_ring_buffer"))
                @as(?*narration.NarrationRingBuffer, &agent.narration_ring_buffer)
            else
                null;
            const frames = narration.recallRecent(rb_ptr, allocator, narration.RECALL_DEPTH) catch |err| {
                log.warn("narration.recall_failed err={s}", .{@errorName(err)});
                break :blk null;
            };
            // v1.14.18-B G3 follow-up — `recallRecent` deep-copies each
            // frame's `.message` / `.tool_name` into `allocator` (closes
            // a HIGH concurrent use-after-free where the prior borrow
            // contract aliased ring-buffer memory and a worker-thread
            // `push()` could free the slot between `recallRecent` and
            // `renderRecentThoughtsBlock`). `self.allocator` here is the
            // Agent's GPA-backed allocator, NOT an arena, so we must
            // explicitly free each frame's owned strings AND the outer
            // slice on every exit path of this block.
            defer {
                for (frames) |f| {
                    allocator.free(f.message);
                    if (f.tool_name) |t| allocator.free(t);
                }
                allocator.free(frames);
            }
            if (frames.len == 0) break :blk null;
            const current_iter: u32 = if (@hasField(@TypeOf(agent.*), "iteration_counter"))
                agent.iteration_counter
            else
                0;
            break :blk narration.renderRecentThoughtsBlock(
                allocator,
                frames,
                current_iter,
            ) catch |err| {
                log.warn("narration.render_failed err={s}", .{@errorName(err)});
                break :blk null;
            };
        };
        defer if (recent_thoughts_block) |b| allocator.free(b);

        // v1.14.18-A G4 (TASK-PLANNER READ-BACK) — render the agent's retained
        // task plan as a `<task_plan>` block. The plan is an Agent field
        // (persist-until-replaced) so this surfaces the plan + live step
        // progress from the most recent turn that emitted one. Failure-soft:
        // a render error drops the block, never fails assembly.
        const task_plan_block: ?[]u8 = blk: {
            const plan_ptr: ?*const task_planner.TaskPlan = if (@hasField(@TypeOf(agent.*), "active_task_plan"))
                (if (agent.active_task_plan) |*p| p else null)
            else
                null;
            const p = plan_ptr orelse break :blk null;
            break :blk task_planner.renderPlanBlock(allocator, p) catch |err| {
                log.warn("task_planner.render_failed err={s}", .{@errorName(err)});
                break :blk null;
            };
        };
        defer if (task_plan_block) |b| allocator.free(b);

        // Context v2: build stable + volatile separately so tool instructions
        // can sit in the STABLE half (byte-identical across turns) rather than
        // after the volatile block. This preserves byte-prefix cache stability
        // on Together/vLLM and enables future Anthropic two-block emission.
        //
        // v1.14.18-B coordination invariant — Recall-stack ordering:
        //   1. recent_thoughts (G3, Agent G)    ← FIRST in PromptContext
        //   2. known_weakness  (G7, Agent E)    ← SECOND (populated separately)
        //   3. task_plan       (G4, v1.14.18-A) ← THIRD (agent's plan + progress)
        //   4. skill_traces    (G-07, existing) ← FOURTH
        //
        // This four-block order is also baked into
        // `prompt.buildVolatileSystemPrompt`. Byte-stability across turns
        // assumes the upstream sources update at session boundaries.
        // Re-ordering these fields here without also updating the prompt
        // builder is a SILENT cache-stability regression. Do not edit
        // without updating both.
        const prompt_ctx = prompt.PromptContext{
            .workspace_dir = agent.workspace_dir,
            .model_name = agent.model_name,
            .tools = agent.tools,
            .capabilities_section = capabilities_section,
            .conversation_context = agent.conversation_context,
            .sections = .{ .persona = persona_section },
            .memory_slot = if (ingest_out.memory_slot.fenced_content.len > 0) ingest_out.memory_slot.fenced_content else null,
            .working_memory_block = wm_block,
            .recent_thoughts_block = if (recent_thoughts_block) |b| (if (b.len > 0) b else null) else null,
            .known_weakness_block = if (known_weakness_block) |b| (if (b.len > 0) b else null) else null,
            .task_plan_block = if (task_plan_block) |b| (if (b.len > 0) b else null) else null,
            .skill_traces_block = if (skill_traces_block) |b| (if (b.len > 0) b else null) else null,
        };

        const stable_prompt = try prompt.buildStableSystemPrompt(allocator, prompt_ctx);
        defer allocator.free(stable_prompt);

        const tool_instructions = try dispatcher.buildToolInstructions(allocator, agent.tools);
        defer allocator.free(tool_instructions);

        const volatile_prompt = try prompt.buildVolatileSystemPrompt(allocator, prompt_ctx);
        defer allocator.free(volatile_prompt);

        // Layout: [stable][tool_instructions][volatile]
        // stable + tool_instructions = byte-stable prefix (cached by provider KV).
        // volatile = dynamic tail (datetime / conversation context / memory).
        const stable_prefix_len = stable_prompt.len + tool_instructions.len;
        const full_system = try allocator.alloc(u8, stable_prefix_len + volatile_prompt.len);
        // iter22 (Nova's Medium finding): errdefer guards the window between
        // alloc and ownership transfer into history. If history.insert or
        // history.append fails (OOM on the ArrayList resize), without this
        // errdefer the full_system buffer would orphan. Cleared manually
        // on each success branch so ownership cleanly transfers.
        var full_system_owned = true;
        errdefer if (full_system_owned) allocator.free(full_system);
        @memcpy(full_system[0..stable_prompt.len], stable_prompt);
        @memcpy(full_system[stable_prompt.len..stable_prefix_len], tool_instructions);
        @memcpy(full_system[stable_prefix_len..], volatile_prompt);

        // Byte-stability diagnostic: compute the FNV-1a hash of the stable
        // prefix AND the kept history tail unconditionally so tests +
        // AssembleResult + the JSONL diagnostic can assert byte-identical
        // prefix + tail across turns of the same session. The log emission
        // is still gated by NULLALIS_LOG_PREFIX_HASH=1 to keep noise out
        // of prod logs.
        //
        // V1.14.6 follow-up: also hash the kept history TAIL (last 4
        // messages of self.history). F-PA2's drop-from-middle pattern
        // promises that when no Pass C summarization fires, the kept
        // tail bytes match the prior turn — that's what makes vLLM /
        // Together / Moonshot prefix caching usable on long sessions.
        // Two consecutive same-session turns with identical
        // `prefix.tail` hashes confirm the contract holds. Diverging
        // hashes when nothing semantic changed is a regression signal.
        //
        // v1.14.14.1 Finding 2 (PREFIX-TAIL-SURFACE): the tail hash now
        // computes unconditionally (FNV-1a is ~50ns/KB; ≤4 messages × ≤8KB
        // each = ~1.6μs total — undetectable) and flows through
        // AssembleResult.tail_hash + tail_bytes. The Phase 5 .spike/run.sh
        // drift assertion now covers BOTH halves.
        const stable_prefix_hash = std.hash.Fnv1a_64.hash(full_system[0..stable_prefix_len]);

        const TAIL_HASH_MSGS: usize = 4;
        var tail_hasher = std.hash.Fnv1a_64.init();
        var tail_bytes: usize = 0;
        var tail_msgs: usize = 0;
        if (agent.history.items.len > 0) {
            const start_idx = agent.history.items.len -|
                @min(TAIL_HASH_MSGS, agent.history.items.len);
            for (agent.history.items[start_idx..]) |*m| {
                if (m.role == .system) continue;
                tail_hasher.update(m.content);
                tail_bytes += m.content.len;
                tail_msgs += 1;
            }
        }
        const tail_hash = tail_hasher.final();

        if (std.process.getEnvVarOwned(allocator, "NULLALIS_LOG_PREFIX_HASH")) |env_value| {
            defer allocator.free(env_value);
            if (env_value.len > 0 and env_value[0] != '0') {
                log.info("prefix.stable hash={x} bytes={d} session={s}", .{
                    stable_prefix_hash,
                    stable_prefix_len,
                    agent.memory_session_id orelse "none",
                });
                log.info("prefix.tail hash={x} bytes={d} msgs={d} session={s}", .{
                    tail_hash,
                    tail_bytes,
                    tail_msgs,
                    agent.memory_session_id orelse "none",
                });
            }
        } else |_| {}

        // Keep exactly one canonical system prompt at history[0].
        // This allows /model to invalidate and refresh the prompt in place.
        // Each branch transfers ownership of full_system into history on
        // success, flipping full_system_owned = false so the errdefer no
        // longer tries to free it. try insert/append path: if the call
        // fails the errdefer will free full_system (insert/append do not
        // take ownership on failure).
        if (agent.history.items.len > 0 and agent.history.items[0].role == .system) {
            agent.history.items[0].deinit(allocator);
            agent.history.items[0] = .{
                .role = .system,
                .content = full_system,
            };
            full_system_owned = false;
        } else if (agent.history.items.len > 0) {
            try agent.history.insert(allocator, 0, .{
                .role = .system,
                .content = full_system,
            });
            full_system_owned = false;
        } else {
            try agent.history.append(allocator, .{
                .role = .system,
                .content = full_system,
            });
            full_system_owned = false;
        }
        agent.has_system_prompt = true;
        agent.system_prompt_has_conversation_context = refresh_plan.conversation_context_present;
        agent.system_prompt_conversation_context_fingerprint = refresh_plan.conversation_context_fingerprint;
        agent.workspace_prompt_fingerprint = refresh_plan.workspace_prompt_fingerprint;
        agent.system_prompt_time_bucket_min = refresh_plan.current_time_bucket_min;

        return .{
            .prompt_refreshed = refresh_plan.should_refresh_system_prompt,
            .workspace_prompt_changed = refresh_plan.workspace_prompt_changed,
            .time_bucket_changed = refresh_plan.time_bucket_changed,
            .conversation_context_changed = refresh_plan.conversation_context_changed,
            .stable_prefix_state = stable_prefix_state,
            .token_estimate = snapshot.token_estimate,
            .context_pressure_percent = snapshot.context_pressure_percent,
            .compaction_recommended = snapshot.token_compaction_triggered,
            .stable_prefix_hash = stable_prefix_hash,
            .stable_prefix_bytes = stable_prefix_len,
            .tail_hash = tail_hash,
            .tail_bytes = tail_bytes,
        };
    }

    /// Phase 3: Compact — token-budget compaction (Pass A + Pass C).
    ///
    /// v1.14.14 Phase 3 (CONTEXT-ENGINE audit-ledger row): owns the
    /// auto-compaction call shape that previously inlined at 8 sites in
    /// `Agent.turnOutcome` (cache-hit branches, response-cache hit branch,
    /// main flow, tool-loop post-tool, exhausted-iteration recovery, etc.).
    /// Each call site previously wrote 3-4 lines of `history_before` capture,
    /// `autoCompactHistory()` call, `last_turn_compacted` set, and
    /// `recordAutoCompaction()` record. This method consolidates them.
    ///
    /// The iter20 70/80/90 threshold escalation + iter19 anti-thrash guard
    /// remain inside `Agent.autoCompactHistory` (root.zig) where the
    /// thrash-ring state lives. This wrapper is the canonical entry point;
    /// it does NOT bypass the guard, and site-specific post-compact actions
    /// (continuity refresh, duration logging, observer events) continue to
    /// fire at the call site after this method returns.
    pub fn compact(self: *ContextEngine, agent: anytype) CompactResult {
        self.phase = .compacting;
        defer self.phase = .idle;

        const before = agent.history.items.len;
        const compacted = agent.autoCompactHistory() catch false;
        if (compacted) {
            // IMPORTANT: only set `last_turn_compacted = true` — never
            // clobber to false. The guard at root.zig:3753
            // (`if (... and !self.last_turn_compacted) { ... }`) uses this
            // flag as "did this turn experience ANY successful compaction?"
            // — overwriting a prior `true` from an earlier in-turn compact
            // with the current call's `false` would defeat the guard and
            // cause double-compaction attempts in the same turn.
            agent.last_turn_compacted = true;
            const after = agent.history.items.len;
            agent.recordAutoCompaction(before, after);
            return .{ .compacted = true, .method = .auto };
        }
        return .{ .compacted = false, .method = .none };
    }

    /// Phase 3 emergency path: force-compress history.
    ///
    /// v1.14.14 Phase 3: routes the 3 force-compress call sites in
    /// `Agent.turnOutcome` (context-exhaustion recovery inside the tool loop
    /// retry paths) through one method. Each call site previously wrote a
    /// `history_before` capture, `forceCompressHistory()` call,
    /// `recordForceCompression()` record, and two state-flag writes
    /// (`context_was_compacted = true; context_force_compressed = true`).
    /// This method consolidates all five.
    ///
    /// Unlike `compact()`, this path BYPASSES the iter19 anti-thrash guard
    /// — force-compress is the emergency lever that fires when the model
    /// has exceeded its budget and the only path forward is to drop content
    /// from the middle of history. Anti-thrash is for "is it worth running
    /// compaction this turn?"; force-compress is "we have no choice."
    pub fn forceCompact(self: *ContextEngine, agent: anytype) CompactResult {
        self.phase = .compacting;
        defer self.phase = .idle;

        const before = agent.history.items.len;
        const compacted = agent.forceCompressHistory();
        if (compacted) {
            const after = agent.history.items.len;
            agent.recordForceCompression(before, after);
            agent.context_was_compacted = true;
            agent.context_force_compressed = true;
            return .{ .compacted = true, .method = .force_compress };
        }
        return .{ .compacted = false, .method = .none };
    }

    /// Phase 4: After Turn — record lifecycle stats + emit stability snapshot.
    ///
    /// v1.14.14 Phase 4 (CONTEXT-ENGINE audit-ledger row): the
    /// production turn loop now calls this once per turn at the normal-exit
    /// boundary. Receives the aggregated phase results + per-phase durations
    /// + the assembled prefix hash, writes a one-line JSONL stability record
    /// to `NULLALIS_STABILITY_JSON_PATH` (when set), and returns the
    /// `TurnContextResult` aggregation for caller use.
    ///
    /// Filesystem emission is best-effort — failures are silent. Stability
    /// emission must NEVER block the turn (operator dashboards are
    /// diagnostic, not blocking).
    pub fn afterTurn(
        self: *ContextEngine,
        allocator: std.mem.Allocator,
        ingest_result: IngestResult,
        assemble_result: AssembleResult,
        compact_result: CompactResult,
        durations: PhaseDurations,
        turn_start_ms: i64,
        session: []const u8,
    ) TurnContextResult {
        self.phase = .after_turn;
        defer self.phase = .idle;

        const after_turn_start_ms = std.time.milliTimestamp();
        const total_duration: u64 = @intCast(@max(0, after_turn_start_ms - turn_start_ms));

        const auto_compacted = compact_result.method == .auto;
        const force_compressed = compact_result.method == .force_compress;

        // Stability snapshot (env-gated). after_turn_ms intentionally measured
        // BEFORE the file write so the duration captures lifecycle work only,
        // not diagnostic I/O.
        const after_turn_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - after_turn_start_ms));
        writeStabilityJsonl(allocator, .{
            .turn_start_ms = turn_start_ms,
            .ingest_ms = durations.ingest_ms,
            .assemble_ms = durations.assemble_ms,
            // v1.14.14.1 Finding 3: caller (root.zig defer) still passes the
            // main-flow-only `turn_compaction_ms` via durations.compact_ms;
            // renamed to compact_ms_main_site_only when it crosses the
            // operator boundary (StabilityRecord + JSONL).
            .compact_ms_main_site_only = durations.compact_ms,
            .after_turn_ms = after_turn_ms,
            .total_turn_ms = total_duration,
            .stable_prefix_hash = assemble_result.stable_prefix_hash,
            .stable_prefix_bytes = assemble_result.stable_prefix_bytes,
            .tail_hash = assemble_result.tail_hash,
            .tail_bytes = assemble_result.tail_bytes,
            .session = session,
        });

        // v1.14.14.1 Finding 4: the per-site message counts
        // (auto_compacted_messages / force_compressed_messages /
        // history_messages_after_trim) used to derive from
        // CompactResult.messages_before/after. Those fields are removed —
        // the source of truth is `agent.last_turn_context`, populated by
        // recordAutoCompaction / recordForceCompression inside
        // compact()/forceCompact(). The TurnContextResult.last_turn
        // returned here only carries the event-count signals (1/0) +
        // assemble/ingest stats. Production discards this return value
        // (`_ = afterTurn(...)`); the live agent.last_turn_context is
        // the channel-facing surface.
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
                .force_compression_events = if (force_compressed) 1 else 0,
            },
            .total_duration_ms = total_duration,
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Format a compact per-bucket entry summary for the memory_retrieval trace
/// event's status field. Caller owns the returned slice and must free it with
/// the same allocator.
fn bucketSummary(allocator: std.mem.Allocator, stats: memory_loader.SelectionStats) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "continuity:{d},semantic:{d},fallback:{d},graph:{d}",
        .{
            stats.continuity_bucket_entries,
            stats.semantic_bucket_entries,
            stats.fallback_bucket_entries,
            stats.graph_recall_neighbor_count,
        },
    );
}

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

// v1.14.14 Phase 2: the pre-extraction "assemble returns idle phase after
// completion" test was a lightweight smoke test on the old thin assemble that
// only computed stats. The new heavy assemble owns the full system-prompt
// assembly + history[0] mutation + 5 state-field writes, with hard
// dependencies on Memory, MemoryRuntime, zaki_state.Manager, prompt module,
// dispatcher module, capabilities module, and procedural_memory module.
// Construction of a duck-typed fake-agent that satisfies every concrete-typed
// call along that chain is a >300-line scaffold for a single test. Parity is
// instead guarded by:
//   (1) the integration tests in the canonical-profile build
//       (`zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram`)
//       which exercise the real turnOutcome → ContextEngine.assemble path with
//       real Agent + Memory + Manager instances, and
//   (2) the existing AssembleResult-field tests below — covering the new
//       stable_prefix_hash / stable_prefix_bytes surface against accidental
//       removal.
test "AssembleResult exposes prefix + tail hash defaults" {
    const r = AssembleResult{};
    try std.testing.expectEqual(@as(u64, 0), r.stable_prefix_hash);
    try std.testing.expectEqual(@as(usize, 0), r.stable_prefix_bytes);
    // v1.14.14.1 Finding 2: PREFIX-TAIL-SURFACE added the tail fields.
    try std.testing.expectEqual(@as(u64, 0), r.tail_hash);
    try std.testing.expectEqual(@as(usize, 0), r.tail_bytes);
    try std.testing.expect(!r.compaction_recommended);
    try std.testing.expect(!r.prompt_refreshed);
}

test "formatStabilityJsonlLine escapes session and preserves hash strings" {
    const allocator = std.testing.allocator;
    const session = "agent:\"zaki\"\nmain\\tail";
    const line = try formatStabilityJsonlLine(allocator, .{
        .turn_start_ms = 11,
        .ingest_ms = 1,
        .assemble_ms = 2,
        .compact_ms_main_site_only = 3,
        .after_turn_ms = 4,
        .total_turn_ms = 10,
        .stable_prefix_hash = 0xabc,
        .stable_prefix_bytes = 123,
        .tail_hash = 0x2a,
        .tail_bytes = 45,
        .session = session,
    });
    defer allocator.free(line);

    try std.testing.expect(line.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);

    const json = line[0 .. line.len - 1];
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings(session, obj.get("session").?.string);
    try std.testing.expectEqualStrings("abc", obj.get("stable_prefix_hash").?.string);
    try std.testing.expectEqualStrings("2a", obj.get("tail_hash").?.string);
    try std.testing.expectEqual(@as(i64, 11), obj.get("turn_start_ms").?.integer);
}

test "formatStabilityJsonlLine handles long session identifiers" {
    const allocator = std.testing.allocator;
    const session = try allocator.alloc(u8, 1500);
    defer allocator.free(session);
    @memset(session, 's');

    const line = try formatStabilityJsonlLine(allocator, .{
        .turn_start_ms = 1,
        .ingest_ms = 0,
        .assemble_ms = 0,
        .compact_ms_main_site_only = 0,
        .after_turn_ms = 0,
        .total_turn_ms = 0,
        .stable_prefix_hash = 0,
        .stable_prefix_bytes = 0,
        .tail_hash = 0,
        .tail_bytes = 0,
        .session = session,
    });
    defer allocator.free(line);

    try std.testing.expect(line.len > 1024);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1500), parsed.value.object.get("session").?.string.len);
}

// v1.14.14 Phase 3: helper for the compact + forceCompact tests below. The
// new compact/forceCompact methods own state writes on the agent
// (last_turn_compacted, context_was_compacted, context_force_compressed,
// compaction_savings_ring via recordAutoCompaction/recordForceCompression).
// This fake records every call + state mutation deterministically so
// unit tests can assert the route-through semantics without spinning up a
// real Memory/Provider/history pipeline.
const FakeCompactAgent = struct {
    history: struct {
        const FakeMsg = struct { role: enum { user, assistant }, content: []const u8 };
        items: []const FakeMsg = &.{},
    } = .{},
    last_turn_compacted: bool = false,
    context_was_compacted: bool = false,
    context_force_compressed: bool = false,
    // Behavior switches the fake agent exposes for the test.
    auto_returns: bool = false, // value autoCompactHistory returns
    force_returns: bool = false, // value forceCompressHistory returns
    auto_calls: u32 = 0,
    force_calls: u32 = 0,
    auto_recorded: u32 = 0,
    force_recorded: u32 = 0,

    pub fn autoCompactHistory(self: *FakeCompactAgent) !bool {
        self.auto_calls += 1;
        return self.auto_returns;
    }
    pub fn forceCompressHistory(self: *FakeCompactAgent) bool {
        self.force_calls += 1;
        return self.force_returns;
    }
    pub fn recordAutoCompaction(self: *FakeCompactAgent, _: usize, _: usize) void {
        self.auto_recorded += 1;
    }
    pub fn recordForceCompression(self: *FakeCompactAgent, _: usize, _: usize) void {
        self.force_recorded += 1;
    }
};

test "compact: no-op when autoCompactHistory returns false — method=none, no record, last_turn_compacted=false" {
    var engine = ContextEngine{};
    var fake_agent = FakeCompactAgent{ .auto_returns = false };
    const result = engine.compact(&fake_agent);

    try std.testing.expect(!result.compacted);
    try std.testing.expectEqual(CompactResult.CompactMethod.none, result.method);
    try std.testing.expectEqual(@as(u32, 1), fake_agent.auto_calls);
    try std.testing.expectEqual(@as(u32, 0), fake_agent.auto_recorded);
    try std.testing.expect(!fake_agent.last_turn_compacted);
    try std.testing.expectEqual(LifecyclePhase.idle, engine.phase);
}

test "compact: success path — auto+record fire, last_turn_compacted=true, method=.auto" {
    var engine = ContextEngine{};
    var fake_agent = FakeCompactAgent{ .auto_returns = true };
    const result = engine.compact(&fake_agent);

    try std.testing.expect(result.compacted);
    try std.testing.expectEqual(CompactResult.CompactMethod.auto, result.method);
    try std.testing.expectEqual(@as(u32, 1), fake_agent.auto_calls);
    try std.testing.expectEqual(@as(u32, 1), fake_agent.auto_recorded);
    try std.testing.expect(fake_agent.last_turn_compacted);
}

test "forceCompact: no-op when forceCompressHistory returns false — method=none, no record, flags untouched" {
    var engine = ContextEngine{};
    var fake_agent = FakeCompactAgent{ .force_returns = false };
    const result = engine.forceCompact(&fake_agent);

    try std.testing.expect(!result.compacted);
    try std.testing.expectEqual(CompactResult.CompactMethod.none, result.method);
    try std.testing.expectEqual(@as(u32, 1), fake_agent.force_calls);
    try std.testing.expectEqual(@as(u32, 0), fake_agent.force_recorded);
    try std.testing.expect(!fake_agent.context_was_compacted);
    try std.testing.expect(!fake_agent.context_force_compressed);
}

test "forceCompact: success path — record fires + both compact flags set, method=.force_compress" {
    var engine = ContextEngine{};
    var fake_agent = FakeCompactAgent{ .force_returns = true };
    const result = engine.forceCompact(&fake_agent);

    try std.testing.expect(result.compacted);
    try std.testing.expectEqual(CompactResult.CompactMethod.force_compress, result.method);
    try std.testing.expectEqual(@as(u32, 1), fake_agent.force_calls);
    try std.testing.expectEqual(@as(u32, 1), fake_agent.force_recorded);
    try std.testing.expect(fake_agent.context_was_compacted);
    try std.testing.expect(fake_agent.context_force_compressed);
}

// Brief-required test: 15 rapid-fire compact() calls — when the fake
// reports auto_returns=false (simulating thrash guard or any other rejection),
// no recording fires from rounds 3-15. Validates the route-through doesn't
// inadvertently double-fire recordAutoCompaction. The actual thrash-guard
// log-line `compaction.skipped reason=thrash_guard` fires inside
// Agent.autoCompactHistory (root.zig:973-982) which the fake stubs out;
// this test guards the wrapper's "don't double-record" contract.
test "compact: 15 rapid-fire false-returning calls record zero times (wrapper contract)" {
    var engine = ContextEngine{};
    var fake_agent = FakeCompactAgent{ .auto_returns = false };

    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        const result = engine.compact(&fake_agent);
        try std.testing.expect(!result.compacted);
    }
    try std.testing.expectEqual(@as(u32, 15), fake_agent.auto_calls);
    try std.testing.expectEqual(@as(u32, 0), fake_agent.auto_recorded);
    try std.testing.expect(!fake_agent.last_turn_compacted);
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
    const compact_result = CompactResult{ .compacted = false, .method = .none };
    const start_ms = std.time.milliTimestamp() - 10;
    const result = engine.afterTurn(
        std.testing.allocator,
        ingest_result,
        assemble_result,
        compact_result,
        .{},
        start_ms,
        "test-session",
    );

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
    const compact_result = CompactResult{ .compacted = true, .method = .auto };
    const result = engine.afterTurn(
        std.testing.allocator,
        ingest_result,
        assemble_result,
        compact_result,
        .{},
        std.time.milliTimestamp(),
        "test-session",
    );

    // v1.14.14.1 Finding 4: auto_compacted_messages / history_messages_after_trim
    // no longer flow through CompactResult — agent.last_turn_context is the
    // source of truth (populated by recordAutoCompaction). The afterTurn
    // return value only exposes event-count signals now.
    try std.testing.expectEqual(@as(usize, 1), result.last_turn.auto_compaction_events);
    try std.testing.expectEqual(@as(usize, 0), result.last_turn.force_compression_events);
}

test "afterTurn records force_compress events" {
    var engine = ContextEngine{};
    const ingest_result = IngestResult{};
    const assemble_result = AssembleResult{};
    const compact_result = CompactResult{ .compacted = true, .method = .force_compress };
    const result = engine.afterTurn(
        std.testing.allocator,
        ingest_result,
        assemble_result,
        compact_result,
        .{},
        std.time.milliTimestamp(),
        "test-session",
    );

    try std.testing.expectEqual(@as(usize, 0), result.last_turn.auto_compaction_events);
    try std.testing.expectEqual(@as(usize, 1), result.last_turn.force_compression_events);
}
