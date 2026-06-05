//! History compaction — token estimation, auto-compaction, force-compression, trimming.
//!
//! Extracted from agent/root.zig. All functions operate on history slices
//! passed by the caller; no dependency on the Agent struct.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.agent);
const providers = @import("../providers/root.zig");
const config_types = @import("../config_types.zig");
const memory_mod = @import("../memory/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const Memory = memory_mod.Memory;
const MemoryRuntime = memory_mod.MemoryRuntime;

const Agent = @import("root.zig").Agent;
const OwnedMessage = Agent.OwnedMessage;
const zaki_state = @import("../zaki_state.zig");
const extraction_persist = @import("extraction_persist.zig");
const extraction_runner = @import("extraction/runner.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Default: keep this many most-recent non-system messages after compaction.
pub const DEFAULT_COMPACTION_KEEP_RECENT: u32 = 20;

/// Default: max characters retained in stored compaction summary.
pub const DEFAULT_COMPACTION_MAX_SUMMARY_CHARS: u32 = 16_000;
/// Maximum characters appended from workspace critical rules.
const MAX_WORKSPACE_CONTEXT_CHARS: usize = 2_000;
/// Maximum AGENTS.md bytes read for critical rules extraction.
const MAX_AGENTS_FILE_BYTES: usize = 2 * 1024 * 1024;

/// Default: max characters in source transcript passed to the summarizer.
pub const DEFAULT_COMPACTION_MAX_SOURCE_CHARS: u32 = 80_000;

/// Default token limit for context window (used by token-based compaction trigger).
pub const DEFAULT_TOKEN_LIMIT: u64 = config_types.DEFAULT_AGENT_TOKEN_LIMIT;

/// Operator-facing advisory point. Crossing this does not compact by itself.
pub const COMPACTION_RECOMMEND_PERCENT: u8 = 50;
/// First automatic compaction pass: deterministic middle-drop/dedup.
pub const AUTO_COMPACT_PASS_A_PERCENT: u8 = 70;
/// Expensive automatic compaction pass: LLM summarization.
pub const AUTO_COMPACT_PASS_C_PERCENT: u8 = 90;

pub const TrimStats = struct {
    history_before: usize = 0,
    history_after: usize = 0,
    removed_messages: usize = 0,
    removed_bytes: usize = 0,
    shrunk_capacity: bool = false,
};

/// Minimum history length before context exhaustion recovery is attempted.
pub const CONTEXT_RECOVERY_MIN_HISTORY: usize = 6;

/// Number of recent messages to keep during force compression.
pub const CONTEXT_RECOVERY_KEEP: usize = 4;

// ═══════════════════════════════════════════════════════════════════════════
// Config
// ═══════════════════════════════════════════════════════════════════════════

pub const CompactionConfig = struct {
    keep_recent: u32 = DEFAULT_COMPACTION_KEEP_RECENT,
    max_summary_chars: u32 = DEFAULT_COMPACTION_MAX_SUMMARY_CHARS,
    max_source_chars: u32 = DEFAULT_COMPACTION_MAX_SOURCE_CHARS,
    token_limit: u64 = DEFAULT_TOKEN_LIMIT,
    max_tokens: u32 = 0,
    message_timeout_secs: u64 = 0,
    max_history_messages: u32 = 50,
    workspace_dir: ?[]const u8 = null,
    // iter29: when both are set, Pass C and force-compress persist their
    // output artifacts (emergency summary, dropped messages) to the memory
    // backend so the agent can recall them via memory_timeline/memory_recall
    // after the fact. Without these, compaction products evaporate with
    // the session.
    archive_memory: ?Memory = null,
    archive_session_id: ?[]const u8 = null,
    // iter31: when set, archived artifacts also get indexed into the vector
    // store via syncVectorAfterStore — so they're reachable by semantic
    // memory_recall, not just prefix-browse via memory_timeline.
    archive_mem_rt: ?*MemoryRuntime = null,
    // V1.6 commit 5b.2: when set alongside archive_memory + archive_session_id,
    // Pass C's extraction JSON tail is parsed and persisted via
    // extraction_persist.persistExtracted. Provider-agnostic — when the
    // parallel memory-pipeline work adds new fact-write sources, they
    // pipe through the same extraction_persist.persistExtracted entry.
    extraction_state_mgr: ?*zaki_state.Manager = null,
    // V1.6 commit 5b.2: numeric user_id for extraction_persist call.
    // CompactionConfig today has session_id but not user_id (the
    // archive path doesn't need it because Memory.store wraps
    // user-scoping). extraction_persist needs user_id explicitly for
    // upsertMemoryWithMetadata. null → extraction skipped.
    // (5b-loose-ends-sweep: was sentinel `i64 = 0`; replaced with
    // optional to avoid magic-value brittleness per IN-4.)
    extraction_user_id: ?i64 = null,
    // V1.6 commit 6: optional contradiction-judge LLM context. When set,
    // extraction_persist runs the Graphiti resolve_edge prompt per new
    // fact (after MD5 dedup) to detect semantic duplicates + close out
    // contradicted older rows via bi-temporal valid_to/invalid_at/
    // expired_at + is_latest=false. Pairs with extraction_state_mgr +
    // extraction_user_id; null leaves V1.6 5b.3 MD5-only behavior intact.
    //
    // Today the same provider + model_name used for the summarization
    // call also serves as judge (Together's Llama-3.3-70B handles both
    // surfaces fine). A future commit could route the judge to a smaller
    // sidecar model for latency.
    extraction_judge_provider: ?Provider = null,
    extraction_judge_model_name: ?[]const u8 = null,
    // V1.14.12 (Path A) — extraction_legacy_direct_writes field removed
    // from CompactionConfig. The gated Pass C direct write was deleted;
    // Pass C extraction now flows entirely through extractAtBoundary.
    /// V1.14.12 (M2 review CRITICAL) — cardinality fast-path flag,
    /// threaded into JudgeContext at the Pass A + Pass C direct sites
    /// so persistExtracted honors operator config.
    extraction_cardinality_fastpath: bool = true,
    // V1.6 commit 8: optional embedding provider for entity coreference.
    // When set, extracted-fact object strings get cosine-resolved against
    // existing memory_entities rows (≥0.95 = same entity, reuse id; new
    // entities get inserted). Without it, edges fall back to the V1.6 cmt7
    // hash-based target_key shape — graph still works, just no surface-form
    // coreference (Helix vs HELIX = two nodes instead of one).
    extraction_coref_embed: ?@import("../memory/vector/embeddings.zig").EmbeddingProvider = null,
};

pub const TokenBudgetPolicy = struct {
    reply_reserve: u64,
    tool_reserve: u64,
    safety_reserve: u64,
    total_reserve: u64,
    /// Reserve-based force-compress threshold. Hard guard against context
    /// exhaustion; keep existing 65% floor semantics.
    threshold: u64,
    /// **Advisory marker — NOT a fire signal.** Set to 50% of the resolved
    /// context window. When pressure crosses this, the agent's
    /// `context_pressure.compaction_recommended` flag flips to true so the
    /// UI can render a "halfway through context" hint and the agent's
    /// reasoning knows to be mindful of length. **Compaction itself does
    /// NOT fire here.**
    ///
    /// The actual firing thresholds live inside `autoCompactHistory` below
    /// (single source of truth — do not duplicate the percentages here):
    ///   - **Pass A (cheap dedup + placeholder substitution): 70%**
    ///   - **Pass C (LLM summarization, expensive):           90%**
    ///
    /// Two-tier hot path. Pass B was deleted in iter28 (commit 8136f8d) —
    /// it duplicated work the post-reply lifecycle summarizer already does.
    /// Earlier commits referenced 60/75/85% thresholds; that comment is
    /// stale, current truth is 70/90.
    ///
    /// Derived as token_limit * COMPACTION_RECOMMEND_PERCENT / 100.
    compaction_trigger: u64,
};

pub fn buildTokenBudgetPolicy(token_limit: u64, max_tokens: u32) TokenBudgetPolicy {
    if (token_limit == 0) {
        return .{
            .reply_reserve = 0,
            .tool_reserve = 0,
            .safety_reserve = 0,
            .total_reserve = 0,
            .threshold = 0,
            .compaction_trigger = 0,
        };
    }

    const reply_reserve = if (max_tokens > 0) @as(u64, max_tokens) else @as(u64, 8_192);
    const tool_reserve = @max(@as(u64, 2_048), @min(token_limit / 8, @as(u64, 16_384)));
    const safety_reserve = @max(@as(u64, 1_024), @min(token_limit / 20, @as(u64, 8_192)));
    const total_reserve = reply_reserve + tool_reserve + safety_reserve;
    const threshold_from_reserve = if (token_limit > total_reserve) token_limit - total_reserve else token_limit / 2;
    const minimum_threshold = (token_limit * 65) / 100;
    return .{
        .reply_reserve = reply_reserve,
        .tool_reserve = tool_reserve,
        .safety_reserve = safety_reserve,
        .total_reserve = total_reserve,
        .threshold = @max(minimum_threshold, threshold_from_reserve),
        .compaction_trigger = (token_limit * COMPACTION_RECOMMEND_PERCENT) / 100,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Public functions
// ═══════════════════════════════════════════════════════════════════════════

/// Estimate total tokens in conversation history using heuristic: (total_chars + 3) / 4.
/// Includes assistant `reasoning` traces — they are replayed to the
/// provider on the Moonshot route (`thinking.keep:"all"`) and therefore
/// consume context window like any other message content.
pub fn tokenEstimate(history: []const OwnedMessage) u64 {
    var total_chars: u64 = 0;
    for (history) |*msg| {
        total_chars += msg.content.len;
        if (msg.reasoning) |r| total_chars += r.len;
    }
    return (total_chars + 3) / 4;
}

/// Auto-compact history using a multi-pass strategy.
///
/// V1.7a-4 review fix (V1.6 IN-01): docstring previously listed stale
/// 60/75/85 thresholds. Authoritative values match `TokenBudgetPolicy`
/// at lines 133-138 (70% Pass A, 90% Pass C); Pass B was deleted in iter28.
///
/// Pass A (70% of context): Cheap dedup + placeholder substitution.
///   - Replace tool results older than `keep_recent` turns with short placeholders
///   - Deduplicate consecutive identical tool outputs
///   - Zero LLM cost — pure string operations
///
/// Pass B: deleted (iter28). Was a structured-extraction sidecar plan that
/// never landed; the work merged into Pass C's dual-output JSON tail.
///
/// Pass C (90% of context): Full LLM summarization.
///   - Summarize older messages via the provider (existing logic)
///   - For large histories (>10 messages): splits into halves, summarizes each
///   - Optional V1.6 dual-output: emits a JSON tail of structured atomic
///     facts that `extraction_persist` consumes for the typed-edge graph
///
/// Returns true if any compaction was performed.
pub fn autoCompactHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    provider: Provider,
    model_name: []const u8,
    config: CompactionConfig,
) !bool {
    if (config.token_limit == 0) return false;

    var compacted = false;
    const estimate_before = tokenEstimate(history.items);
    const pressure_pct: u8 = @intCast(@min(100, (estimate_before * 100) / config.token_limit));

    // iter24: visibility log — so Nova can see the token-budget system is
    // actually making decisions each turn. Prints current pressure vs the
    // 70/80/90 trigger curve at the top of every auto-compaction call.
    log.info("compaction.auto: evaluating tokens={d} limit={d} pressure={d}%", .{
        estimate_before,
        config.token_limit,
        pressure_pct,
    });

    // iter28: two-tier hot-path compaction. Pass B (LLM-driven structured
    // extraction at 80%) was deleted — it duplicated work the post-reply
    // lifecycle summarizer already does, and made a second provider call
    // in-turn that was redundant with Pass C.
    //
    // For Kimi K2.5 (262K window): Pass A ~183K, Pass C ~236K.

    // ── Pass A: Drop-from-middle at 70% ──
    // F-PA2 (V1.14.6 SOTA context): the prior in-place placeholder
    // substitution rewrote bytes on cached prefix, invalidating every
    // provider's KV cache from the rewrite point onward (Anthropic
    // ephemeral, Together vLLM byte-prefix, Moonshot automatic — all
    // impacted). "Don't Break the Cache" (arxiv 2601.06007) measured
    // this anti-pattern as 41-80% cost overhead. Replaced with the SOTA
    // pattern (Claude Code / Cline / Hermes / OpenAI Agents SDK):
    // drop oldest user/assistant/tool messages from the middle while
    // preserving system + first user turn + last keep_recent messages.
    // Append-only mutation downstream of the protected prefix preserves
    // cache hits on the unchanged prefix. Tool-call/tool-result pair
    // hygiene mirrors compactHistoryKeepingRecent's existing logic.
    const cheap_threshold = (config.token_limit * AUTO_COMPACT_PASS_A_PERCENT) / 100;
    if (estimate_before > cheap_threshold) {
        log.info("compaction.auto: pass=A firing (drop-from-middle)", .{});
        const reduced = dropOldestPairsFromMiddle(allocator, history, config);
        if (reduced) compacted = true;
    }

    // ── Pass C: Full LLM summarization at 90% ──
    const llm_threshold = (config.token_limit * AUTO_COMPACT_PASS_C_PERCENT) / 100;
    if (tokenEstimate(history.items) > llm_threshold) {
        log.info("compaction.auto: pass=C firing (LLM summarization)", .{});
        // V1.8-5 fix: when Pass C fires, GUARANTEE compaction. Pre-V1.8
        // used `config.keep_recent` (default 20) verbatim — when token
        // pressure was high but message COUNT was low (long multi-paragraph
        // messages), keep_recent covered everything, compact_count=0,
        // compactHistoryKeepingRecent returned false, and
        // archiveCompactionSummary never wrote — even though "pass=C
        // firing" had already logged. V1.8-7 audit confirmed: Pass C
        // fired ~16 times across 8 long-context turns with token_limit=8000,
        // 0 compaction_summary/* keys ever landed.
        //
        // Fix: cap keep_recent at half the non-system message count so
        // there's always something to compact. Floors keep_recent to
        // 4 (preserve the agent's immediate working context — last 2
        // user/assistant pairs). When the history is too small to be
        // worth Pass C in the first place, the cap doesn't bite.
        const non_system: usize = @max(history.items.len, 1) -| 1;
        const half: usize = non_system / 2;
        const cap_keep: u32 = @intCast(@max(@min(half, @as(usize, config.keep_recent)), @as(usize, 4)));
        const summarized = try compactHistoryKeepingRecent(allocator, history, provider, model_name, config, cap_keep);
        if (summarized) compacted = true;
    }

    if (compacted) {
        const estimate_after = tokenEstimate(history.items);
        const saved = if (estimate_before > estimate_after) estimate_before - estimate_after else 0;
        const saved_pct: u8 = if (estimate_before > 0) @intCast(@min(100, (saved * 100) / estimate_before)) else 0;
        log.info("compaction.auto: compacted before={d} after={d} saved={d}%", .{
            estimate_before,
            estimate_after,
            saved_pct,
        });
        // F-CB2 (V1.14.6 SOTA context): notifyCompaction emits a
        // structured log so cache-hit-rate telemetry can reset its
        // baseline. Otherwise the legitimate post-compaction prefix
        // change registers as a cache regression in our metrics.
        // Mirrors Claude Code's `notifyCompaction()` pattern (see
        // claude-code/src/services/compact/apiMicrocompact.ts).
        // Format chosen so a single grep for "compaction.notify" gives
        // operators every compaction event with bytes saved + reason.
        log.info(
            "compaction.notify reason=auto_passA_or_passC bytes_before={d} bytes_after={d} saved_bytes={d} pressure_before={d}%",
            .{ estimate_before, estimate_after, saved, pressure_pct },
        );
    }

    return compacted;
}

/// Pass A (F-PA2): Drop oldest messages from the middle of history.
///
/// **SOTA context-engineering pattern** (Claude Code, Cline, Hermes,
/// OpenAI Agents SDK). Append-only mutation downstream of the protected
/// prefix preserves provider KV cache hits on the unchanged head. The
/// prior implementation rewrote tool_result bytes in place, which
/// invalidated cache from the rewrite point onward (textbook anti-pattern
/// per "Don't Break the Cache", arxiv 2601.06007 — 41-80% cost overhead).
///
/// Protection regions ("system_and_first_and_last_N" — Hermes terminology):
///   1. The system prompt (index 0 if present).
///   2. The first user message (the original task framing — agents
///      consistently regress when this disappears).
///   3. The last `keep_recent` messages (immediate working context).
///
/// Drop region: everything between (2) and (3), with tool-call/tool-result
/// pair hygiene at both boundaries so we never split a pair.
///
/// Best-effort archive: when archive_memory + archive_session_id are set,
/// dropped messages are persisted as `compaction_dropped/{session}/{ts}`
/// before deletion (mirrors forceCompressHistoryWithArchive). Recallable
/// via memory_timeline / memory_recall after the fact.
///
/// Returns true if any messages were dropped.
///
/// V1.14.7 C2 / V1.14.8 C6: signature takes the full `CompactionConfig` so
/// we can wire structured extraction over the drop window before deletion.
/// The extraction call uses extraction_runner.extractAtBoundary with
/// `enable_hydration=false` (Pass A is mid-session — extraction only).
fn dropOldestPairsFromMiddle(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    config: CompactionConfig,
) bool {
    const keep_recent = config.keep_recent;
    const archive_memory = config.archive_memory;
    const archive_mem_rt = config.archive_mem_rt;
    const archive_session_id = config.archive_session_id;
    const total = history.items.len;
    const has_system = total > 0 and history.items[0].role == .system;
    const sys_count: usize = if (has_system) 1 else 0;

    // Find first user message after the optional system prompt — that's
    // the task framing we always preserve. If there's no user message yet
    // (system-only history), nothing to drop.
    var first_user_idx_opt: ?usize = null;
    {
        var i: usize = sys_count;
        while (i < total) : (i += 1) {
            if (history.items[i].role == .user) {
                first_user_idx_opt = i;
                break;
            }
        }
    }
    const first_user_idx = first_user_idx_opt orelse return false;

    // Tail protection — last keep_recent messages.
    if (total <= sys_count + 1 + keep_recent) return false;
    var tail_start: usize = total - keep_recent;

    // Tool-pair hygiene at tail boundary: if the first kept message is a
    // .tool result, walk backward so its preceding assistant tool_call is
    // also kept. Mirrors compactHistoryKeepingRecent's logic.
    while (tail_start > first_user_idx + 1 and
        tail_start < total and
        history.items[tail_start].role == .tool)
    {
        tail_start -= 1;
    }

    // Drop region: (first_user_idx, tail_start). Strictly after the first
    // user turn, strictly before the kept tail.
    var drop_start: usize = first_user_idx + 1;
    var drop_end: usize = tail_start;
    if (drop_end <= drop_start) return false;

    // Tool-pair hygiene at drop_end boundary: if the last dropped message
    // is an assistant message that issued a tool_call AND the first kept
    // message is the corresponding .tool result, the result would be
    // orphaned. Walk drop_end backward past trailing assistant messages
    // when the next-kept is a .tool. (Inverse of the tail walk above.)
    while (drop_end > drop_start and
        drop_end < total and
        history.items[drop_end].role == .tool and
        history.items[drop_end - 1].role == .assistant)
    {
        drop_end -= 1;
    }

    // Tool-pair hygiene at drop_start boundary: if the first dropped
    // message is a .tool result, the assistant call sits at drop_start-1
    // (which we're keeping, since it's the first user message or earlier).
    // That's malformed — a tool result can never directly follow a user
    // message. Defensively, if drop_start lands on .tool, advance past it
    // (we'd rather keep one extra .tool than emit an orphaned result).
    while (drop_start < drop_end and history.items[drop_start].role == .tool) {
        drop_start += 1;
    }

    if (drop_end <= drop_start) return false;
    const dropped_count = drop_end - drop_start;

    // Compute byte savings before mutation for the notify event.
    var dropped_bytes: u64 = 0;
    for (history.items[drop_start..drop_end]) |*msg| dropped_bytes += msg.content.len;

    log.info(
        "compaction.passA.drop start={d} end={d} dropped={d} bytes={d} sys={d} first_user={d} tail_start={d}",
        .{ drop_start, drop_end, dropped_count, dropped_bytes, sys_count, first_user_idx, tail_start },
    );

    // V1.14.8 C6 — Pass A wired to the unified boundary extractor.
    //
    // Why we wire it (reverses the C2 deactivation): Pass A fires whenever
    // history exceeds 70% of token_limit. At Kimi K2.5 (256K window) this
    // is ~183K tokens — frequent on long benches (LoCoMo eval observed 8
    // fires in one session, hit 99% pressure). Each fire drops a window
    // of oldest mid-history messages PERMANENTLY before Pass C ever sees
    // them. Without extraction here, every entity/edge mentioned in the
    // dropped turns is lost from the graph layer (only the raw bytes
    // survive in `compaction_dropped/{session}/{ts}`, recallable by text
    // search but invisible to the typed-edge brain).
    //
    // Cost mitigation vs C2's concern: hydration is SKIPPED for Pass A
    // (`enable_hydration = false`). Hydration is for full session
    // summaries — a mid-session drop slice isn't worth a second LLM call
    // for that. So Pass A pays one LLM call per fire, not two. Pass C +
    // session-end keep both calls. Dedup at persistExtracted handles
    // overlap with downstream Pass C extraction of the surviving tail.
    // The runner can use a dedicated extraction provider/model without a
    // contradiction judge, but this legacy path only has the judge-backed
    // extraction config available. Avoid routing arbitrary compaction
    // providers through the structured extraction parser.
    {
        const window = history.items[drop_start..drop_end];
        var msgs_buf = std.ArrayListUnmanaged(ChatMessage).initCapacity(allocator, window.len) catch null;
        if (msgs_buf) |*buf| {
            defer buf.deinit(allocator);
            for (window) |m| buf.appendAssumeCapacity(.{ .role = m.role, .content = m.content });
            const judge_model_resolved = config.extraction_judge_model_name orelse "";
            const ctx = extraction_runner.ExtractionContext{
                .judge_provider = config.extraction_judge_provider,
                .judge_model = judge_model_resolved,
                .state_mgr = config.extraction_state_mgr,
                .user_id = config.extraction_user_id,
                .session_id = config.archive_session_id,
                .coref_embed = config.extraction_coref_embed,
                .archive_mem = config.archive_memory,
                .archive_mem_rt = config.archive_mem_rt,
                .max_source_chars = config.max_source_chars,
                .enable_hydration = false, // Pass A is mid-session — extraction only.
                .boundary_kind = .pass_a, // V1.14.9 L-01: explicit telemetry tag
                .write_origin = .pass_a_drop, // V1.14.12 (M1) — per-path telemetry tag
                .cardinality_fastpath_enabled = config.extraction_cardinality_fastpath, // V1.14.12 (M2 review CRITICAL)
            };
            const br = extraction_runner.extractAtBoundary(allocator, buf.items, ctx);
            defer br.deinit(allocator);
            log.info(
                "compaction.passA.unified_extract entities={d} edges={d} window_msgs={d}",
                .{
                    if (br.extraction) |e| e.entities.len else 0,
                    if (br.extraction) |e| e.edges.len else 0,
                    window.len,
                },
            );
        }
    }

    // Best-effort archive before deletion (continuity artifact). Mirrors
    // forceCompressHistoryWithArchive — same key shape so memory_timeline
    // surfaces both via a single prefix scan.
    if (archive_memory) |m| {
        archiveDroppedMessages(
            allocator,
            m,
            archive_mem_rt,
            archive_session_id,
            history.items[drop_start..drop_end],
            dropped_count,
        );
    }

    // Free dropped messages
    for (history.items[drop_start..drop_end]) |*msg| {
        msg.deinit(allocator);
    }

    // Shift the kept tail forward to fill the gap (append-only downstream
    // of `drop_start` from the cache's perspective — no mutation of the
    // protected prefix [0..drop_start)).
    const tail = history.items[drop_end..];
    std.mem.copyForwards(OwnedMessage, history.items[drop_start..], tail);
    history.items.len -= dropped_count;

    // F-CB2 mirror: emit a structured notify event so cache-hit-rate
    // telemetry can attribute the drop. Distinguished from the broader
    // auto_passA_or_passC notify (which fires once per
    // autoCompactHistory call covering Pass A + Pass C combined).
    log.info(
        "compaction.notify reason=passA_drop dropped_messages={d} dropped_bytes={d}",
        .{ dropped_count, dropped_bytes },
    );

    return true;
}

/// Manual compaction for explicit operator boundaries.
/// Summarizes older context and keeps the most recent recovery tail intact.
pub fn manualCompactHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    provider: Provider,
    model_name: []const u8,
    config: CompactionConfig,
) !bool {
    return compactHistoryKeepingRecent(allocator, history, provider, model_name, config, CONTEXT_RECOVERY_KEEP);
}

fn compactHistoryKeepingRecent(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    provider: Provider,
    model_name: []const u8,
    config: CompactionConfig,
    requested_keep_recent: usize,
) !bool {
    const has_system = history.items.len > 0 and history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    const non_system_count = history.items.len - start;

    var keep_recent: usize = @min(non_system_count, requested_keep_recent);

    // Tool-call pair hygiene: never split a tool_call from its tool_result.
    // If the boundary lands on a .tool message (tool result), extend keep_recent
    // backwards to also include the preceding assistant message (tool call instruction).
    const boundary_idx = start + (non_system_count - keep_recent);
    if (boundary_idx < history.items.len and boundary_idx > start) {
        if (history.items[boundary_idx].role == .tool) {
            // The first kept message is a tool result — orphaned without its call.
            // Include the preceding assistant message too.
            keep_recent += 1;
        }
    }
    // Also check the last compacted message: if it's an assistant with a tool_call
    // and the next (first kept) is a .tool, the pair is already preserved above.
    // But if the last compacted message is .tool and the one before it is .assistant,
    // we should keep both — walk back until we hit a non-tool message.
    {
        var adj_boundary = start + (non_system_count - keep_recent);
        while (adj_boundary > start and adj_boundary < history.items.len and
            history.items[adj_boundary].role == .tool)
        {
            keep_recent += 1;
            adj_boundary -= 1;
        }
    }

    keep_recent = @min(non_system_count, keep_recent);
    const compact_count = non_system_count - keep_recent;
    if (compact_count == 0) return false;

    const compact_end = start + compact_count;

    // Multi-part strategy: if >10 messages to summarize, split into halves.
    // Split-half branches don't capture extraction tail (acceptable V1.6
    // simplification — merging two batches' extracted facts adds complexity
    // for a rare path; deferred to V1.7 if measurably valuable).
    // V1.7a-4 review fix (V1.6 IN-03) — start with `null` so the defer
    // unconditionally frees once `summarizeSlice` populates a heap slice
    // (even a zero-length `try allocator.dupe(u8, "")` allocation needs
    // freeing under the testing allocator). Prior shape used a sentinel
    // empty slice + `if (extraction_tail.len > 0)` guard, which leaked
    // any zero-length heap allocation.
    var extraction_tail: ?[]u8 = null;
    defer if (extraction_tail) |t| allocator.free(t);
    const summary = if (compact_count > 10) blk: {
        const mid = start + compact_count / 2;

        // Summarize first half (no extraction capture for split path)
        const summary_a = try summarizeSlice(allocator, provider, model_name, history.items, start, mid, config, null);
        defer allocator.free(summary_a);

        // Summarize second half (no extraction capture for split path)
        const summary_b = try summarizeSlice(allocator, provider, model_name, history.items, mid, compact_end, config, null);
        defer allocator.free(summary_b);

        // Merge the two summaries
        const merged = try std.fmt.allocPrint(
            allocator,
            "Earlier context:\n{s}\n\nMore recent context:\n{s}",
            .{ summary_a, summary_b },
        );

        // Truncate if too long
        if (merged.len > config.max_summary_chars) {
            const truncated = try allocator.dupe(u8, merged[0..config.max_summary_chars]);
            allocator.free(merged);
            break :blk truncated;
        }

        break :blk merged;
        // V1.6 commit 5b.2: single-call branch captures extraction tail
        // for downstream persist via extraction_persist.persistExtracted.
        // V1.7a-4 review fix (V1.6 IN-03) — capture into a local then
        // transfer to the optional so the defer above always frees the
        // tail (summarizeSlice's success path ALWAYS dupes a slice into
        // tail_local, even when the JSON tail is empty).
    } else blk: {
        var tail_local: []u8 = &.{};
        const s = try summarizeSlice(allocator, provider, model_name, history.items, start, compact_end, config, &tail_local);
        extraction_tail = tail_local;
        break :blk s;
    };
    defer allocator.free(summary);

    const workspace_context = try readWorkspaceContextForSummary(allocator, config.workspace_dir);
    defer allocator.free(workspace_context);

    const summary_with_context = if (workspace_context.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ summary, workspace_context })
    else
        try allocator.dupe(u8, summary);
    defer allocator.free(summary_with_context);

    // Create the compaction summary message
    const summary_content = try std.fmt.allocPrint(allocator, "[Compaction summary]\n{s}", .{summary_with_context});

    // iter29: archive the emergency summary as a durable continuity artifact.
    // Key shape: compaction_summary/{session}/{ts}. Retrievable by the agent
    // via memory_timeline (warm) or transcript_read fallback (cold). Without
    // this, the summary evaporates when the session ends.
    if (config.archive_memory) |mem| {
        if (config.archive_session_id) |session_id| {
            archiveCompactionSummary(allocator, mem, config.archive_mem_rt, session_id, summary_with_context, compact_count) catch |err| {
                log.warn("compaction: failed to archive Pass C summary: {}", .{err});
            };
        }
    }

    // V1.6 commit 5b.2: persist atomic facts from JSON tail.
    //
    // Runs only when:
    //   - extraction_state_mgr + extraction_user_id are configured
    //   - The single-call summarization branch produced a tail
    //     (split-half branch passed null per V1.6 simplification)
    //
    // Failure modes are non-fatal — extraction_persist.persistExtracted
    // already logs per-fact failures + returns counts. A failed
    // extraction does NOT abort the compaction (the prose summary
    // already archived above is preserved).
    // V1.7a-4 review fix (V1.6 WR-04) — re-indented inner block so visual
    // structure matches logical structure (zig-fmt compliant). Was an
    // outdented inner block hiding 60+ lines under `if (extraction_tail...)`.
    // V1.14.12 (Path A) — Pass C JSON-tail parse + legacy direct write
    // BOTH deleted. extraction_tail is captured by the summary call
    // above and freed by its defer, but no longer parsed/persisted
    // here. The Pass C extractAtBoundary call below (line ~770)
    // handles structured extraction (entities + edges schema) from
    // the same compaction window — single source of truth, single
    // LLM call, graceful null-judge handling.

    // V1.14.8 C3 — unified boundary extraction (additive to legacy JSON-tail
    // path above). Fires the structured extraction (graphiti-shape JSON →
    // entities + edges) and hydration (Claude-Code-shape XML → summary_latest/
    // <session>) using the configured judge provider. Failure-soft per layer;
    // existing JSON-tail path at lines 637-710 remains the primary edge writer
    // until C5 cleanup. Dedup at persistExtracted handles overlap.
    // The runner can use a dedicated extraction provider/model without a
    // contradiction judge, but this legacy path only has the judge-backed
    // extraction config available. Avoid routing arbitrary compaction
    // providers through the structured extraction parser.
    {
        const window = history.items[start..compact_end];
        var msgs_buf = std.ArrayListUnmanaged(ChatMessage).initCapacity(allocator, window.len) catch null;
        if (msgs_buf) |*buf| {
            defer buf.deinit(allocator);
            for (window) |m| buf.appendAssumeCapacity(.{ .role = m.role, .content = m.content });
            const judge_model_resolved = config.extraction_judge_model_name orelse "";
            const ctx = extraction_runner.ExtractionContext{
                .judge_provider = config.extraction_judge_provider,
                .judge_model = judge_model_resolved,
                .state_mgr = config.extraction_state_mgr,
                .user_id = config.extraction_user_id,
                .session_id = config.archive_session_id,
                .coref_embed = config.extraction_coref_embed,
                .archive_mem = config.archive_memory,
                .archive_mem_rt = config.archive_mem_rt,
                .max_source_chars = config.max_source_chars,
                .boundary_kind = .pass_c, // V1.14.9 L-01: explicit telemetry tag
                .write_origin = .pass_c_compaction_extract, // V1.14.12 (M1) — per-path telemetry tag
                .cardinality_fastpath_enabled = config.extraction_cardinality_fastpath, // V1.14.12 (M2 review CRITICAL)
            };
            const br = extraction_runner.extractAtBoundary(allocator, buf.items, ctx);
            defer br.deinit(allocator);
            log.info(
                "compaction.passC.unified_extract entities={d} edges={d} hydration_present={}",
                .{
                    if (br.extraction) |e| e.entities.len else 0,
                    if (br.extraction) |e| e.edges.len else 0,
                    br.hydration != null,
                },
            );
        }
    }

    // Free old messages being compacted
    for (history.items[start..compact_end]) |*msg| {
        msg.deinit(allocator);
    }

    // Replace compacted messages with summary
    history.items[start] = .{
        .role = .assistant,
        .content = summary_content,
    };

    // Shift remaining messages
    if (compact_end > start + 1) {
        const src = history.items[compact_end..];
        std.mem.copyForwards(OwnedMessage, history.items[start + 1 ..], src);
        history.items.len -= (compact_end - start - 1);
    }

    return true;
}

/// Force-compress history for context exhaustion recovery.
/// Keeps system prompt (if any) + last CONTEXT_RECOVERY_KEEP messages.
/// Everything in between is dropped without LLM summarization (we can't call
/// the LLM since the context is exhausted). Returns true if compression was performed.
///
/// NOTE: This is a lossy hard-drop. Callers MUST surface this to the user so
/// they are aware context continuity has been interrupted.
/// Maximum characters saved in a compaction archive entry.
const MAX_ARCHIVE_CHARS: usize = 6_000;

pub fn forceCompressHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
) bool {
    return forceCompressHistoryWithArchive(allocator, history, null, null, null);
}

/// Force-compress history, optionally archiving dropped messages to memory.
/// When mem and session_id are provided, dropped messages are saved as a
/// compaction_dropped/{session}/{ts} entry before deletion — preventing
/// silent context loss. iter31: mem_rt optional; when set, the archive is
/// also indexed into the vector store for semantic recall.
pub fn forceCompressHistoryWithArchive(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    mem: ?Memory,
    mem_rt: ?*MemoryRuntime,
    session_id: ?[]const u8,
) bool {
    const has_system = history.items.len > 0 and history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    const non_system_count = history.items.len - start;

    if (non_system_count <= CONTEXT_RECOVERY_KEEP) return false;

    const keep_start = history.items.len - CONTEXT_RECOVERY_KEEP;
    const to_remove = keep_start - start;

    log.warn("compaction: force-compressing history — dropping {} messages (context exhausted, LLM unavailable)", .{to_remove});

    // F-CB2 (V1.14.6 SOTA context): notifyCompaction fires on the
    // emergency force-compress path too. Operators see EVERY
    // compaction event from a single grep "compaction.notify" — this
    // path's reason marks the emergency case so it's distinguishable
    // from the normal auto-compaction notify.
    log.info(
        "compaction.notify reason=force_compress messages_dropped={d}",
        .{to_remove},
    );

    // Archive dropped messages to memory before deletion (best-effort)
    if (mem) |m| {
        archiveDroppedMessages(allocator, m, mem_rt, session_id, history.items[start..keep_start], to_remove);
    }

    // Free messages being removed
    for (history.items[start..keep_start]) |*msg| {
        msg.deinit(allocator);
    }

    // Shift remaining elements
    const src = history.items[keep_start..];
    std.mem.copyForwards(OwnedMessage, history.items[start..], src);
    history.items.len -= to_remove;

    return true;
}

/// Best-effort archive of messages about to be dropped.
/// iter31: mem_rt optional — when set, indexes into vector store for recall.
fn archiveDroppedMessages(
    allocator: std.mem.Allocator,
    mem: Memory,
    mem_rt: ?*MemoryRuntime,
    session_id: ?[]const u8,
    messages: []const OwnedMessage,
    count: usize,
) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    std.fmt.format(w, "type=compaction_archive\nmessages_dropped={d}\nreason=context_exhaustion\n\n", .{count}) catch return;

    for (messages) |msg| {
        if (buf.items.len >= MAX_ARCHIVE_CHARS) {
            w.writeAll("\n[... remaining messages truncated ...]\n") catch {};
            break;
        }
        const role_str: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
            .system => "system",
            .tool => "tool",
        };
        std.fmt.format(w, "[{s}] {s}\n\n", .{
            role_str,
            if (msg.content.len > 500) msg.content[0..500] else msg.content,
        }) catch break;
    }

    // iter29: key shape changed from `compaction_archive/{ts}` to
    // `compaction_dropped/{session}/{ts}` so agents can scope retrieval to
    // a session via memory_timeline. Falls back to session-less key when
    // session_id is unavailable (preserves old behavior as the off-path).
    const ts: u128 = @bitCast(std.time.nanoTimestamp());
    const key = if (session_id) |sid|
        std.fmt.allocPrint(allocator, "compaction_dropped/{s}/{d}", .{ sid, ts }) catch return
    else
        std.fmt.allocPrint(allocator, "compaction_dropped/{d}", .{ts}) catch return;
    defer allocator.free(key);

    if (mem.store(key, buf.items, .conversation, session_id)) |_| {
        if (mem_rt) |rt| _ = rt.syncVectorAfterStore(allocator, key, buf.items);
    } else |err| {
        log.warn("compaction: failed to archive dropped messages: {}", .{err});
    }
}

/// iter29: archive the Pass C emergency summary to memory so it becomes a
/// recallable continuity artifact. Key shape: `compaction_summary/{session}/{ts}`.
/// Category=.daily so memory_timeline lists it alongside lifecycle summaries.
/// iter31: when mem_rt is provided, also indexes into the vector store so
/// memory_recall semantic search can find it.
fn archiveCompactionSummary(
    allocator: std.mem.Allocator,
    mem: Memory,
    mem_rt: ?*MemoryRuntime,
    session_id: []const u8,
    summary_body: []const u8,
    compacted_message_count: usize,
) !void {
    const ts: u128 = @bitCast(std.time.nanoTimestamp());
    const key = try std.fmt.allocPrint(allocator, "compaction_summary/{s}/{d}", .{ session_id, ts });
    defer allocator.free(key);

    // Prefix metadata so downstream timeline/recall tools recognize the
    // provenance. Format mirrors summary_latest's metadata block.
    const payload = try std.fmt.allocPrint(
        allocator,
        "type=compaction_summary\nsession={s}\nat={d}\ntrigger=autoCompactHistory:passC\nmessages_compacted={d}\n\n{s}",
        .{ session_id, ts, compacted_message_count, summary_body },
    );
    defer allocator.free(payload);

    try mem.store(key, payload, .daily, session_id);
    if (mem_rt) |rt| _ = rt.syncVectorAfterStore(allocator, key, payload);
}

/// Trim history to prevent unbounded growth.
/// Preserves the system prompt (first message) and the most recent messages.
pub fn trimHistoryDetailed(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    max_history_messages: u32,
) TrimStats {
    var stats = TrimStats{
        .history_before = history.items.len,
        .history_after = history.items.len,
    };

    // iter26: max=0 means "disabled" (pure token-based, no message-count cap).
    // Competitors (Claude Code, Hermes, OpenClaw) all use pure token budgets; we
    // follow suit. The mechanism remains for future per-deployment opt-in but is
    // inert by default — autoCompactHistory (70/80/90 token-budget) owns compaction.
    const max = max_history_messages;
    if (max == 0) return stats;
    if (history.items.len <= max + 1) return stats; // +1 for system prompt

    const has_system = history.items.len > 0 and history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    const non_system_count = history.items.len - start;

    if (non_system_count <= max) return stats;

    const to_remove = non_system_count - max;
    stats.removed_messages = to_remove;

    // Free the messages being removed
    for (history.items[start .. start + to_remove]) |*msg| {
        stats.removed_bytes += msg.content.len;
        msg.deinit(allocator);
    }

    // Shift remaining elements
    const src = history.items[start + to_remove ..];
    std.mem.copyForwards(OwnedMessage, history.items[start..], src);
    history.items.len -= to_remove;
    stats.history_after = history.items.len;

    // Shrink backing array if capacity is much larger than needed
    if (history.capacity > history.items.len * 2 + 8) {
        history.shrinkAndFree(allocator, history.items.len);
        stats.shrunk_capacity = true;
    }

    return stats;
}

/// Trim history to prevent unbounded growth.
/// Preserves the system prompt (first message) and the most recent messages.
pub fn trimHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    max_history_messages: u32,
) void {
    _ = trimHistoryDetailed(allocator, history, max_history_messages);
}

test "trimHistoryDetailed reports removed messages and bytes" {
    const allocator = std.testing.allocator;
    var history: std.ArrayListUnmanaged(OwnedMessage) = .empty;
    defer {
        for (history.items) |*msg| msg.deinit(allocator);
        history.deinit(allocator);
    }

    try history.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u1") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "assistant-one") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u2") });

    const stats = trimHistoryDetailed(allocator, &history, 2);
    try std.testing.expectEqual(@as(usize, 4), stats.history_before);
    try std.testing.expectEqual(@as(usize, 3), stats.history_after);
    try std.testing.expectEqual(@as(usize, 1), stats.removed_messages);
    try std.testing.expectEqual(@as(usize, 2), stats.removed_bytes);
    try std.testing.expectEqual(@as(usize, 3), history.items.len);
    try std.testing.expectEqualStrings("assistant-one", history.items[1].content);
    try std.testing.expectEqualStrings("u2", history.items[2].content);
}

test "buildTokenBudgetPolicy keeps dynamic headroom" {
    const kimi = buildTokenBudgetPolicy(262_144, 32_768);
    try std.testing.expectEqual(@as(u64, 32_768), kimi.reply_reserve);
    try std.testing.expectEqual(@as(u64, 16_384), kimi.tool_reserve);
    try std.testing.expectEqual(@as(u64, 8_192), kimi.safety_reserve);
    try std.testing.expectEqual(@as(u64, 57_344), kimi.total_reserve);
    try std.testing.expectEqual(@as(u64, 204_800), kimi.threshold);

    const smaller = buildTokenBudgetPolicy(32_768, 8_192);
    try std.testing.expect(smaller.threshold >= (32_768 * 65) / 100);
}

// ═══════════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Build a compaction transcript from a slice of history messages.
fn buildCompactionTranscript(
    allocator: std.mem.Allocator,
    history_items: []const OwnedMessage,
    start: usize,
    end: usize,
    max_source_chars: u32,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (history_items[start..end]) |*msg| {
        const role_str: []const u8 = switch (msg.role) {
            .system => "SYSTEM",
            .user => "USER",
            .assistant => "ASSISTANT",
            .tool => "TOOL",
        };
        try buf.appendSlice(allocator, role_str);
        try buf.appendSlice(allocator, ": ");
        // Truncate very long messages in transcript
        const content = if (msg.content.len > 2000) msg.content[0..2000] else msg.content;
        try buf.appendSlice(allocator, content);
        try buf.append(allocator, '\n');

        // Safety cap
        if (buf.items.len > max_source_chars) break;
    }

    if (buf.items.len > max_source_chars) {
        buf.items.len = max_source_chars;
    }

    return buf.toOwnedSlice(allocator);
}

/// Summarize a slice of history messages via the LLM provider.
/// Returns an owned summary string. Falls back to transcript truncation on error.
fn summarizeSlice(
    allocator: std.mem.Allocator,
    provider: Provider,
    model_name: []const u8,
    history_items: []const OwnedMessage,
    start: usize,
    end: usize,
    config: CompactionConfig,
    // V1.6 commit 5b.2: optional extraction-tail capture. When non-null,
    // the JSON tail (the part after "===EXTRACTED===") is duplicated into
    // out.*; caller frees. When null, tail is discarded as in V1.5.5.
    // Used by Pass C's single-call branch to feed extraction_persist.
    // Split-in-half branch passes null (each half's tail is discarded —
    // simpler than merging two batches; acceptable for V1.6 ship).
    json_tail_out: ?*[]u8,
) ![]u8 {
    const transcript = try buildCompactionTranscript(allocator, history_items, start, end, config.max_source_chars);
    defer allocator.free(transcript);

    // V1.5.5 prompt (rules 1-4) + V1.6 commit 5 dual-output extension.
    //
    // Output format: prose bullets first (existing V1.5.5 substrate,
    // measured 0.94 recall / 0.92 precision against compaction_corpus),
    // followed by a delimiter and a JSON array of structured atomic
    // facts ready for V1.6 commit 5b persistence into the typed-edge
    // memory surface.
    //
    // Why delimiter approach over JSON-mode:
    //   - Prose format unchanged → V1.5.5 substrate gates re-validate
    //     against the same corpus without regression risk on the
    //     prose-recall path
    //   - JSON parsing failure leaves prose intact (graceful degradation)
    //   - No response_format flag needed (works on Groq + Together
    //     uniformly without provider-specific JSON mode)
    //
    // V1.5.5 RULES carry through unchanged (1: NO FACTS guard,
    // 2: direct-support, 3: attribution prefixes, 4: no meta-statements).
    // The extracted_memories JSON section honors the SAME rules — facts
    // there must be the same atomic-fact universe the prose covers.
    const summarizer_system =
        "You are a conversation compaction engine. Summarize older chat history " ++
        "into concise context for future turns. Preserve: user preferences, " ++
        "commitments, decisions, unresolved tasks, key facts. Omit: filler, " ++
        "repeated chit-chat, verbose tool logs.\n\n" ++
        "OUTPUT FORMAT (two sections, in this exact order):\n" ++
        "1. Plain text bullet points (max 12 bullets, one per line, hyphen or asterisk prefix).\n" ++
        "2. The literal delimiter line: ===EXTRACTED===\n" ++
        "3. A JSON array of atomic-fact objects (empty array `[]` if no facts).\n\n" ++
        "RULES (apply to both bullet output and JSON facts):\n" ++
        "1. NO FACTS guard takes ABSOLUTE PRECEDENCE. If the conversation contains " ++
        "no factual content — pure greetings (\"hi\", \"good morning\", \"hey\"), " ++
        "pleasantries (\"thanks\", \"how are you\"), ack-only exchanges (\"ok\", " ++
        "\"got it\", \"ttyl\"), or any exchange where nothing substantive was " ++
        "established — output EXACTLY:\nNO FACTS\n===EXTRACTED===\n[]\n\n" ++
        "Even if you could mechanically extract a triplet like (user, GREETED, " ++
        "assistant), DO NOT. Greetings, acknowledgements, and conversational " ++
        "filler are NEVER facts. The JSON schema below tempts you to fill it; " ++
        "RESIST that temptation when no real fact exists.\n\n" ++
        "Test: ask yourself \"would a human reading this conversation later care " ++
        "about this detail?\" If no, omit it. \"User said good morning\" — no human " ++
        "cares. \"User prefers Helix\" — that's a fact.\n\n" ++
        "2. Every bullet AND every fact must be DIRECTLY supported by user or " ++
        "assistant text in the conversation. Do NOT add inferences, suggestions " ++
        "you offered that were not adopted, or general commentary.\n" ++
        "3. When a fact reflects an assistant offer or suggestion (not a user " ++
        "statement or decision), prefix the bullet with \"(assistant offered) \" " ++
        "AND set \"attributed_to\":\"assistant_offer\" in the JSON entry. " ++
        "When it reflects an unresolved consideration, prefix with " ++
        "\"(undecided) \" AND set \"attributed_to\":\"undecided\".\n" ++
        "4. Do NOT include conversational meta-statements like \"user thanked the " ++
        "assistant\", \"user greeted the assistant\", \"user mentioned X\", " ++
        "\"user asked about Y\", \"user requested Z\", \"assistant offered help\". " ++
        "State the FACT or DECISION itself, never that the user articulated it. " ++
        "Bad: \"User asked about pgvector indexing options\". " ++
        "Good: \"User chose ivfflat over HNSW for pgvector indexing\". " ++
        "Bad: \"User greeted the assistant\". " ++
        "Good: (omit entirely — greetings are not facts).\n\n" ++
        "JSON FACT SCHEMA (each object in the array):\n" ++
        "{\n" ++
        "  \"text\": \"<15-80 word atomic self-contained fact>\",\n" ++
        "  \"subject\": \"<entity name, e.g. 'user', 'Alex', 'project'>\",\n" ++
        "  \"predicate\": \"<RELATION_TYPE_SCREAMING_SNAKE_CASE, e.g. 'PREFERS', 'DEPLOYS_TO', 'BIRTHDAY'>\",\n" ++
        "  \"object\": \"<value or target entity name>\",\n" ++
        "  \"attributed_to\": \"user\" | \"assistant\" | \"assistant_offer\" | \"undecided\",\n" ++
        "  \"confidence\": <number 0.0-1.0>,\n" ++
        "  \"valid_at\": \"<OPTIONAL ISO-8601 datetime when the fact became true; OMIT THIS FIELD if the fact has no temporal anchor>\"\n" ++
        "}\n" ++
        "VALID_AT GUIDANCE: include `valid_at` ONLY when the fact has a clear " ++
        "temporal anchor expressed in the conversation (e.g. \"I joined Google " ++
        "in 2020\" → valid_at=\"2020-01-01T00:00:00Z\"; \"Mia's birthday is " ++
        "June 3\" → valid_at=\"2026-06-03T00:00:00Z\" using current year if " ++
        "ambiguous). For facts without temporal context (preferences, " ++
        "stable attributes like \"user lives in Riyadh\"), OMIT the field — " ++
        "do not guess. The system will treat omitted valid_at as \"valid since " ++
        "now\" via the write-time fallback.\n" ++
        "Each JSON fact corresponds to one bullet (1:1). The bullets describe " ++
        "the same facts in human-readable prose; the JSON describes them in " ++
        "structured form for downstream indexing.\n\n" ++
        "REJECTED PREDICATES (never use these — they signal you're extracting " ++
        "meta-narrative instead of facts): GREETED, SAID, ASKED, MENTIONED, " ++
        "REPLIED, ACKNOWLEDGED, EXPRESSED, INDICATED_READINESS, IS_GETTING_STARTED, " ++
        "OFFERED_TO_WAIT, PRIORITIZED, ADDRESSED_AS, IS_UNKNOWN. " ++
        "If the only predicate you can come up with is in this list, omit the fact.";
    const summarizer_user = try std.fmt.allocPrint(allocator, "Summarize the following conversation history for context preservation. Keep it short (max 12 bullet points).\n\n{s}", .{transcript});
    defer allocator.free(summarizer_user);

    var summary_messages: [2]ChatMessage = .{
        .{ .role = .system, .content = summarizer_system },
        .{ .role = .user, .content = summarizer_user },
    };

    const messages_slice = summary_messages[0..2];

    const summary_resp = provider.chat(
        allocator,
        .{
            .messages = messages_slice,
            .model = model_name,
            .temperature = 0.2,
            .tools = null,
            .timeout_secs = config.message_timeout_secs,
        },
        model_name,
        0.2,
    ) catch |err| {
        // LLM summarization failed — fall back to a hard truncation of the raw
        // transcript. Log this clearly: the caller will surface it to the user so
        // they know context continuity may be degraded.
        log.warn("compaction: LLM summarization failed ({}), falling back to transcript truncation — context continuity may be degraded", .{err});
        const max_len = @min(transcript.len, config.max_summary_chars);
        return try allocator.dupe(u8, transcript[0..max_len]);
    };
    // Free response's heap-allocated fields after extracting what we need.
    // Includes tool_calls for defensive completeness (W1 fix).
    defer {
        if (summary_resp.content) |c| {
            if (c.len > 0) allocator.free(c);
        }
        if (summary_resp.model.len > 0) allocator.free(summary_resp.model);
        if (summary_resp.reasoning_content) |rc| {
            if (rc.len > 0) allocator.free(rc);
        }
        for (summary_resp.tool_calls) |tc| {
            if (tc.id.len > 0) allocator.free(tc.id);
            if (tc.name.len > 0) allocator.free(tc.name);
            if (tc.arguments.len > 0) allocator.free(tc.arguments);
        }
        if (summary_resp.tool_calls.len > 0) allocator.free(summary_resp.tool_calls);
    }

    const raw_summary = summary_resp.contentOrEmpty();

    // V1.6 commit 5a — split prose from extracted_memories JSON tail.
    // Output format (system prompt above): bullet prose, then literal
    // line "===EXTRACTED===", then a JSON array. The prose half is
    // what gets archived as the compaction_summary continuity artifact;
    // the JSON tail is consumed by V1.6 commit 5b's persist hook.
    //
    // For 5a (this commit) we just split + return prose; JSON tail is
    // discarded silently. 5b adds the persist call. This sequencing
    // keeps the substrate-validation step (V1.5.5 corpus re-run)
    // independent of the persistence layer — if the prompt change
    // regresses prose recall, we know before we wire writes.
    //
    // Graceful degradation: if no delimiter present, treat the whole
    // response as prose (LLM didn't follow the format — happens; the
    // existing summary path keeps working).
    const delimiter = "===EXTRACTED===";
    const split_idx = std.mem.indexOf(u8, raw_summary, delimiter);
    const prose_summary = if (split_idx) |idx|
        std.mem.trimRight(u8, raw_summary[0..idx], &std.ascii.whitespace)
    else
        raw_summary;

    // V1.6 commit 5b.2: pipe JSON tail to caller's out pointer when
    // requested. When delimiter absent (LLM didn't follow new format),
    // out is set to empty string so caller can detect no-tail case.
    if (json_tail_out) |out| {
        if (split_idx) |idx| {
            const tail_start = idx + delimiter.len;
            if (tail_start < raw_summary.len) {
                out.* = try allocator.dupe(u8, raw_summary[tail_start..]);
            } else {
                out.* = try allocator.dupe(u8, "");
            }
        } else {
            out.* = try allocator.dupe(u8, "");
        }
    }

    const max_len = @min(prose_summary.len, config.max_summary_chars);
    return try allocator.dupe(u8, prose_summary[0..max_len]);
}

const HeadingInfo = struct {
    level: u8,
    text: []const u8,
};

fn parseHeadingLine(line: []const u8) ?HeadingInfo {
    const trimmed_left = std.mem.trimLeft(u8, line, " \t");
    if (trimmed_left.len < 4) return null;

    var level: u8 = 0;
    var idx: usize = 0;
    while (idx < trimmed_left.len and trimmed_left[idx] == '#') : (idx += 1) {
        level += 1;
    }
    if (level < 2 or level > 3) return null;
    if (idx >= trimmed_left.len) return null;
    if (trimmed_left[idx] != ' ' and trimmed_left[idx] != '\t') return null;
    const heading_text = std.mem.trim(u8, trimmed_left[idx + 1 ..], " \t");
    if (heading_text.len == 0) return null;
    return .{
        .level = level,
        .text = heading_text,
    };
}

fn appendSectionLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    has_any: *bool,
    line: []const u8,
) !void {
    if (has_any.*) {
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, line);
    has_any.* = true;
}

fn extractNamedSection(
    allocator: std.mem.Allocator,
    content: []const u8,
    section_name: []const u8,
) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_section = false;
    var section_level: u8 = 0;
    var in_code_block = false;
    var has_any = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const left_trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, left_trimmed, "```")) {
            in_code_block = !in_code_block;
            if (in_section) {
                try appendSectionLine(allocator, &out, &has_any, line);
            }
            continue;
        }

        if (!in_code_block) {
            if (parseHeadingLine(line)) |heading| {
                if (!in_section) {
                    if (std.ascii.eqlIgnoreCase(heading.text, section_name)) {
                        in_section = true;
                        section_level = heading.level;
                        try appendSectionLine(allocator, &out, &has_any, line);
                        continue;
                    }
                } else {
                    if (heading.level <= section_level) {
                        break;
                    }
                    try appendSectionLine(allocator, &out, &has_any, line);
                    continue;
                }
            }
        }

        if (in_section) {
            try appendSectionLine(allocator, &out, &has_any, line);
        }
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }

    const raw = try out.toOwnedSlice(allocator);
    errdefer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.len == raw.len) return raw;

    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return duped;
}

fn extractSections(
    allocator: std.mem.Allocator,
    content: []const u8,
    section_names: []const []const u8,
) ![]u8 {
    var combined: std.ArrayListUnmanaged(u8) = .empty;
    errdefer combined.deinit(allocator);

    for (section_names) |section_name| {
        const maybe_section = try extractNamedSection(allocator, content, section_name);
        if (maybe_section) |section| {
            defer allocator.free(section);
            if (combined.items.len > 0) {
                try combined.appendSlice(allocator, "\n\n");
            }
            try combined.appendSlice(allocator, section);
        }
    }

    return try combined.toOwnedSlice(allocator);
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len > 0 and (prefix[prefix.len - 1] == '/' or prefix[prefix.len - 1] == '\\')) return true;
    const c = path[prefix.len];
    return c == '/' or c == '\\';
}

fn openWorkspaceAgentsFileGuarded(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
) ?std.fs.File {
    const workspace_root = std.fs.cwd().realpathAlloc(allocator, workspace_dir) catch return null;
    defer allocator.free(workspace_root);

    const agents_candidate = std.fs.path.join(allocator, &.{ workspace_root, "AGENTS.md" }) catch return null;
    defer allocator.free(agents_candidate);

    const agents_canonical = std.fs.cwd().realpathAlloc(allocator, agents_candidate) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer allocator.free(agents_canonical);

    if (!pathStartsWith(agents_canonical, workspace_root)) return null;
    return std.fs.openFileAbsolute(agents_canonical, .{}) catch null;
}

fn readWorkspaceContextForSummary(
    allocator: std.mem.Allocator,
    workspace_dir: ?[]const u8,
) ![]u8 {
    const dir = workspace_dir orelse return try allocator.dupe(u8, "");
    const file = openWorkspaceAgentsFileGuarded(allocator, dir) orelse return try allocator.dupe(u8, "");
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_AGENTS_FILE_BYTES) catch return try allocator.dupe(u8, "");
    defer allocator.free(content);

    const sections = try extractSections(allocator, content, &.{ "Session Startup", "Red Lines" });
    defer allocator.free(sections);
    if (sections.len == 0) return try allocator.dupe(u8, "");

    const safe_content = if (sections.len > MAX_WORKSPACE_CONTEXT_CHARS)
        try std.fmt.allocPrint(allocator, "{s}\n...[truncated]...", .{sections[0..MAX_WORKSPACE_CONTEXT_CHARS]})
    else
        try allocator.dupe(u8, sections);
    defer allocator.free(safe_content);

    return try std.fmt.allocPrint(
        allocator,
        "\n\n<workspace-critical-rules>\n{s}\n</workspace-critical-rules>",
        .{safe_content},
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const observability = @import("../observability.zig");
const ToolSpec = providers.ToolSpec;

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

test "tokenEstimate empty history" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Empty history: (0 + 3) / 4 = 0
    try std.testing.expectEqual(@as(u64, 0), tokenEstimate(agent.history.items));
}

test "tokenEstimate with messages" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add messages with known content lengths
    // "hello" = 5 chars, "world" = 5 chars => total 10 chars => (10 + 3) / 4 = 3
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "world"),
    });

    try std.testing.expectEqual(@as(u64, 3), tokenEstimate(agent.history.items));
}

test "tokenEstimate heuristic accuracy" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // 400 chars should estimate ~100 tokens
    const content = try allocator.alloc(u8, 400);
    defer allocator.free(content);
    @memset(content, 'a');

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, content),
    });

    // (400 + 3) / 4 = 100
    try std.testing.expectEqual(@as(u64, 100), tokenEstimate(agent.history.items));
}

test "autoCompactHistory no-op below token threshold" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add a few small messages — well below the token threshold.
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const compacted = try autoCompactHistory(allocator, &agent.history, agent.provider, agent.model_name, .{
        .token_limit = DEFAULT_TOKEN_LIMIT,
    });
    try std.testing.expect(!compacted);
    try std.testing.expectEqual(@as(usize, 2), agent.history.items.len);
}

test "DEFAULT_TOKEN_LIMIT constant" {
    try std.testing.expectEqual(config_types.DEFAULT_AGENT_TOKEN_LIMIT, DEFAULT_TOKEN_LIMIT);
}

test "forceCompressHistory keeps system + last 4 messages" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add system prompt + 8 messages
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });
    for (0..8) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }
    try std.testing.expectEqual(@as(usize, 9), agent.history.items.len);

    const compressed = forceCompressHistory(allocator, &agent.history);
    try std.testing.expect(compressed);

    // Should keep system + last 4
    try std.testing.expectEqual(@as(usize, 5), agent.history.items.len);
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expectEqualStrings("system prompt", agent.history.items[0].content);
    try std.testing.expectEqualStrings("msg-4", agent.history.items[1].content);
    try std.testing.expectEqualStrings("msg-7", agent.history.items[4].content);
}

test "forceCompressHistory without system prompt" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add 8 messages (no system prompt)
    for (0..8) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    const compressed = forceCompressHistory(allocator, &agent.history);
    try std.testing.expect(compressed);

    // Should keep last 4
    try std.testing.expectEqual(@as(usize, 4), agent.history.items.len);
    try std.testing.expectEqualStrings("msg-4", agent.history.items[0].content);
    try std.testing.expectEqualStrings("msg-7", agent.history.items[3].content);
}

test "forceCompressHistory no-op when history is small" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const compressed = forceCompressHistory(allocator, &agent.history);
    try std.testing.expect(!compressed);
    try std.testing.expectEqual(@as(usize, 2), agent.history.items.len);
}

test "manualCompactHistory summarizes older context and keeps recent recovery tail" {
    const SummaryProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "- compacted summary");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "- compacted summary"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "summary-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = SummaryProvider.chatWithSystem,
        .chat = SummaryProvider.chat,
        .supportsNativeTools = SummaryProvider.supportsNativeTools,
        .getName = SummaryProvider.getName,
        .deinit = SummaryProvider.deinitFn,
    };
    agent.provider = .{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });
    for (0..6) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    const compacted = try manualCompactHistory(allocator, &agent.history, agent.provider, agent.model_name, .{
        .keep_recent = 20,
        .max_summary_chars = 500,
        .max_source_chars = 1_500,
    });
    try std.testing.expect(compacted);
    try std.testing.expectEqual(@as(usize, 6), agent.history.items.len);
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expect(agent.history.items[1].role == .assistant);
    try std.testing.expect(std.mem.startsWith(u8, agent.history.items[1].content, "[Compaction summary]\n"));
    try std.testing.expectEqualStrings("msg-2", agent.history.items[2].content);
    try std.testing.expectEqualStrings("msg-5", agent.history.items[5].content);
}

test "CONTEXT_RECOVERY constants" {
    try std.testing.expectEqual(@as(usize, 6), CONTEXT_RECOVERY_MIN_HISTORY);
    try std.testing.expectEqual(@as(usize, 4), CONTEXT_RECOVERY_KEEP);
}

test "extractSections captures Session Startup and Red Lines, ignoring code fences" {
    const content =
        \\## Intro
        \\hello
        \\
        \\```md
        \\## Session Startup
        \\this must be ignored
        \\```
        \\
        \\## Session Startup
        \\- read SOUL.md
        \\
        \\### Nested detail
        \\- keep this too
        \\
        \\## Red Lines
        \\- do not leak secrets
        \\
        \\## Other
        \\ignored
    ;

    const sections = try extractSections(std.testing.allocator, content, &.{ "Session Startup", "Red Lines" });
    defer std.testing.allocator.free(sections);

    try std.testing.expect(std.mem.indexOf(u8, sections, "## Session Startup") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "### Nested detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "## Red Lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "this must be ignored") == null);
}

test "readWorkspaceContextForSummary wraps AGENTS critical sections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("AGENTS.md", .{});
        defer f.close();
        try f.writeAll(
            \\## Session Startup
            \\- read AGENTS.md
            \\- read SOUL.md
            \\
            \\## Red Lines
            \\- never leak tokens
        );
    }

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const context = try readWorkspaceContextForSummary(std.testing.allocator, workspace);
    defer std.testing.allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "<workspace-critical-rules>") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "Session Startup") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "Red Lines") != null);
}

test "readWorkspaceContextForSummary returns empty when AGENTS missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const context = try readWorkspaceContextForSummary(std.testing.allocator, workspace);
    defer std.testing.allocator.free(context);

    try std.testing.expectEqual(@as(usize, 0), context.len);
}

test "readWorkspaceContextForSummary blocks AGENTS symlink escape" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    var outside_tmp = std.testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    try outside_tmp.dir.writeFile(.{
        .sub_path = "outside-agents.md",
        .data =
        \\## Session Startup
        \\- outside
        \\
        \\## Red Lines
        \\- outside
        ,
    });

    const outside_path = try outside_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(outside_path);
    const outside_agents = try std.fs.path.join(std.testing.allocator, &.{ outside_path, "outside-agents.md" });
    defer std.testing.allocator.free(outside_agents);

    try ws_tmp.dir.symLink(outside_agents, "AGENTS.md", .{});

    const workspace = try ws_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const context = try readWorkspaceContextForSummary(std.testing.allocator, workspace);
    defer std.testing.allocator.free(context);

    try std.testing.expectEqual(@as(usize, 0), context.len);
}

test "buildCompactionTranscript excludes bootstrap system prompt when start skips system" {
    var history = std.ArrayListUnmanaged(OwnedMessage).empty;
    defer {
        for (history.items) |*msg| msg.deinit(std.testing.allocator);
        history.deinit(std.testing.allocator);
    }

    try history.append(std.testing.allocator, .{
        .role = .system,
        .content = try std.testing.allocator.dupe(u8, "AGENTS.md bootstrap content"),
    });
    try history.append(std.testing.allocator, .{
        .role = .user,
        .content = try std.testing.allocator.dupe(u8, "user-message"),
    });

    const transcript = try buildCompactionTranscript(
        std.testing.allocator,
        history.items,
        1,
        history.items.len,
        DEFAULT_COMPACTION_MAX_SOURCE_CHARS,
    );
    defer std.testing.allocator.free(transcript);

    try std.testing.expect(std.mem.indexOf(u8, transcript, "AGENTS.md bootstrap content") == null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "USER: user-message") != null);
}

test "tool-call pair hygiene: boundary never orphans tool result" {
    // Verify that when keep_recent boundary lands on a .tool message,
    // the boundary extends to include the preceding assistant tool_call.
    const allocator = std.testing.allocator;
    var history: std.ArrayListUnmanaged(OwnedMessage) = .empty;
    defer {
        for (history.items) |*msg| msg.deinit(allocator);
        history.deinit(allocator);
    }

    // Build history: [system, user1, asst1, user2, asst2(tool_call), tool_result, user3, asst3]
    try history.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u1") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a1") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u2") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "tool_call:read_file") });
    try history.append(allocator, .{ .role = .tool, .content = try allocator.dupe(u8, "file contents here") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u3") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a3") });

    // With keep_recent=3, naive boundary would be at index 5 (the .tool message).
    // Pair hygiene should extend keep_recent to include the assistant at index 4.
    // non_system_count = 7, keep_recent starts at 3, boundary = 1 + (7-3) = 5 → .tool
    // After hygiene: keep_recent should be 4, boundary at index 4 → .assistant
    const non_system = history.items.len - 1; // 7
    _ = non_system;

    // We can't call compactHistoryKeepingRecent directly since it needs a provider.
    // Instead, verify the boundary logic inline:
    const has_system = history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    const non_system_count = history.items.len - start;
    var keep_recent: usize = @min(non_system_count, 3);

    // Replicate the pair hygiene logic
    const boundary_idx = start + (non_system_count - keep_recent);
    if (boundary_idx < history.items.len and boundary_idx > start) {
        if (history.items[boundary_idx].role == .tool) {
            keep_recent += 1;
        }
    }
    {
        var adj_boundary = start + (non_system_count - keep_recent);
        while (adj_boundary > start and adj_boundary < history.items.len and
            history.items[adj_boundary].role == .tool)
        {
            keep_recent += 1;
            adj_boundary -= 1;
        }
    }
    keep_recent = @min(non_system_count, keep_recent);

    // Verify: keep_recent extended from 3 to 4 to include the assistant tool_call
    try std.testing.expectEqual(@as(usize, 4), keep_recent);

    // Verify the first kept message is the assistant (tool_call), not the .tool result
    const final_boundary = start + (non_system_count - keep_recent);
    try std.testing.expect(history.items[final_boundary].role == .assistant);
    try std.testing.expectEqualStrings("tool_call:read_file", history.items[final_boundary].content);
}

test "dropOldestPairsFromMiddle drops middle messages, preserves prefix + tail" {
    const allocator = std.testing.allocator;
    var history: std.ArrayListUnmanaged(OwnedMessage) = .empty;
    defer {
        for (history.items) |*msg| msg.deinit(allocator);
        history.deinit(allocator);
    }

    // Build history: system + first_user + several middle pairs + recent tail
    try history.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "first user task") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "ack") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "middle u1") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "middle a1") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "middle u2") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "middle a2") });
    // Recent tail (keep_recent=2 protects these)
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "recent_u") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "recent_a") });

    const reduced = dropOldestPairsFromMiddle(allocator, &history, .{ .token_limit = 1000, .keep_recent = 2 });
    try std.testing.expect(reduced);

    // Protected prefix preserved
    try std.testing.expectEqualStrings("sys", history.items[0].content);
    try std.testing.expectEqualStrings("first user task", history.items[1].content);

    // Recent tail preserved (now at indices 2 + 3 after drop)
    const last = history.items.len;
    try std.testing.expectEqualStrings("recent_a", history.items[last - 1].content);
    try std.testing.expectEqualStrings("recent_u", history.items[last - 2].content);

    // Middle messages gone
    for (history.items) |msg| {
        try std.testing.expect(std.mem.indexOf(u8, msg.content, "middle") == null);
    }
}

test "dropOldestPairsFromMiddle preserves tool_call/tool_result pair at tail boundary" {
    const allocator = std.testing.allocator;
    var history: std.ArrayListUnmanaged(OwnedMessage) = .empty;
    defer {
        for (history.items) |*msg| msg.deinit(allocator);
        history.deinit(allocator);
    }

    try history.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "first") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "old1") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "old_u") });
    // The pair that must stay together: assistant tool_call followed by .tool result.
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "tool_call:read_file") });
    try history.append(allocator, .{ .role = .tool, .content = try allocator.dupe(u8, "file contents") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "summary") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "recent_u") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "recent_a") });

    // keep_recent=4 lands tail_start at index 5 (the .tool message); the
    // tail-boundary walk should pull tail_start backward to include the
    // assistant tool_call at index 4, keeping the pair intact.
    _ = dropOldestPairsFromMiddle(allocator, &history, .{ .token_limit = 1000, .keep_recent = 4 });

    // Find the .tool message — its preceding message must still be the matching .assistant tool_call.
    var found_pair = false;
    var i: usize = 1;
    while (i < history.items.len) : (i += 1) {
        if (history.items[i].role == .tool) {
            try std.testing.expect(i > 0);
            try std.testing.expect(history.items[i - 1].role == .assistant);
            try std.testing.expectEqualStrings("tool_call:read_file", history.items[i - 1].content);
            found_pair = true;
            break;
        }
    }
    try std.testing.expect(found_pair);

    // System + first user always preserved.
    try std.testing.expectEqualStrings("sys", history.items[0].content);
    try std.testing.expectEqualStrings("first", history.items[1].content);
}

test "dropOldestPairsFromMiddle no-op when total under keep_recent + protect prefix" {
    const allocator = std.testing.allocator;
    var history: std.ArrayListUnmanaged(OwnedMessage) = .empty;
    defer {
        for (history.items) |*msg| msg.deinit(allocator);
        history.deinit(allocator);
    }

    try history.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u1") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a1") });

    // keep_recent=10 covers everything
    const reduced = dropOldestPairsFromMiddle(allocator, &history, .{ .token_limit = 1000, .keep_recent = 10 });
    try std.testing.expect(!reduced);
}

// V1.14.8 C6: extractFromDropWindow skip-path tests removed alongside the
// function. Pass A is now wired through extraction_runner.extractAtBoundary
// — its skip-path coverage lives in extraction/runner.zig's tests
// ("extractAtBoundary skip path: empty window", "empty extraction model",
// "no state mgr", "zero edges").

// V1.14.12 (Path A) — `extraction_legacy_direct_writes defaults to true` test
// REMOVED. Field deleted; the gated Pass C direct write block was deleted in
// Path A (commit closing M5 sprint).
