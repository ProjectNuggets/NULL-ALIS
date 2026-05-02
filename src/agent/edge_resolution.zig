//! V1.6 commit 6 — Bi-temporal close-out + Graphiti contradiction LLM judge.
//!
//! When a new atomic fact arrives via `extraction_persist.persistExtracted`
//! (after MD5 dedup, before write), this module decides:
//!
//!   1. **Duplicate** — does an existing same-subject extracted fact say the
//!      same thing? → skip the new write (existing row stays as-is, optionally
//!      gets the new episode appended in V1.7).
//!   2. **Contradiction** — does the new fact supersede an older one?
//!      (e.g. `(user PREFERS Helix)` arriving when `(user PREFERS NeoVim)`
//!      is already on file). → close out the older row via bi-temporal
//!      `valid_to + invalid_at + expired_at` and let the new fact write.
//!
//! This is the V1.6 RESOLVE step that pairs with the V1.5.5 CAPTURE step.
//! Compaction Pass C captures both sides of a corrected fact (validated in
//! V1.5.5 error_recovery test); commit 6 closes out the loser.
//!
//! ## Algorithm (verbatim port of Graphiti `resolve_edge`)
//!
//!   - Build TWO candidate lists with continuous indices:
//!       EXISTING FACTS         = idx 0..N (same-subject extracted memories)
//!       INVALIDATION CANDIDATES = idx N..N+M (broader hybrid-search neighborhood)
//!   - One LLM call per new fact emits `{duplicate_facts:[idx], contradicted_facts:[idx]}`
//!   - duplicate_facts MUST be in EXISTING FACTS range (idx < N).
//!   - contradicted_facts can be from EITHER list.
//!   - Apply close-out arithmetic:
//!       contradicted older fact: valid_to = invalid_at = new.valid_at,
//!                                expired_at = now(), is_latest = false
//!
//! ## Failure modes (all non-fatal, log + proceed)
//!
//!   - LLM call fails → no contradictions resolved this batch (MD5 still
//!     guards against exact duplicates; semantic dups may slip through once)
//!   - LLM emits malformed JSON → tolerant parser returns empty result
//!   - Idx out of range → drop silently per spec
//!
//! ## Cost
//!
//! One LLM call per new memory that has at least one candidate. Per-trigger
//! count is small (0-5 facts after MD5 dedup), each call returns ~30 tokens,
//! so total contradiction-judge cost per compaction is < $0.001 on Together's
//! Llama-3.3-70B. Acceptable.

const std = @import("std");
const log = std.log.scoped(.edge_resolution);

const providers = @import("../providers/root.zig");
const zaki_state = @import("../zaki_state.zig");
const memory_root = @import("../memory/root.zig");
const extraction_persist = @import("extraction_persist.zig");

const ChatMessage = providers.ChatMessage;
const Provider = providers.Provider;
const ExtractedMemory = extraction_persist.ExtractedMemory;

/// One contradicted-out memory resolved by the judge. The caller writes
/// `setMemoryInvalidation(user_id, key, invalid_at, expired_at)` to close
/// it out.
pub const Contradiction = struct {
    /// Key of the existing memory whose fact has been superseded.
    existing_key: []const u8,
    /// Event time when the fact stopped being true. Set to the new fact's
    /// `valid_at` (today: `std.time.timestamp()` because the extraction
    /// path doesn't yet plumb explicit `valid_at` from the LLM).
    invalid_at: i64,
    /// System time of close-out (when the row was marked superseded).
    /// Set to `std.time.timestamp()`. Differs from `invalid_at` only when
    /// correcting historical data (V2 feature).
    expired_at: i64,
};

/// Per-fact judge outcome.
pub const ResolveOutcome = struct {
    /// True if the LLM said this new fact duplicates an existing one — skip
    /// the write entirely.
    is_duplicate: bool,
    /// Existing memory keys whose facts the new fact contradicts. Caller
    /// runs close-out on each.
    contradictions: []const Contradiction,

    pub fn deinit(self: *const ResolveOutcome, allocator: std.mem.Allocator) void {
        for (self.contradictions) |c| allocator.free(c.existing_key);
        allocator.free(self.contradictions);
    }
};

/// Hard cap on how many candidates we feed to the judge per call. The
/// resolve_edge prompt scales O(candidates) in token count + judging
/// quality starts to drop past ~20 in Graphiti's own deployment.
pub const MAX_RELATED_CANDIDATES: usize = 12;
pub const MAX_BROADER_CANDIDATES: usize = 8;

/// Resolve duplicate + contradiction status for one new fact against
/// pre-fetched candidate lists.
///
/// Returns a `ResolveOutcome` describing what the caller should do. On
/// any failure (LLM error, parse error, empty candidates) returns the
/// no-op outcome `{is_duplicate=false, contradictions=&.{}}` so the
/// caller writes the new fact normally — fail-open semantics, since
/// failing-closed risks losing facts.
///
/// `related` and `broader` candidates may share entries; the indices
/// are continuous: idx 0..related.len = related, idx related.len..total
/// = broader. duplicate_facts from the LLM are accepted only if idx <
/// related.len (per spec).
pub fn resolveOne(
    allocator: std.mem.Allocator,
    provider: Provider,
    judge_model_name: []const u8,
    new_memory: ExtractedMemory,
    related: []const memory_root.MemoryEntry,
    broader: []const memory_root.MemoryEntry,
) !ResolveOutcome {
    const empty_contradictions: []const Contradiction = &.{};

    if (related.len == 0 and broader.len == 0) {
        return .{ .is_duplicate = false, .contradictions = empty_contradictions };
    }

    // Build the prompt
    const prompt_user = buildResolvePrompt(allocator, new_memory, related, broader) catch |err| {
        log.warn("edge_resolution.prompt_build_failed err={s}", .{@errorName(err)});
        return .{ .is_duplicate = false, .contradictions = empty_contradictions };
    };
    defer allocator.free(prompt_user);

    var messages: [2]ChatMessage = .{
        .{
            .role = .system,
            .content = JUDGE_SYSTEM_PROMPT,
        },
        .{
            .role = .user,
            .content = prompt_user,
        },
    };

    const resp = provider.chat(
        allocator,
        .{
            .messages = messages[0..],
            .model = judge_model_name,
            .temperature = 0.0,
            .tools = null,
            .timeout_secs = 30,
        },
        judge_model_name,
        0.0,
    ) catch |err| {
        log.warn("edge_resolution.llm_failed err={s} subject={s} predicate={s}", .{
            @errorName(err), new_memory.subject, new_memory.predicate,
        });
        return .{ .is_duplicate = false, .contradictions = empty_contradictions };
    };
    defer freeChatResponse(allocator, resp);

    const raw = resp.contentOrEmpty();
    if (raw.len == 0) {
        log.warn("edge_resolution.empty_response subject={s}", .{new_memory.subject});
        return .{ .is_duplicate = false, .contradictions = empty_contradictions };
    }

    var parsed = parseJudgeJson(allocator, raw) catch |err| {
        log.warn("edge_resolution.parse_failed err={s}", .{@errorName(err)});
        return .{ .is_duplicate = false, .contradictions = empty_contradictions };
    };
    defer parsed.deinit(allocator);

    // Apply spec rules:
    //   - duplicate_facts: only valid if idx < related.len (per Graphiti spec)
    //   - contradicted_facts: idx may span both lists
    var is_duplicate = false;
    for (parsed.duplicate_facts) |idx| {
        if (idx >= 0 and @as(usize, @intCast(idx)) < related.len) {
            is_duplicate = true;
            log.info("edge_resolution.duplicate_detected new_subject={s} predicate={s} matches_existing_key={s}", .{
                new_memory.subject, new_memory.predicate, related[@intCast(idx)].key,
            });
            break; // any duplicate hit is enough — skip the new write
        }
    }

    // Build contradiction list. Now is the close-out timestamp — for V1.6
    // we don't yet plumb explicit `valid_at` from the extraction LLM, so
    // both `invalid_at` and `expired_at` use `now()`. When V2 adds explicit
    // valid_at, this becomes `invalid_at = new.valid_at`, `expired_at = now()`.
    const now_ts = std.time.timestamp();
    var contras: std.ArrayListUnmanaged(Contradiction) = .{};
    errdefer {
        for (contras.items) |c| allocator.free(c.existing_key);
        contras.deinit(allocator);
    }

    const total = related.len + broader.len;
    for (parsed.contradicted_facts) |raw_idx| {
        if (raw_idx < 0) continue;
        const idx: usize = @intCast(raw_idx);
        if (idx >= total) continue;

        const existing = if (idx < related.len)
            related[idx]
        else
            broader[idx - related.len];

        // Defensive: don't try to invalidate a row that's already been
        // close-out'd. Without this guard a chain of corrections within one
        // batch could double-write the same superseded row.
        if (existing.valid_to) |vt| {
            if (vt > 0 and vt <= now_ts) continue;
        }

        const dup_key = try allocator.dupe(u8, existing.key);
        errdefer allocator.free(dup_key);
        try contras.append(allocator, .{
            .existing_key = dup_key,
            .invalid_at = now_ts,
            .expired_at = now_ts,
        });

        log.info("edge_resolution.contradiction new_subject={s} new_predicate={s} closes_existing_key={s}", .{
            new_memory.subject, new_memory.predicate, existing.key,
        });
    }

    return .{
        .is_duplicate = is_duplicate,
        .contradictions = try contras.toOwnedSlice(allocator),
    };
}

/// Apply contradiction close-outs by writing `valid_to + invalid_at +
/// expired_at + is_latest=false` on each existing row. Each row gets a
/// separate UPDATE so a partial failure (one row missing, or constraint
/// violation) doesn't abort the rest.
///
/// Failure mode: log.warn per failed row; continue. Caller proceeds with
/// the new write regardless.
pub fn applyContradictions(
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    contradictions: []const Contradiction,
) usize {
    var applied: usize = 0;
    for (contradictions) |c| {
        state_mgr.setMemoryInvalidation(user_id, c.existing_key, c.invalid_at, c.expired_at) catch |err| {
            log.warn("edge_resolution.invalidation_write_failed key={s} err={s}", .{
                c.existing_key, @errorName(err),
            });
            continue;
        };
        applied += 1;
    }
    return applied;
}

// ── Prompt construction ─────────────────────────────────────────────────────

/// Verbatim from Graphiti `prompts/dedupe_edges.py:43` system role.
const JUDGE_SYSTEM_PROMPT =
    "You are a fact deduplication assistant. " ++
    "NEVER mark facts with key differences as duplicates.";

/// Build the user-side prompt with the new fact + two candidate lists.
/// Continuous idx numbering across both lists per Graphiti spec.
fn buildResolvePrompt(
    allocator: std.mem.Allocator,
    new_memory: ExtractedMemory,
    related: []const memory_root.MemoryEntry,
    broader: []const memory_root.MemoryEntry,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(
        \\NEVER mark facts as duplicates if they have key differences, particularly around numeric values, dates, or key qualifiers.
        \\
        \\IMPORTANT constraints:
        \\- duplicate_facts: ONLY idx values from EXISTING FACTS (NEVER include FACT INVALIDATION CANDIDATES)
        \\- contradicted_facts: idx values from EITHER list (EXISTING FACTS or FACT INVALIDATION CANDIDATES)
        \\- The idx values are continuous across both lists (INVALIDATION CANDIDATES start where EXISTING FACTS end)
        \\
        \\<EXISTING FACTS>
        \\
    );
    for (related, 0..) |m, i| {
        try w.print("idx={d}: \"{s}\"\n", .{ i, m.content });
    }
    try w.writeAll(
        \\</EXISTING FACTS>
        \\
        \\<FACT INVALIDATION CANDIDATES>
        \\
    );
    for (broader, 0..) |m, j| {
        const idx = related.len + j;
        try w.print("idx={d}: \"{s}\"\n", .{ idx, m.content });
    }
    try w.writeAll(
        \\</FACT INVALIDATION CANDIDATES>
        \\
        \\<NEW FACT>
        \\
    );
    try w.print("\"{s}\"\n", .{new_memory.text});
    try w.writeAll(
        \\</NEW FACT>
        \\
        \\You will receive TWO lists of facts with CONTINUOUS idx numbering across both lists.
        \\EXISTING FACTS are indexed first, followed by FACT INVALIDATION CANDIDATES.
        \\
        \\1. DUPLICATE DETECTION:
        \\   - If the NEW FACT represents identical factual information as any fact in EXISTING FACTS, return those idx values in duplicate_facts.
        \\   - If no duplicates, return an empty list for duplicate_facts.
        \\
        \\2. CONTRADICTION DETECTION:
        \\   - Determine which facts the NEW FACT contradicts from either list.
        \\   - A fact from EXISTING FACTS can be both a duplicate AND contradicted (e.g., semantically the same but the new fact updates/supersedes it).
        \\   - Return all contradicted idx values in contradicted_facts.
        \\   - If no contradictions, return an empty list for contradicted_facts.
        \\
        \\<EXAMPLE>
        \\EXISTING FACT: idx=0, "Alice joined Acme Corp in 2020"
        \\NEW FACT: "Alice joined Acme Corp in 2020"
        \\Result: duplicate_facts=[0], contradicted_facts=[] (identical factual information)
        \\
        \\EXISTING FACT: idx=1, "Alice works at Acme Corp as a software engineer"
        \\NEW FACT: "Alice works at Acme Corp as a senior engineer"
        \\Result: duplicate_facts=[], contradicted_facts=[1] (same relationship but updated title — contradiction, NOT a duplicate)
        \\
        \\EXISTING FACT: idx=2, "Bob ran 5 miles on Tuesday"
        \\NEW FACT: "Bob ran 3 miles on Wednesday"
        \\Result: duplicate_facts=[], contradicted_facts=[] (different events on different days — neither duplicate nor contradiction)
        \\</EXAMPLE>
        \\
        \\Respond with EXACTLY this JSON shape (no prose, no code fence):
        \\{"duplicate_facts": [<idx>...], "contradicted_facts": [<idx>...]}
        \\
    );

    return buf.toOwnedSlice(allocator);
}

// ── JSON parsing (tolerant) ─────────────────────────────────────────────────

const JudgeResult = struct {
    duplicate_facts: []const i64,
    contradicted_facts: []const i64,

    pub fn deinit(self: *JudgeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.duplicate_facts);
        allocator.free(self.contradicted_facts);
    }
};

/// Tolerant of:
///   - leading / trailing whitespace
///   - markdown code fence (```json ... ```)
///   - non-integer values (skipped)
///   - missing keys (treated as empty arrays)
///
/// Caller frees both fields via `JudgeResult.deinit`.
pub fn parseJudgeJson(allocator: std.mem.Allocator, raw: []const u8) !JudgeResult {
    var s = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfPos(u8, s, 3, "\n")) |nl| {
            s = s[nl + 1 ..];
        }
        if (std.mem.endsWith(u8, s, "```")) {
            s = s[0 .. s.len - 3];
        }
        s = std.mem.trim(u8, s, &std.ascii.whitespace);
    }

    if (s.len == 0) {
        const empty: []const i64 = &.{};
        return .{
            .duplicate_facts = try allocator.dupe(i64, empty),
            .contradicted_facts = try allocator.dupe(i64, empty),
        };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, s, .{}) catch {
        const empty: []const i64 = &.{};
        return .{
            .duplicate_facts = try allocator.dupe(i64, empty),
            .contradicted_facts = try allocator.dupe(i64, empty),
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        const empty: []const i64 = &.{};
        return .{
            .duplicate_facts = try allocator.dupe(i64, empty),
            .contradicted_facts = try allocator.dupe(i64, empty),
        };
    }

    return .{
        .duplicate_facts = try extractIntArray(allocator, parsed.value.object.get("duplicate_facts")),
        .contradicted_facts = try extractIntArray(allocator, parsed.value.object.get("contradicted_facts")),
    };
}

fn extractIntArray(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const i64 {
    var out: std.ArrayListUnmanaged(i64) = .{};
    errdefer out.deinit(allocator);
    if (value_opt) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                switch (item) {
                    .integer => |n| try out.append(allocator, n),
                    .float => |f| try out.append(allocator, @intFromFloat(f)),
                    else => {}, // skip non-numeric idx silently
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn freeChatResponse(allocator: std.mem.Allocator, resp: providers.ChatResponse) void {
    if (resp.content) |c| {
        if (c.len > 0) allocator.free(c);
    }
    if (resp.model.len > 0) allocator.free(resp.model);
    if (resp.reasoning_content) |rc| {
        if (rc.len > 0) allocator.free(rc);
    }
    for (resp.tool_calls) |tc| {
        if (tc.id.len > 0) allocator.free(tc.id);
        if (tc.name.len > 0) allocator.free(tc.name);
        if (tc.arguments.len > 0) allocator.free(tc.arguments);
    }
    if (resp.tool_calls.len > 0) allocator.free(resp.tool_calls);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "parseJudgeJson handles empty arrays" {
    const allocator = std.testing.allocator;
    var r = try parseJudgeJson(allocator, "{\"duplicate_facts\":[],\"contradicted_facts\":[]}");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), r.duplicate_facts.len);
    try std.testing.expectEqual(@as(usize, 0), r.contradicted_facts.len);
}

test "parseJudgeJson handles single duplicate" {
    const allocator = std.testing.allocator;
    var r = try parseJudgeJson(allocator, "{\"duplicate_facts\":[3],\"contradicted_facts\":[]}");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), r.duplicate_facts.len);
    try std.testing.expectEqual(@as(i64, 3), r.duplicate_facts[0]);
}

test "parseJudgeJson handles multiple contradictions across both lists" {
    const allocator = std.testing.allocator;
    var r = try parseJudgeJson(allocator, "{\"duplicate_facts\":[],\"contradicted_facts\":[1, 5, 7]}");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), r.contradicted_facts.len);
    try std.testing.expectEqual(@as(i64, 1), r.contradicted_facts[0]);
    try std.testing.expectEqual(@as(i64, 5), r.contradicted_facts[1]);
    try std.testing.expectEqual(@as(i64, 7), r.contradicted_facts[2]);
}

test "parseJudgeJson tolerates code fence" {
    const allocator = std.testing.allocator;
    const raw = "```json\n{\"duplicate_facts\":[0],\"contradicted_facts\":[]}\n```";
    var r = try parseJudgeJson(allocator, raw);
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), r.duplicate_facts.len);
}

test "parseJudgeJson tolerates malformed JSON gracefully" {
    const allocator = std.testing.allocator;
    var r = try parseJudgeJson(allocator, "garbage }{}{");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), r.duplicate_facts.len);
    try std.testing.expectEqual(@as(usize, 0), r.contradicted_facts.len);
}

test "parseJudgeJson treats missing keys as empty arrays" {
    const allocator = std.testing.allocator;
    var r = try parseJudgeJson(allocator, "{\"duplicate_facts\":[2]}");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), r.duplicate_facts.len);
    try std.testing.expectEqual(@as(usize, 0), r.contradicted_facts.len);
}

test "parseJudgeJson skips non-integer idx silently" {
    const allocator = std.testing.allocator;
    const raw = "{\"duplicate_facts\":[\"x\", 2, null, 5],\"contradicted_facts\":[]}";
    var r = try parseJudgeJson(allocator, raw);
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), r.duplicate_facts.len);
    try std.testing.expectEqual(@as(i64, 2), r.duplicate_facts[0]);
    try std.testing.expectEqual(@as(i64, 5), r.duplicate_facts[1]);
}

test "buildResolvePrompt produces continuous idx numbering" {
    const allocator = std.testing.allocator;
    const new = ExtractedMemory{
        .text = "User prefers Helix",
        .subject = "user",
        .predicate = "PREFERS",
        .object = "Helix",
        .attributed_to = "user",
        .confidence = 1.0,
    };
    const related = [_]memory_root.MemoryEntry{
        .{ .id = "a", .key = "k1", .content = "User prefers NeoVim", .category = .core, .timestamp = "1" },
    };
    const broader = [_]memory_root.MemoryEntry{
        .{ .id = "b", .key = "k2", .content = "User uses pgvector", .category = .core, .timestamp = "2" },
    };
    const out = try buildResolvePrompt(allocator, new, &related, &broader);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx=0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx=1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "User prefers Helix") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "EXISTING FACTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FACT INVALIDATION CANDIDATES") != null);
}
