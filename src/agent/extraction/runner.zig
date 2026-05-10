//! V1.14.8 — Boundary extraction runner.
//!
//! Single entry point used by all boundary triggers (Pass C summary,
//! session-end TTL). Pass A is intentionally NOT wired (see V1.14.8 C2 —
//! Pass A's drop-from-middle behavior preserved; extraction wire deferred
//! until Pass A is observed firing in production).
//!
//! Per boundary fire:
//!   1. Build a transcript of the conversation window once (reused).
//!   2. Run extraction LLM call → JSON {entities, edges} → ExtractionResult.
//!   3. Run hydration LLM call → XML <summary> → HydrationSummary.
//!   4. Persist extraction via existing extraction_persist.persistExtracted
//!      (entity coref, edge upsert, vector sync, working memory promotion).
//!   5. Persist hydration as `summary_latest/<session>` text payload.
//!   6. Return BoundaryResult so caller can attach to its own telemetry.
//!
//! Failure-soft at every layer: any LLM/parse/persist error is logged and
//! the corresponding output null'd; the boundary's primary write proceeds.
//! Skips silently when extraction context lacks the required plumbing
//! (no judge_provider, no state_mgr, etc.).

const std = @import("std");
const log = std.log.scoped(.extraction_runner);

const providers = @import("../../providers/root.zig");
const memory_root = @import("../../memory/root.zig");
const zaki_state = @import("../../zaki_state.zig");

const schema = @import("schema.zig");
const prompts = @import("prompts.zig");
const parser = @import("parser.zig");
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
/// Required fields: judge_provider, judge_model, state_mgr, user_id.
/// Optional: session_id, coref_embed, archive_mem, archive_mem_rt.
///
/// When required fields are missing, the corresponding output is silently
/// skipped — the runner does NOT error.
pub const ExtractionContext = struct {
    judge_provider: Provider,
    judge_model: []const u8,
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
};

/// Convenience: persist what we extracted/hydrated and return the
/// combined result. Caller frees via BoundaryResult.deinit.
pub fn extractAtBoundary(
    allocator: std.mem.Allocator,
    window: []const ChatMessage,
    ctx: ExtractionContext,
) schema.BoundaryResult {
    if (window.len == 0) {
        log.info("boundary.skip reason=empty_window", .{});
        return .{ .extraction = null, .hydration = null };
    }
    if (ctx.judge_model.len == 0) {
        log.info("boundary.skip reason=no_judge_model", .{});
        return .{ .extraction = null, .hydration = null };
    }

    const transcript = buildTranscript(allocator, window, ctx.max_source_chars) catch |err| {
        log.warn("boundary.transcript_failed err={s}", .{@errorName(err)});
        return .{ .extraction = null, .hydration = null };
    };
    defer allocator.free(transcript);

    if (transcript.len == 0) {
        log.info("boundary.skip reason=empty_transcript", .{});
        return .{ .extraction = null, .hydration = null };
    }

    // Two LLM calls. Sequential for simplicity (parallel adds threading
    // complexity and boundaries are infrequent — once per Pass A drop or
    // session end, not per turn).
    const extraction_result = runExtractionCall(allocator, transcript, ctx) catch |err| blk: {
        log.warn("boundary.extraction.call_failed err={s}", .{@errorName(err)});
        break :blk null;
    };

    const hydration_result = runHydrationCall(allocator, transcript, ctx) catch |err| blk: {
        log.warn("boundary.hydration.call_failed err={s}", .{@errorName(err)});
        break :blk null;
    };

    // Persist (best-effort per layer)
    if (extraction_result) |e| {
        persistExtraction(allocator, e, ctx) catch |err| {
            log.warn("boundary.extraction.persist_failed err={s}", .{@errorName(err)});
        };
    }
    if (hydration_result) |h| {
        persistHydration(allocator, h, ctx) catch |err| {
            log.warn("boundary.hydration.persist_failed err={s}", .{@errorName(err)});
        };
    }

    log.info(
        "boundary.complete entities={d} edges={d} hydration_present={} window_msgs={d} transcript_bytes={d}",
        .{
            if (extraction_result) |e| e.entities.len else 0,
            if (extraction_result) |e| e.edges.len else 0,
            hydration_result != null,
            window.len,
            transcript.len,
        },
    );

    return .{ .extraction = extraction_result, .hydration = hydration_result };
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
    var messages = [_]ChatMessage{
        .{ .role = .system, .content = prompts.extractionSystemPrompt() },
        .{ .role = .user, .content = transcript },
    };
    const request = providers.ChatRequest{
        .messages = messages[0..],
        .model = ctx.judge_model,
        .temperature = 0.2,
        .tools = null,
        .timeout_secs = ctx.timeout_secs,
    };

    const response = ctx.judge_provider.chat(allocator, request, ctx.judge_model, 0.2) catch |err| {
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
    var messages = [_]ChatMessage{
        .{ .role = .system, .content = prompts.hydrationSystemPrompt() },
        .{ .role = .user, .content = transcript },
    };
    const request = providers.ChatRequest{
        .messages = messages[0..],
        .model = ctx.judge_model,
        .temperature = 0.3,
        .tools = null,
        .timeout_secs = ctx.timeout_secs,
    };

    const response = ctx.judge_provider.chat(allocator, request, ctx.judge_model, 0.3) catch |err| {
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

    // Convert each edge to an ExtractedMemory. The text/subject/predicate/
    // object map directly. attributed_to defaults to "user" (boundary
    // extraction is implicitly user-attributed; the agent's own writes go
    // through memory_store, not this path).
    const mems = try allocator.alloc(extraction_persist.ExtractedMemory, result.edges.len);
    defer {
        for (mems) |m| m.deinit(allocator);
        allocator.free(mems);
    }

    for (result.edges, 0..) |edge, i| {
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

    const judge_ctx = extraction_persist.JudgeContext{
        .provider = ctx.judge_provider,
        .model_name = ctx.judge_model,
    };
    const coref_ctx: ?extraction_persist.EntityResolution = if (ctx.coref_embed) |ep|
        extraction_persist.EntityResolution{ .embed_provider = ep, .threshold = 0.95 }
    else
        null;

    const persist_result = extraction_persist.persistExtracted(
        allocator,
        smgr,
        uid,
        ctx.session_id,
        mems,
        judge_ctx,
        coref_ctx,
        ctx.archive_mem_rt,
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
        .judge_provider = undefined,
        .judge_model = "test-model",
    };
    const result = extractAtBoundary(allocator, empty_window, ctx);
    defer result.deinit(allocator);
    try std.testing.expect(result.extraction == null);
    try std.testing.expect(result.hydration == null);
}

test "extractAtBoundary skip path: empty judge_model" {
    const allocator = std.testing.allocator;
    const msgs = [_]ChatMessage{.{ .role = .user, .content = "test" }};
    const ctx = ExtractionContext{
        .judge_provider = undefined,
        .judge_model = "",
    };
    const result = extractAtBoundary(allocator, &msgs, ctx);
    defer result.deinit(allocator);
    try std.testing.expect(result.extraction == null);
    try std.testing.expect(result.hydration == null);
}

test "persistExtraction skip path: no state mgr" {
    const allocator = std.testing.allocator;
    const result = try schema.ExtractionResult.empty(allocator);
    defer result.deinit(allocator);
    const ctx = ExtractionContext{
        .judge_provider = undefined,
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
        .judge_provider = undefined,
        .judge_model = "test-model",
        .state_mgr = &fake_mgr,
        .user_id = 42,
    };
    // zero edges → early return without touching state_mgr
    try persistExtraction(allocator, result, ctx);
}
