//! V1.14.8 — Boundary extraction runner.
//!
//! Single entry point used by every boundary trigger:
//!   - Pass A drop-from-middle (mid-session, extract-only via
//!     `enable_hydration=false`)
//!   - Pass C full LLM summarization (extract + hydrate)
//!   - Session-end TTL (extract + hydrate)
//!
//! Per boundary fire:
//!   1. Build a transcript of the conversation window once (reused).
//!   2. Run extraction LLM call → JSON {entities, edges} → ExtractionResult.
//!   3. Run hydration LLM call → XML <summary> → HydrationSummary
//!      (skipped when `ctx.enable_hydration=false`).
//!   4. Persist extraction via existing extraction_persist.persistExtracted
//!      (entity coref, edge upsert, vector sync, working memory promotion).
//!   5. Persist hydration as `summary_latest/<session>` text payload.
//!   6. Return BoundaryResult so caller can attach to its own telemetry.
//!
//! Failure-soft at every layer: any LLM/parse/persist error is logged and
//! the corresponding output null'd; the boundary's primary write proceeds.
//! Skips silently when extraction context lacks the required plumbing
//! (no extract provider/model, no state_mgr, etc.).

const std = @import("std");
const log = std.log.scoped(.extraction_runner);

const providers = @import("../../providers/root.zig");
const memory_root = @import("../../memory/root.zig");
const zaki_state = @import("../../zaki_state.zig");

const schema = @import("schema.zig");
const prompts = @import("prompts.zig");
const parser = @import("parser.zig");
const chunker = @import("chunker.zig");
const merger = @import("merger.zig");
const telemetry = @import("telemetry.zig");
const extraction_persist = @import("../extraction_persist.zig");
const working_memory = @import("../working_memory.zig");

/// V1.14.8 C4 — map a schema.Edge.SlotIntent to the static
/// working_memory.SlotType string the persist layer expects.
/// Returns null when the LLM didn't tag intent or when the intent
/// has no corresponding working-memory slot type (`.preference` —
/// preferences live in canonical memory, not working slots).
fn slotIntentToWorkingMemoryType(intent: ?schema.Edge.SlotIntent) ?[]const u8 {
    const i = intent orelse return null;
    return switch (i) {
        .open_loop => working_memory.SlotType.open_loop,
        .active_goal => working_memory.SlotType.active_goal,
        .decision => working_memory.SlotType.decision,
        .identity => working_memory.SlotType.identity,
        .temporal => working_memory.SlotType.temporal,
        .preference => null, // preferences stay in canonical memory only
    };
}

const Memory = memory_root.Memory;
const MemoryRuntime = memory_root.MemoryRuntime;
const ChatMessage = providers.ChatMessage;
const Provider = providers.Provider;

/// All inputs the runner needs to fire both LLM calls and persist results.
/// Required for extraction: extract_provider + extract_model, or the legacy
/// judge_provider + judge_model pair as a fallback.
/// Required for persistence: state_mgr + user_id.
/// Optional: judge_provider + judge_model for contradiction/cardinality checks,
/// session_id, coref_embed, archive_mem, archive_mem_rt.
///
/// When required fields are missing, the corresponding output is silently
/// skipped — the runner does NOT error.
pub const ExtractionContext = struct {
    extract_provider: ?Provider = null,
    extract_model: []const u8 = "",
    judge_provider: ?Provider = null,
    judge_model: []const u8 = "",
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,
    session_id: ?[]const u8 = null,
    coref_embed: ?@import("../../memory/vector/embeddings.zig").EmbeddingProvider = null,
    archive_mem: ?Memory = null,
    archive_mem_rt: ?*MemoryRuntime = null,
    /// Total transcript byte cap. The transcript builder truncates to this
    /// (per-message 2KB cap is applied first via the message-level loop).
    /// 80KB matches the existing buildCompactionTranscript default.
    max_source_chars: u32 = 80_000,
    /// LLM call timeout in seconds. Boundaries are infrequent so we afford
    /// a longer budget than per-turn calls.
    timeout_secs: u64 = 60,
    /// V1.14.8 C6 — when false, the hydration LLM call is skipped entirely
    /// and `BoundaryResult.hydration` is null. Pass A drop windows set this
    /// false: each drop is a partial mid-session slice, NOT a full session
    /// summary; the session-end boundary owns hydration for that. Pass C +
    /// session-end keep this true (default) — they're whole-window
    /// distillation moments where the hydration summary is genuinely useful.
    enable_hydration: bool = true,
    /// V1.14.9 — Target episode size in estimated tokens (chunker soft
    /// target). Lower = more, smaller calls (better coherence, higher
    /// total cost). Higher = fewer, larger calls. 4000 is the
    /// Llama-3.3-70B-Instruct-Turbo coherence sweet spot per the
    /// 2026-05-10 research report.
    target_episode_tokens: u32 = 4000,
    /// V1.14.9 — Hard cap on episode size in tokens. Mid-turn splits
    /// only fire when adding the next message would exceed this.
    /// Conventionally 2x target.
    max_episode_tokens: u32 = 8000,
    /// V1.14.9 — Cost guard. Max extraction LLM calls per boundary.
    /// When chunker emits more, sample first 5 + last (cap-5) to
    /// preserve narrative anchor + recent context. 20 = ~$0.04 per
    /// boundary at Llama prices.
    max_episodes_per_boundary: u32 = 20,
    /// V1.14.9 review fix L-01 — explicit boundary kind for telemetry
    /// tagging. Pre-fix: runner inferred kind from
    /// `enable_hydration=false` → Pass A. Brittle: any future caller
    /// setting `enable_hydration=false` for a different reason
    /// (cost/latency optimization, debug mode, etc.) would mis-tag.
    /// Now callers set this explicitly. Default `.session_end` is
    /// conservative — it implies hydration=on (default) and assumes a
    /// full-window distillation, which matches the most common
    /// boundary type.
    boundary_kind: telemetry.BoundaryKind = .session_end,
    /// V1.14.9 — Parallelism for episode fan-out. 1 = sequential.
    /// Higher = parallel via std.Thread.Pool.
    ///
    /// V1.14.9 P7 (2026-05-18): dropped default from 8 → 4 after F5
    /// conv-43 observed 38 `AllProvidersFailed` events across one
    /// boundary fire (3 episode extractions + 20 edge_resolution judge
    /// calls + 15 entity coref embeds), all symptoms of Together's
    /// rate-limit window getting blasted by an 8-wide burst followed
    /// by the SERIAL persistExtracted pipeline (judge + embed per
    /// fact) hitting the same window before it resets.
    ///
    /// 4-way halves the burst-rate equivalent (168 req/min → 70 req/
    /// min on a 14-episode boundary), expected to lift episode success
    /// from 79% → 95%+. Wall-time goes from ~5s (2 batches of 8) to
    /// ~12s (4 batches of 4) per boundary. Acceptable; boundaries
    /// fire infrequently (once per Pass A drop / Pass C / session-end).
    /// Operators can re-tune via ExtractionContext at the call site
    /// if their provider has a more generous rate limit.
    extraction_concurrency: u32 = 4,
    /// V1.14.12 (M1) — write origin tag for per-path telemetry.
    /// Passed through to `persistExtracted` inside this runner. Each
    /// of the three production callers of extractAtBoundary must set
    /// the right tag (pass_a_drop / pass_c_compaction_extract /
    /// session_end_extract).
    ///
    /// V1.14.12 (M1 review HIGH#1 fix) — default changed from
    /// .session_end_extract → .unknown. Pre-fix a forgotten field on
    /// a new ExtractionContext construction silently inflated the
    /// session_end histogram. Post-fix a forgotten field surfaces as
    /// `.unknown` in the histogram — a LOUD signal that a new
    /// callsite needs a precise tag. M3/M5 redundancy gates depend on
    /// accurate per-path distributions; this default change protects
    /// those gates from silent corruption.
    write_origin: @import("../extraction_persist.zig").WriteOrigin = .unknown,
    /// V1.14.12 (M3) — coverage filter gate. When true (default),
    /// boundary extraction skips facts whose canonical key matches
    /// one already written by the agent's memory_store tool (per
    /// state_mgr.listAgentMemoryStoreKeys, horizon-bounded). When
    /// false, boundary extraction processes all extracted edges
    /// (pre-M3 behavior).
    ///
    /// Operators disable via `agent.extraction_coverage_filter_enabled
    /// = false` in config.json. Coverage filter is the architectural
    /// fix for the Captain Mochi double-write problem — disable only
    /// for debugging or migration scenarios.
    coverage_filter_enabled: bool = true,
    /// V1.14.12 (M3 review MED) — coverage filter horizon bounds.
    /// Promoted from hardcoded local consts so high-volume tenants
    /// can tune. Defaults match the reviewer-approved horizons.
    /// horizon_days = 30 means agent-store'd facts older than 30 days
    /// don't suppress re-extraction (allows cardinality drift to
    /// surface). horizon_session_cap = 5000 bounds memory usage on
    /// long-active users; the SQL ORDER BY created_at DESC ensures
    /// eviction is recency-based (M3 review MEDIUM#5).
    coverage_horizon_days: u32 = 30,
    coverage_horizon_session_cap: u32 = 5000,
    /// V1.14.12 (M2 review CRITICAL) — cardinality fast-path flag,
    /// passed through to JudgeContext inside persistExtraction so
    /// operator config actually controls M2 behavior. Default true
    /// preserves M2 fast-path effects.
    cardinality_fastpath_enabled: bool = true,
    /// P3 (memory-phase-0.5) — semantic type-routing flag, passed through
    /// to JudgeContext so persistExtracted routes memory_type by fact
    /// meaning per operator config. Default true.
    semantic_type_routing_enabled: bool = true,
};

/// V1.14.9 — Episode-based boundary extraction. Replaces the V1.14.8
/// "one giant LLM call on the full window" pattern that degraded to
/// entities=0 edges=0 on long sessions (293-msg windows truncated to
/// 80KB of fragments).
///
/// Pipeline:
///   1. chunker.chunkIntoEpisodes(window) → semantic episodes
///   2. for each episode: build per-episode transcript (no aggressive
///      per-msg cap), fire one extraction LLM call. Sequential in P3;
///      parallel in P4 (gated by ctx.extraction_concurrency).
///   3. merger.mergeEpisodeResults(results) → ONE merged ExtractionResult
///      (entity coref + structural edge dedup)
///   4. Hydration runs ONCE on a condensed full-window transcript
///      (it's a summary, not an extraction — one coherent call is
///      correct shape).
///   5. persistExtraction (existing path) handles MD5 + semantic dedup
///      on the merged result.
///
/// Caller frees via BoundaryResult.deinit.
pub fn extractAtBoundary(
    allocator: std.mem.Allocator,
    window: []const ChatMessage,
    ctx: ExtractionContext,
) schema.BoundaryResult {
    if (window.len == 0) {
        log.info("boundary.skip reason=empty_window", .{});
        return .{ .extraction = null, .hydration = null };
    }
    if (resolveExtractionProvider(ctx) == null or resolveExtractionModel(ctx).len == 0) {
        log.info("boundary.skip reason=no_extraction_model", .{});
        return .{ .extraction = null, .hydration = null };
    }

    // Phase 1 — chunk into semantic episodes.
    const episodes = chunker.chunkIntoEpisodes(
        allocator,
        window,
        ctx.target_episode_tokens,
        ctx.max_episode_tokens,
        ctx.max_episodes_per_boundary,
    ) catch |err| {
        log.warn("boundary.chunk_failed err={s}", .{@errorName(err)});
        return .{ .extraction = null, .hydration = null };
    };
    defer allocator.free(episodes);

    if (episodes.len == 0) {
        log.info("boundary.skip reason=zero_episodes", .{});
        return .{ .extraction = null, .hydration = null };
    }

    log.info(
        "boundary.chunked window_msgs={d} episodes={d} target_tokens={d} max_episodes={d}",
        .{ window.len, episodes.len, ctx.target_episode_tokens, ctx.max_episodes_per_boundary },
    );

    // Phase 2 — extract per episode. Sequential when concurrency<=1
    // OR when there's only one episode (no point spinning up a pool).
    // Parallel via std.Thread.Pool when concurrency>1 and we have
    // multiple episodes. Timed for R1 telemetry (review fix M-04).
    const use_parallel = ctx.extraction_concurrency > 1 and episodes.len > 1;
    var extraction_timer = std.time.Timer.start() catch null;
    const episode_results = (if (use_parallel)
        extractEpisodesParallel(allocator, episodes, ctx)
    else
        extractEpisodesSequential(allocator, episodes, ctx)) catch |err| blk: {
        log.warn("boundary.extract_episodes_failed err={s}", .{@errorName(err)});
        break :blk null;
    };
    const extraction_ms_total: u64 = if (extraction_timer) |*t| t.read() / std.time.ns_per_ms else 0;
    defer if (episode_results) |er| freeEpisodeResults(allocator, er);

    // Phase 3 — merge with coref + structural dedup.
    const merged_extraction: ?schema.ExtractionResult = if (episode_results) |er| blk: {
        const coref_ctx: ?merger.CorefCtx = if (ctx.coref_embed) |ep|
            merger.CorefCtx{ .embed_provider = ep, .threshold = 0.95 }
        else
            null;
        break :blk merger.mergeEpisodeResults(allocator, er, coref_ctx) catch |err| inner: {
            log.warn("boundary.merge_failed err={s}", .{@errorName(err)});
            break :inner null;
        };
    } else null;

    // Phase 4 — hydration on a single condensed transcript (no chunking;
    // hydration is intentionally a whole-window summary). Timed for R1
    // telemetry (review fix M-04).
    var hydration_timer = std.time.Timer.start() catch null;
    const hydration_result: ?schema.HydrationSummary = if (ctx.enable_hydration) hydration: {
        const transcript = buildTranscript(allocator, window, ctx.max_source_chars) catch |err| {
            log.warn("boundary.hydration.transcript_failed err={s}", .{@errorName(err)});
            break :hydration null;
        };
        defer allocator.free(transcript);
        if (transcript.len == 0) break :hydration null;
        break :hydration runHydrationCall(allocator, transcript, ctx) catch |err| inner: {
            log.warn("boundary.hydration.call_failed err={s}", .{@errorName(err)});
            break :inner null;
        };
    } else null;
    const hydration_ms: u64 = if (ctx.enable_hydration)
        (if (hydration_timer) |*t| t.read() / std.time.ns_per_ms else 0)
    else
        0;

    // Phase 5 — persist (best-effort per layer).
    if (merged_extraction) |e| {
        persistExtraction(allocator, e, ctx) catch |err| {
            log.warn("boundary.extraction.persist_failed err={s}", .{@errorName(err)});
        };
    }
    if (hydration_result) |h| {
        persistHydration(allocator, h, ctx) catch |err| {
            log.warn("boundary.hydration.persist_failed err={s}", .{@errorName(err)});
        };
    }

    // Aggregate telemetry. R1's `boundary.metrics` log + zero_density
    // + episode_failure_high alerts live in telemetry.zig.
    const episodes_extracted_success = if (episode_results) |er| countNonNull(er) else 0;
    const episodes_extracted_failed = if (episode_results) |er| er.len - episodes_extracted_success else 0;

    // Sum window bytes for density calculation. Cheap O(N) pass over
    // ChatMessage slice (no string copy).
    var window_bytes: u64 = 0;
    for (window) |m| window_bytes += m.content.len;

    telemetry.recordBoundary(.{
        .kind = ctx.boundary_kind,
        .window_msg_count = @intCast(window.len),
        .window_byte_total = window_bytes,
        .episodes_chunked = @intCast(episodes.len),
        .episodes_extracted_success = @intCast(episodes_extracted_success),
        .episodes_extracted_failed = @intCast(episodes_extracted_failed),
        .entities_extracted = @intCast(if (merged_extraction) |e| e.entities.len else 0),
        .edges_extracted = @intCast(if (merged_extraction) |e| e.edges.len else 0),
        .hydration_present = hydration_result != null,
        // V1.14.9 review fix M-04: wall-clock timings via
        // std.time.Timer (captured around the fan-out + hydration
        // calls above). Hydration timer skipped when disabled.
        .extraction_ms_total = extraction_ms_total,
        .hydration_ms = hydration_ms,
    });

    // Keep the legacy boundary.complete line for grep-compat with
    // any existing alerting that expects it. telemetry.zig's
    // boundary.metrics is the canonical structured log going forward.
    log.info(
        "boundary.complete episodes={d} episodes_ok={d} episodes_failed={d} entities={d} edges={d} hydration_present={} window_msgs={d}",
        .{
            episodes.len,
            episodes_extracted_success,
            episodes_extracted_failed,
            if (merged_extraction) |e| e.entities.len else 0,
            if (merged_extraction) |e| e.edges.len else 0,
            hydration_result != null,
            window.len,
        },
    );

    return .{ .extraction = merged_extraction, .hydration = hydration_result };
}

// V1.14.9 review fix L-01: `inferBoundaryKind` removed in favor of
// `ExtractionContext.boundary_kind` set explicitly by each caller.
// Pass A wire sets `.pass_a`; Pass C wire sets `.pass_c`; session-end
// wire keeps the default `.session_end`. Telemetry tags accurately
// without inference.

/// V1.14.9 — Run extraction sequentially across episodes. Each
/// episode failure returns null in its slot; we don't abort the
/// whole boundary on one bad episode (partial signal beats none).
/// P4 introduces a parallel variant gated on
/// `ctx.extraction_concurrency`.
fn extractEpisodesSequential(
    allocator: std.mem.Allocator,
    episodes: []const chunker.Episode,
    ctx: ExtractionContext,
) ![]?schema.ExtractionResult {
    var results = try allocator.alloc(?schema.ExtractionResult, episodes.len);
    errdefer allocator.free(results);
    for (episodes, 0..) |ep, i| {
        results[i] = runExtractionOnEpisode(allocator, ep, ctx) catch |err| blk: {
            log.warn("boundary.episode[{d}].failed err={s} msgs={d}", .{ i, @errorName(err), ep.messages.len });
            break :blk null;
        };
    }
    return results;
}

/// V1.14.9 P4 — Parallel episode extraction via std.Thread.Pool.
/// Called when `ctx.extraction_concurrency > 1`. Each episode runs
/// in its own worker; failures are isolated (slot stays null,
/// others proceed). Caller frees via freeEpisodeResults.
///
/// Allocator thread-safety: the agent's primary allocator is
/// expected to be thread-safe (std.heap.GeneralPurposeAllocator with
/// `.thread_safe = true` OR the C allocator). The runner doesn't
/// override; it inherits whatever the caller passes. Each thread's
/// LLM call uses curl-subprocess transport (provider-level), which
/// is process-isolated and inherently thread-safe.
fn extractEpisodesParallel(
    allocator: std.mem.Allocator,
    episodes: []const chunker.Episode,
    ctx: ExtractionContext,
) ![]?schema.ExtractionResult {
    var results = try allocator.alloc(?schema.ExtractionResult, episodes.len);
    @memset(results, null);
    errdefer allocator.free(results);

    // Cap thread count at the smaller of (episodes count, configured
    // concurrency). No point spinning up 8 threads for 3 episodes.
    const n_jobs: usize = @min(episodes.len, @as(usize, ctx.extraction_concurrency));

    var pool: std.Thread.Pool = undefined;
    pool.init(.{ .allocator = allocator, .n_jobs = n_jobs }) catch |err| {
        log.warn("boundary.pool_init_failed err={s} falling_back=sequential", .{@errorName(err)});
        // Free the pre-allocated results array so the sequential path
        // can allocate fresh.
        allocator.free(results);
        return extractEpisodesSequential(allocator, episodes, ctx);
    };
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    for (episodes, 0..) |ep, i| {
        pool.spawnWg(&wg, episodeWorker, .{ &results[i], ep, ctx, allocator, i });
    }
    wg.wait();

    return results;
}

/// Worker function for parallel episode extraction. One per episode.
/// Writes its result (or null on failure) into the pre-allocated slot.
fn episodeWorker(
    slot: *?schema.ExtractionResult,
    episode: chunker.Episode,
    ctx: ExtractionContext,
    allocator: std.mem.Allocator,
    idx: usize,
) void {
    slot.* = runExtractionOnEpisode(allocator, episode, ctx) catch |err| blk: {
        log.warn("boundary.episode[{d}].parallel_failed err={s} msgs={d}", .{ idx, @errorName(err), episode.messages.len });
        break :blk null;
    };
}

/// Free an array of per-episode results allocated by
/// extractEpisodesSequential / extractEpisodesParallel.
fn freeEpisodeResults(allocator: std.mem.Allocator, results: []?schema.ExtractionResult) void {
    for (results) |opt| {
        if (opt) |r| r.deinit(allocator);
    }
    allocator.free(results);
}

fn countNonNull(results: []const ?schema.ExtractionResult) usize {
    var n: usize = 0;
    for (results) |r| {
        if (r != null) n += 1;
    }
    return n;
}

/// Per-message content cap inside `buildEpisodeTranscript`. Episodes
/// are bounded by `target_episode_tokens` overall but a SINGLE
/// pathologically-large message (tool output dump, file paste, very
/// long assistant reply) can still dominate the LLM's view and
/// recreate the V1.14.8 fragmentation failure mode. 8KB is generous
/// enough for substantive turn content while bounding the worst case.
/// Review fix M-03.
const PER_MESSAGE_EPISODE_CAP: usize = 8_000;

/// V1.14.9 — Build a transcript for ONE episode. Episodes are
/// bounded by `target_episode_tokens` at the chunker level, but
/// `buildEpisodeTranscript` still caps each individual message at
/// `PER_MESSAGE_EPISODE_CAP` so a single oversized tool output or
/// file dump can't dominate one episode's view and recreate the
/// V1.14.8 fragmentation problem at the per-episode level. When a
/// message is truncated, we append a sentinel so the LLM knows the
/// content was cut.
fn buildEpisodeTranscript(
    allocator: std.mem.Allocator,
    episode: chunker.Episode,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (episode.messages) |*msg| {
        const role_str: []const u8 = switch (msg.role) {
            .system => "SYSTEM",
            .user => "USER",
            .assistant => "ASSISTANT",
            .tool => "TOOL",
        };
        try buf.appendSlice(allocator, role_str);
        try buf.appendSlice(allocator, ": ");
        if (msg.content.len > PER_MESSAGE_EPISODE_CAP) {
            try buf.appendSlice(allocator, msg.content[0..PER_MESSAGE_EPISODE_CAP]);
            try buf.appendSlice(allocator, "\n[...truncated for extraction...]");
        } else {
            try buf.appendSlice(allocator, msg.content);
        }
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

/// V1.14.9 — Fire one extraction LLM call against a single episode.
/// Returns parsed ExtractionResult or null on any failure.
fn runExtractionOnEpisode(
    allocator: std.mem.Allocator,
    episode: chunker.Episode,
    ctx: ExtractionContext,
) !?schema.ExtractionResult {
    if (episode.messages.len == 0) return null;
    const transcript = try buildEpisodeTranscript(allocator, episode);
    defer allocator.free(transcript);
    if (transcript.len == 0) return null;
    return runExtractionCall(allocator, transcript, ctx);
}

/// Build a compact transcript of the conversation window. Per-message cap
/// of 2KB; total cap from `ctx.max_source_chars`. Mirrors compaction.zig's
/// buildCompactionTranscript but operates on `[]ChatMessage` directly so
/// the runner doesn't need to depend on compaction internals.
fn buildTranscript(
    allocator: std.mem.Allocator,
    window: []const ChatMessage,
    max_chars: u32,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (window) |*msg| {
        const role_str: []const u8 = switch (msg.role) {
            .system => "SYSTEM",
            .user => "USER",
            .assistant => "ASSISTANT",
            .tool => "TOOL",
        };
        try buf.appendSlice(allocator, role_str);
        try buf.appendSlice(allocator, ": ");
        const content = if (msg.content.len > 2000) msg.content[0..2000] else msg.content;
        try buf.appendSlice(allocator, content);
        try buf.append(allocator, '\n');

        if (buf.items.len > max_chars) break;
    }

    if (buf.items.len > max_chars) {
        buf.items.len = max_chars;
    }

    return buf.toOwnedSlice(allocator);
}

/// Run the extraction LLM call. Returns parsed ExtractionResult or null on
/// any failure. Caller owns the returned struct and must call deinit.
fn runExtractionCall(
    allocator: std.mem.Allocator,
    transcript: []const u8,
    ctx: ExtractionContext,
) !?schema.ExtractionResult {
    const provider = resolveExtractionProvider(ctx) orelse return null;
    const model = resolveExtractionModel(ctx);
    if (model.len == 0) return null;

    var messages = [_]ChatMessage{
        .{ .role = .system, .content = prompts.extractionSystemPrompt() },
        .{ .role = .user, .content = transcript },
    };
    const request = providers.ChatRequest{
        .messages = messages[0..],
        .model = model,
        .temperature = 0.2,
        .tools = null,
        .timeout_secs = ctx.timeout_secs,
    };

    const response = provider.chat(allocator, request, model, 0.2) catch |err| {
        log.warn("boundary.extraction.llm_failed err={s}", .{@errorName(err)});
        return null;
    };
    defer freeResponse(allocator, response);

    const content = response.content orelse return null;
    if (content.len == 0) return null;

    const result = parser.parseExtraction(allocator, content) catch |err| {
        log.warn("boundary.extraction.parse_failed err={s} raw_len={d}", .{ @errorName(err), content.len });
        return null;
    };

    return result;
}

/// Run the hydration LLM call. Same shape as extraction but XML output.
fn runHydrationCall(
    allocator: std.mem.Allocator,
    transcript: []const u8,
    ctx: ExtractionContext,
) !?schema.HydrationSummary {
    const provider = resolveExtractionProvider(ctx) orelse return null;
    const model = resolveExtractionModel(ctx);
    if (model.len == 0) return null;

    var messages = [_]ChatMessage{
        .{ .role = .system, .content = prompts.hydrationSystemPrompt() },
        .{ .role = .user, .content = transcript },
    };
    const request = providers.ChatRequest{
        .messages = messages[0..],
        .model = model,
        .temperature = 0.3,
        .tools = null,
        .timeout_secs = ctx.timeout_secs,
    };

    const response = provider.chat(allocator, request, model, 0.3) catch |err| {
        log.warn("boundary.hydration.llm_failed err={s}", .{@errorName(err)});
        return null;
    };
    defer freeResponse(allocator, response);

    const content = response.content orelse return null;
    if (content.len == 0) return null;

    const result = parser.parseHydration(allocator, content) catch |err| {
        log.warn("boundary.hydration.parse_failed err={s} raw_len={d}", .{ @errorName(err), content.len });
        return null;
    };
    return result;
}

fn resolveExtractionProvider(ctx: ExtractionContext) ?Provider {
    return ctx.extract_provider orelse ctx.judge_provider;
}

fn resolveExtractionModel(ctx: ExtractionContext) []const u8 {
    if (ctx.extract_model.len > 0) return ctx.extract_model;
    return ctx.judge_model;
}

/// Free response fields owned by the provider.chat callee. Mirrors the
/// existing pattern in commands.zig + compaction.zig.
fn freeResponse(allocator: std.mem.Allocator, response: providers.ChatResponse) void {
    if (response.content) |c| if (c.len > 0) allocator.free(c);
    for (response.tool_calls) |tc| {
        allocator.free(tc.id);
        allocator.free(tc.name);
        allocator.free(tc.arguments);
    }
    if (response.tool_calls.len > 0) allocator.free(response.tool_calls);
    if (response.model.len > 0) allocator.free(response.model);
    if (response.reasoning_content) |rc| if (rc.len > 0) allocator.free(rc);
}

/// V1.14.12 (M3 review HIGH#3) — coverage filter implementation,
/// extracted into a helper so persistExtraction can wrap it in a
/// single catch that no-ops on ANY failure (DB error, OOM,
/// key-compute failure). Filtering is an optimization; it must not
/// error-propagate to break boundary extraction.
///
/// Reads agent_keys via state_mgr.listAgentMemoryStoreKeys, builds
/// the canonical key for each candidate edge, and appends only
/// non-matching edges to `out`.
fn runCoverageFilter(
    allocator: std.mem.Allocator,
    smgr: *zaki_state.Manager,
    user_id: i64,
    edges: []const schema.Edge,
    out: *std.ArrayListUnmanaged(schema.Edge),
    horizon_days: u32,
    horizon_session_cap: u32,
) !void {
    const agent_keys = try smgr.listAgentMemoryStoreKeys(
        allocator,
        user_id,
        horizon_days,
        horizon_session_cap,
    );
    defer {
        for (agent_keys) |k| allocator.free(k);
        allocator.free(agent_keys);
    }

    if (agent_keys.len == 0) {
        log.info("boundary.extraction.coverage_filter agent_keys=0 — passive-only session", .{});
        try out.appendSlice(allocator, edges);
        return;
    }

    var key_set = std.StringHashMapUnmanaged(void){};
    defer key_set.deinit(allocator);
    for (agent_keys) |k| try key_set.put(allocator, k, {});

    var skipped: usize = 0;
    for (edges) |edge| {
        const candidate_key = extraction_persist.deriveExtractionKey(
            allocator,
            edge.source_name,
            edge.relation_type,
            edge.target_name,
        ) catch |err| {
            log.warn("boundary.extraction.coverage_key_compute_failed err={s} subject={s}", .{ @errorName(err), edge.source_name });
            // Conservative: keep on failure.
            try out.append(allocator, edge);
            continue;
        };
        defer allocator.free(candidate_key);
        if (key_set.contains(candidate_key)) {
            skipped += 1;
        } else {
            try out.append(allocator, edge);
        }
    }
    log.info(
        "boundary.extraction.coverage_filter agent_keys={d} input_edges={d} skipped={d} remaining={d}",
        .{ agent_keys.len, edges.len, skipped, out.items.len },
    );
}

/// Convert the structured ExtractionResult into ExtractedMemory[] and
/// persist via the existing extraction_persist.persistExtracted path
/// (entity coref + edge upsert + vector sync). This is where Layer 4
/// (graph) finally populates reliably.
fn persistExtraction(
    allocator: std.mem.Allocator,
    result: schema.ExtractionResult,
    ctx: ExtractionContext,
) !void {
    const smgr = ctx.state_mgr orelse {
        log.info("boundary.extraction.skip_persist reason=no_state_mgr", .{});
        return;
    };
    const uid = ctx.user_id orelse {
        log.info("boundary.extraction.skip_persist reason=no_user_id", .{});
        return;
    };
    if (result.edges.len == 0) {
        log.info("boundary.extraction.skip_persist reason=zero_edges", .{});
        return;
    }

    // V1.14.12 (M3) — coverage filter. Skip extracted edges whose
    // canonical key matches one already written by the agent's
    // memory_store tool. This is the architectural fix that prevents
    // boundary re-extraction from creating duplicates of facts the
    // agent already explicitly stored.
    //
    // Race-safety: extractAtBoundary fires AFTER the agent's turn loop
    // completes. All memory_store tool calls in this session have
    // already committed (synchronous within the turn) by the time
    // we reach here. Cross-session writes are visible via the SQL
    // query's user_id scope + horizon bounds.
    //
    // Failure mode: if the keys query fails (DB connection, etc.),
    // we LOG + PROCEED — filtering is an optimization, not a correctness
    // guarantee. Worst case: today's behavior (some duplicates, judge
    // cleans up via M2 fast-path or contradiction detection).
    //
    // Bounds: 30 days horizon + 5000 key cap. Tunable later.
    //
    // Filter runs BEFORE the ExtractedMemory allocation so we avoid the
    // partial-deinit / double-free hazard of in-place filtering a fixed
    // slice. The kept-edges slice is what feeds the persist call.
    //
    // V1.14.12 (M3 review MED) — horizon bounds read from ctx so
    // operators can tune per deployment (e.g., high-volume tenants may
    // need a larger key cap or shorter horizon to keep memory bounded).
    var kept_edges_buf = std.ArrayListUnmanaged(schema.Edge){};
    defer kept_edges_buf.deinit(allocator);

    // V1.14.12 (M3 review HIGH#3): wrap the coverage filter in a
    // self-contained block that NEVER fails the persist path. Any
    // error inside the filter (OOM, DB error, key compute failure)
    // logs + falls back to "no filtering" so the persist path
    // proceeds with all edges. Filtering is an optimization, not a
    // correctness gate — it must not error-propagate to break boundary
    // extraction.
    var filter_succeeded = true;
    if (ctx.coverage_filter_enabled) {
        runCoverageFilter(
            allocator,
            smgr,
            uid,
            result.edges,
            &kept_edges_buf,
            ctx.coverage_horizon_days,
            ctx.coverage_horizon_session_cap,
        ) catch |err| {
            log.warn("boundary.extraction.coverage_filter_failed err={s} — proceeding without filter", .{@errorName(err)});
            filter_succeeded = false;
        };
    }
    if (!ctx.coverage_filter_enabled or !filter_succeeded) {
        // Filter disabled OR filter errored — pass all edges through
        // (preserves pre-M3 behavior on failure).
        kept_edges_buf.clearRetainingCapacity();
        try kept_edges_buf.appendSlice(allocator, result.edges);
    }

    if (kept_edges_buf.items.len == 0) {
        log.info("boundary.extraction.skip_persist reason=coverage_filter_kept_zero", .{});
        return;
    }

    const kept_edges = kept_edges_buf.items;

    // Convert each kept edge to an ExtractedMemory. text/subject/predicate/
    // object map directly. attributed_to defaults to "user" (boundary
    // extraction is implicitly user-attributed; the agent's own writes go
    // through memory_store, not this path).
    //
    // P3 (memory-phase-0.5): attributed_to is now PROVENANCE-ONLY metadata,
    // not a type router — the durable memory_type is routed by the fact's
    // meaning (predicate semantics) at the persist site, gated by
    // semantic_type_routing_enabled. The schema.Edge here carries no real
    // observed-speaker field (only source_name, the subject entity), so
    // there is nothing more accurate to substitute; "user" stays as the
    // recorded provenance default for boundary extraction.
    const mems = try allocator.alloc(extraction_persist.ExtractedMemory, kept_edges.len);
    defer {
        for (mems) |m| m.deinit(allocator);
        allocator.free(mems);
    }

    for (kept_edges, 0..) |edge, i| {
        mems[i] = .{
            .text = try allocator.dupe(u8, edge.fact),
            .subject = try allocator.dupe(u8, edge.source_name),
            .predicate = try allocator.dupe(u8, edge.relation_type),
            .object = try allocator.dupe(u8, edge.target_name),
            .attributed_to = try allocator.dupe(u8, "user"),
            .confidence = edge.confidence orelse 0.85,
            .temporal_anchor_unix = edge.valid_at,
            // V1.14.8 C4: forward LLM-tagged slot intent to persistExtracted
            // so it promotes the right working-memory slot. Static-string
            // mapping — never freed by ExtractedMemory.deinit.
            .slot_intent = slotIntentToWorkingMemoryType(edge.slot_intent),
        };
    }

    // V1.14.12 (Path A) — judge_ctx is OPTIONAL. When ctx.judge_model is
    // empty (operator hasn't configured a judge model), we pass null
    // to persistExtracted which gracefully degrades to MD5+canonical-key
    // dedup only (no LLM-based contradiction detection).
    //
    // Pre-Path-A this was unconditionally constructed, which forced
    // every extractAtBoundary caller to gate on judge presence
    // upstream (commands.zig:1475 + compaction.zig:768). After M5
    // gated-code deletion, no-judge tenants would have silently lost
    // session-end writes via the deleted legacy direct path. Optional
    // judge_ctx restores graceful degradation through the
    // extractAtBoundary path.
    const judge_ctx: ?extraction_persist.JudgeContext =
        if (ctx.judge_model.len > 0 and ctx.judge_provider != null)
            extraction_persist.JudgeContext{
                .provider = ctx.judge_provider.?,
                .model_name = ctx.judge_model,
                .cardinality_fastpath_enabled = ctx.cardinality_fastpath_enabled,
                .semantic_type_routing_enabled = ctx.semantic_type_routing_enabled, // P3
            }
        else
            null;
    const coref_ctx: ?extraction_persist.EntityResolution = if (ctx.coref_embed) |ep|
        extraction_persist.EntityResolution{ .embed_provider = ep, .threshold = 0.95 }
    else
        null;

    // P3: capture boundary timestamp immediately before persist so all
    // edges written in this batch share a stable grouping key. All three
    // boundary callers (pass_a_drop, pass_c_compaction_extract,
    // session_end_extract) flow through here, so a single capture point
    // is sufficient. Non-boundary callers don't reach extractAtBoundary.
    const boundary_id = std.time.milliTimestamp();
    const persist_result = extraction_persist.persistExtracted(
        allocator,
        smgr,
        uid,
        ctx.session_id,
        mems,
        judge_ctx,
        coref_ctx,
        ctx.archive_mem_rt,
        ctx.write_origin, // V1.14.12 (M1) — per-path telemetry tag from caller
        boundary_id,      // P3: milliTimestamp at boundary fire
        ctx.semantic_type_routing_enabled, // P3 review: off-switch honored even with no judge
    ) catch |err| {
        log.warn("boundary.extraction.persistExtracted_failed err={s} edges={d}", .{ @errorName(err), result.edges.len });
        return;
    };

    log.info(
        "boundary.extraction.persisted edges_in={d} written={d} skipped_md5={d} skipped_semantic={d} contradictions_resolved={d}",
        .{
            result.edges.len,
            persist_result.written_count,
            persist_result.skipped_md5_dup,
            persist_result.skipped_semantic_dup,
            persist_result.contradictions_resolved,
        },
    );
}

/// Persist the hydration summary as `summary_latest/<session>` (Layer 2,
/// category=core). When archive_mem is null, hydration is silently skipped
/// — the runner doesn't error.
fn persistHydration(
    allocator: std.mem.Allocator,
    h: schema.HydrationSummary,
    ctx: ExtractionContext,
) !void {
    const archive_mem = ctx.archive_mem orelse {
        log.info("boundary.hydration.skip_persist reason=no_archive_mem", .{});
        return;
    };
    const session_id = ctx.session_id orelse {
        log.info("boundary.hydration.skip_persist reason=no_session_id", .{});
        return;
    };

    const summary_text = try h.renderText(allocator);
    defer allocator.free(summary_text);

    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "summary_latest/{s}", .{session_id}) catch return error.SessionIdTooLong;

    archive_mem.store(key, summary_text, .core, session_id) catch |err| {
        log.warn("boundary.hydration.store_failed err={s} session={s}", .{ @errorName(err), session_id });
        return;
    };
    if (ctx.archive_mem_rt) |rt| {
        _ = rt.syncVectorAfterStore(allocator, key, summary_text);
    }

    log.info("boundary.hydration.persisted session={s} bytes={d}", .{ session_id, summary_text.len });
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const TestExtractionProvider = struct {
    calls: usize = 0,

    fn chatWithSystem(_: *anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
        return "";
    }

    fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
        const self: *TestExtractionProvider = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return .{
            .content = try allocator.dupe(u8,
                \\{"entities":[{"name":"Nova","type":"person"},{"name":"nullALIS","type":"project"}],"edges":[{"source":"Nova","target":"nullALIS","predicate":"builds","fact":"Nova builds nullALIS","confidence":0.9}]}
            ),
        };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "test-extraction";
    }

    fn deinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinit,
    };

    fn provider(self: *TestExtractionProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

test "buildTranscript respects per-message + total caps" {
    const allocator = std.testing.allocator;
    const big_content = try allocator.alloc(u8, 5000);
    defer allocator.free(big_content);
    @memset(big_content, 'x');

    const msgs = [_]ChatMessage{
        .{ .role = .user, .content = "short user msg" },
        .{ .role = .assistant, .content = big_content },
    };
    const transcript = try buildTranscript(allocator, &msgs, 80_000);
    defer allocator.free(transcript);

    try std.testing.expect(std.mem.indexOf(u8, transcript, "USER: short user msg") != null);
    // Per-message 2KB cap applied
    try std.testing.expect(transcript.len < 5000 + 100);
    try std.testing.expect(transcript.len < 3000); // ~2KB + headers
}

test "extractAtBoundary skip path: empty window" {
    const allocator = std.testing.allocator;
    const empty_window: []const ChatMessage = &.{};
    const ctx = ExtractionContext{
        .extract_model = "test-model",
    };
    const result = extractAtBoundary(allocator, empty_window, ctx);
    defer result.deinit(allocator);
    try std.testing.expect(result.extraction == null);
    try std.testing.expect(result.hydration == null);
}

test "extractAtBoundary skip path: empty extraction model" {
    const allocator = std.testing.allocator;
    const msgs = [_]ChatMessage{.{ .role = .user, .content = "test" }};
    const ctx = ExtractionContext{};
    const result = extractAtBoundary(allocator, &msgs, ctx);
    defer result.deinit(allocator);
    try std.testing.expect(result.extraction == null);
    try std.testing.expect(result.hydration == null);
}

test "extractAtBoundary runs extraction without judge model" {
    const allocator = std.testing.allocator;
    var provider_state = TestExtractionProvider{};
    const msgs = [_]ChatMessage{.{ .role = .user, .content = "Nova is building nullALIS." }};
    const ctx = ExtractionContext{
        .extract_provider = provider_state.provider(),
        .extract_model = "extract-model",
        .judge_model = "",
        .enable_hydration = false,
    };
    const result = extractAtBoundary(allocator, &msgs, ctx);
    defer result.deinit(allocator);

    try std.testing.expect(provider_state.calls > 0);
    try std.testing.expect(result.extraction != null);
    try std.testing.expect(result.extraction.?.entities.len == 2);
    try std.testing.expect(result.extraction.?.edges.len == 1);
    try std.testing.expect(result.hydration == null);
}

test "persistExtraction skip path: no state mgr (no edges to persist)" {
    // F2 (V1.14.8 review fix): clarified test intent. With an empty
    // ExtractionResult both the no_state_mgr and zero_edges skip paths
    // would fire; the function returns silently regardless. The leak-free
    // exit is the actual contract.
    const allocator = std.testing.allocator;
    const result = try schema.ExtractionResult.empty(allocator);
    defer result.deinit(allocator);
    const ctx = ExtractionContext{
        .judge_model = "test-model",
        // state_mgr null; user_id null
    };
    try persistExtraction(allocator, result, ctx);
}

test "persistExtraction skip path: zero edges" {
    const allocator = std.testing.allocator;
    const result = try schema.ExtractionResult.empty(allocator);
    defer result.deinit(allocator);

    var fake_mgr: zaki_state.Manager = undefined;
    const ctx = ExtractionContext{
        .judge_model = "test-model",
        .state_mgr = &fake_mgr,
        .user_id = 42,
    };
    // zero edges → early return without touching state_mgr
    try persistExtraction(allocator, result, ctx);
}

test "ExtractionContext.enable_hydration default = true" {
    // F3 (V1.14.8 review fix): document + lock the default contract.
    // Pass A wires `enable_hydration = false` explicitly; Pass C +
    // session-end rely on the default `true` for hydration summaries.
    const ctx = ExtractionContext{
        .judge_model = "test-model",
    };
    try std.testing.expect(ctx.enable_hydration == true);
}

test "slotIntentToWorkingMemoryType maps every variant correctly" {
    // F4 (V1.14.8 review fix): enum-exhaustive test so adding a new
    // SlotIntent without updating the mapping (or vice versa) trips a
    // compile error here, not a silent runtime null-promotion.
    try std.testing.expectEqualStrings(
        working_memory.SlotType.open_loop,
        slotIntentToWorkingMemoryType(.open_loop).?,
    );
    try std.testing.expectEqualStrings(
        working_memory.SlotType.active_goal,
        slotIntentToWorkingMemoryType(.active_goal).?,
    );
    try std.testing.expectEqualStrings(
        working_memory.SlotType.decision,
        slotIntentToWorkingMemoryType(.decision).?,
    );
    try std.testing.expectEqualStrings(
        working_memory.SlotType.identity,
        slotIntentToWorkingMemoryType(.identity).?,
    );
    try std.testing.expectEqualStrings(
        working_memory.SlotType.temporal,
        slotIntentToWorkingMemoryType(.temporal).?,
    );
    // .preference intentionally returns null — preferences live in
    // canonical memory, not working slots.
    try std.testing.expect(slotIntentToWorkingMemoryType(.preference) == null);
    try std.testing.expect(slotIntentToWorkingMemoryType(null) == null);
}
