//! V1.10-B — LLM-judge prose-contradiction surveyor.
//!
//! Reads a small batch of `ProseFact` rows that all mention the same
//! entity, asks a cheap LLM (Groq Llama 8B free tier or whatever
//! sidecar is wired) which ones contradict each other, and returns a
//! list of (loser_key → winner_key, reason) verdicts.
//!
//! ## Why this exists
//!
//! V1.9-7's edge-graph surveyor finds contradictions in
//! `(subject, predicate, object)` triples. ZAKI's stress test
//! (2026-05-06) showed his actual zombies live in PROSE — durable_fact
//! rows like "Project Neptune is the new ZAKI codename" alongside
//! "Project Nullalis is the new codename." Edge-graph survey can't see
//! prose contradictions; the V1.7 W-INT-01 immortality guard correctly
//! protects these rows from agent-side mutation. V1.10-B uses a tiny
//! LLM call to do what the SQL surveyor can't — semantic comparison of
//! prose. Once the judge identifies the loser, V1.10-B writes
//! `metadata.superseded_by_correction` via the metadata-write seam
//! (V1.9-3 path), and V1.10-A's loader-side filter hides the loser
//! from retrieval next turn.
//!
//! ## Cost
//!
//! Designed for the **sidecar provider** (Groq Llama 8B free tier at
//! ZAKI's scale; $0.18/M-tok on Together as fallback). Per call:
//!   - input  ~ 200 + 80*N facts tokens (≤ 1.0K for 10 facts)
//!   - output ~ 60 * (avg verdicts) tokens (≤ 0.3K typical)
//!   - latency ~ 600-1500ms on Groq
//!
//! At ZAKI's cleanup cadence (a few entity_pattern surveys per session),
//! this is effectively free.
//!
//! ## Safety
//!
//! 1. **Strict JSON contract.** System prompt commands JSON-only output;
//!    parser rejects anything that doesn't conform.
//! 2. **Key validation.** Every loser_key / winner_key in a verdict must
//!    appear in the input fact set. LLM-hallucinated keys are dropped
//!    with a warning log. Prevents the judge from inventing memory keys
//!    that would silently no-op the metadata write.
//! 3. **Self-supersede guard.** loser_key == winner_key is dropped.
//! 4. **Graceful degrade.** Sidecar failure / unparseable JSON returns
//!    an empty verdict list — the caller writes nothing, no false
//!    positives. The cost of a missed contradiction is one more turn of
//!    latency; the cost of a hallucinated one is a real piece of memory
//!    incorrectly hidden.

const std = @import("std");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatRequest = providers.ChatRequest;
const memory_root = @import("../memory/root.zig");
const ProseFact = memory_root.ProseFact;

const log = std.log.scoped(.prose_judge);

pub const Verdict = struct {
    /// Memory key that the judge ruled is superseded by `winner_key`.
    /// Caller frees.
    loser_key: []u8,
    /// Memory key that the judge ruled is the current/correct version.
    /// Caller frees.
    winner_key: []u8,
    /// Short LLM-authored explanation of why these contradict and why
    /// the winner was chosen. Caller frees. May be empty if the judge
    /// omitted the reason field.
    reason: []u8,

    pub fn deinit(self: *const Verdict, allocator: std.mem.Allocator) void {
        allocator.free(self.loser_key);
        allocator.free(self.winner_key);
        allocator.free(self.reason);
    }
};

pub const VerdictList = struct {
    items: []Verdict,

    pub fn deinit(self: *const VerdictList, allocator: std.mem.Allocator) void {
        for (self.items) |v| v.deinit(allocator);
        allocator.free(self.items);
    }

    pub fn empty(allocator: std.mem.Allocator) !VerdictList {
        return .{ .items = try allocator.alloc(Verdict, 0) };
    }
};

const JUDGE_SYSTEM_PROMPT =
    "You are a fact-checker reviewing memory entries that all reference the same subject. " ++
    "Your job: find PAIRS of entries that directly contradict each other (assert mutually-exclusive truths), " ++
    "and pick the entry that should remain as current truth (the WINNER) versus the one that should be marked superseded (the LOSER). " ++
    "Heuristics for picking the winner: prefer the entry with the more recent updated_at, " ++
    "the entry that explicitly corrects an earlier statement (\"Actually X is...\", \"Update: ...\"), " ++
    "or the entry with more specific / qualified language. Do NOT mark entries as contradicting if they are merely complementary, sequential, or describe different aspects of the subject. " ++
    "Output STRICT JSON only, no prose, no markdown fences. Schema: " ++
    "{\"contradictions\":[{\"loser_key\":\"<exact key from input>\",\"winner_key\":\"<exact key from input>\",\"reason\":\"<one sentence>\"}]}. " ++
    "If no contradictions exist, output {\"contradictions\":[]}. " ++
    "loser_key and winner_key MUST be exact strings copied from the input keys — never invent keys.";

/// Build the user-prompt body listing each fact as a JSON object on its
/// own line. Format kept compact so the prompt fits in the sidecar's
/// budget even with 10-15 facts.
fn buildFactList(allocator: std.mem.Allocator, facts: []const ProseFact) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "Memory entries (all reference the same subject):\n");
    for (facts) |f| {
        // Build one JSON line per fact: {"key":"...","updated_at":<ts>,"content":"..."}
        try buf.appendSlice(allocator, "- ");
        try buf.appendSlice(allocator, "{\"key\":\"");
        try appendJsonEscaped(allocator, &buf, f.key);
        try buf.appendSlice(allocator, "\",\"updated_at\":");
        try buf.writer(allocator).print("{d}", .{f.updated_at_unix});
        try buf.appendSlice(allocator, ",\"content\":\"");
        try appendJsonEscaped(allocator, &buf, f.content);
        try buf.appendSlice(allocator, "\"}\n");
    }
    try buf.appendSlice(allocator, "\nReturn the contradictions JSON now.");
    return try buf.toOwnedSlice(allocator);
}

fn appendJsonEscaped(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => |c| {
                if (c < 0x20) {
                    // Control character — encode as \u00XX
                    try buf.writer(allocator).print("\\u{x:0>4}", .{c});
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
}

/// Run the judge over `facts` and return verdicts. Returns an empty
/// list (allocated, len=0) on any soft-failure (sidecar error,
/// parse failure, no contradictions). Hard errors propagate via `!`.
pub fn judgeProseContradictions(
    allocator: std.mem.Allocator,
    sidecar_provider: Provider,
    sidecar_model: []const u8,
    facts: []const ProseFact,
) !VerdictList {
    if (facts.len < 2) return VerdictList.empty(allocator);

    const user_prompt = try buildFactList(allocator, facts);
    defer allocator.free(user_prompt);

    var messages: [2]ChatMessage = .{
        .{ .role = .system, .content = JUDGE_SYSTEM_PROMPT },
        .{ .role = .user, .content = user_prompt },
    };

    const request: ChatRequest = .{
        .messages = &messages,
        .model = sidecar_model,
        .temperature = 0.1, // Deterministic-ish for fact-checking.
        .max_tokens = 1024,
        .timeout_secs = 30,
    };

    const response = sidecar_provider.chat(
        allocator,
        request,
        sidecar_model,
        0.1,
    ) catch |err| {
        log.warn("prose_judge.sidecar_failed error={s} — returning empty verdicts", .{@errorName(err)});
        return VerdictList.empty(allocator);
    };
    defer {
        if (response.content) |c| if (c.len > 0) allocator.free(c);
        if (response.model.len > 0) allocator.free(response.model);
        if (response.reasoning_content) |rc| if (rc.len > 0) allocator.free(rc);
        for (response.tool_calls) |tc| {
            if (tc.id.len > 0) allocator.free(tc.id);
            if (tc.name.len > 0) allocator.free(tc.name);
            if (tc.arguments.len > 0) allocator.free(tc.arguments);
        }
        if (response.tool_calls.len > 0) allocator.free(response.tool_calls);
    }

    const content = response.contentOrEmpty();
    if (content.len == 0) {
        log.warn("prose_judge.empty_response — returning empty verdicts", .{});
        return VerdictList.empty(allocator);
    }

    return parseVerdicts(allocator, content, facts) catch |err| {
        log.warn("prose_judge.parse_failed error={s} response_len={d}", .{ @errorName(err), content.len });
        return VerdictList.empty(allocator);
    };
}

/// Parse the strict-JSON judge response into validated verdicts.
/// Drops any verdict whose loser_key or winner_key isn't present in
/// the original facts (LLM hallucination guard).
fn parseVerdicts(
    allocator: std.mem.Allocator,
    response: []const u8,
    facts: []const ProseFact,
) !VerdictList {
    // The judge sometimes prefixes a markdown fence despite instructions;
    // strip leading/trailing non-JSON whitespace and an optional
    // ```json ... ``` wrapper.
    const trimmed = stripJsonFence(std.mem.trim(u8, response, " \t\r\n"));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return VerdictList.empty(allocator);
    const obj = parsed.value.object;
    const arr_v = obj.get("contradictions") orelse return VerdictList.empty(allocator);
    if (arr_v != .array) return VerdictList.empty(allocator);
    const arr = arr_v.array;
    if (arr.items.len == 0) return VerdictList.empty(allocator);

    var out: std.ArrayListUnmanaged(Verdict) = .empty;
    errdefer {
        for (out.items) |v| v.deinit(allocator);
        out.deinit(allocator);
    }

    for (arr.items) |item| {
        if (item != .object) continue;
        const item_obj = item.object;
        const loser_v = item_obj.get("loser_key") orelse continue;
        const winner_v = item_obj.get("winner_key") orelse continue;
        if (loser_v != .string or winner_v != .string) continue;
        const loser = loser_v.string;
        const winner = winner_v.string;
        if (loser.len == 0 or winner.len == 0) continue;
        if (std.mem.eql(u8, loser, winner)) {
            log.warn("prose_judge.self_supersede_dropped key={s}", .{loser});
            continue;
        }

        // Hallucination guard: both keys must appear in input.
        if (!keyInFacts(loser, facts)) {
            log.warn("prose_judge.unknown_loser_key dropped='{s}'", .{loser});
            continue;
        }
        if (!keyInFacts(winner, facts)) {
            log.warn("prose_judge.unknown_winner_key dropped='{s}'", .{winner});
            continue;
        }

        const reason_str: []const u8 = if (item_obj.get("reason")) |r|
            (if (r == .string) r.string else "")
        else
            "";

        const loser_owned = try allocator.dupe(u8, loser);
        errdefer allocator.free(loser_owned);
        const winner_owned = try allocator.dupe(u8, winner);
        errdefer allocator.free(winner_owned);
        const reason_owned = try allocator.dupe(u8, reason_str);
        errdefer allocator.free(reason_owned);

        try out.append(allocator, .{
            .loser_key = loser_owned,
            .winner_key = winner_owned,
            .reason = reason_owned,
        });
    }

    return .{ .items = try out.toOwnedSlice(allocator) };
}

fn keyInFacts(key: []const u8, facts: []const ProseFact) bool {
    for (facts) |f| {
        if (std.mem.eql(u8, key, f.key)) return true;
    }
    return false;
}

/// Strip an optional ```json ... ``` wrapper. Idempotent on
/// already-clean input.
fn stripJsonFence(s: []const u8) []const u8 {
    var out = s;
    // Leading ```json or ``` (with optional trailing newline)
    if (std.mem.startsWith(u8, out, "```json")) {
        out = out[7..];
    } else if (std.mem.startsWith(u8, out, "```")) {
        out = out[3..];
    }
    out = std.mem.trim(u8, out, " \t\r\n");
    if (std.mem.endsWith(u8, out, "```")) {
        out = out[0 .. out.len - 3];
    }
    return std.mem.trim(u8, out, " \t\r\n");
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

test "stripJsonFence strips markdown fence" {
    const cleaned = stripJsonFence("```json\n{\"contradictions\":[]}\n```");
    try std.testing.expectEqualStrings("{\"contradictions\":[]}", cleaned);
}

test "stripJsonFence is idempotent on clean input" {
    const cleaned = stripJsonFence("{\"contradictions\":[]}");
    try std.testing.expectEqualStrings("{\"contradictions\":[]}", cleaned);
}

test "stripJsonFence handles bare triple-backtick" {
    const cleaned = stripJsonFence("```\n{\"x\":1}\n```");
    try std.testing.expectEqualStrings("{\"x\":1}", cleaned);
}

test "parseVerdicts drops verdict with hallucinated key" {
    const allocator = std.testing.allocator;
    const facts = [_]ProseFact{
        .{ .key = @constCast("durable_fact/A"), .content = @constCast("X is alpha"), .updated_at_unix = 100 },
        .{ .key = @constCast("durable_fact/B"), .content = @constCast("X is beta"), .updated_at_unix = 200 },
    };
    const response =
        \\{"contradictions":[
        \\  {"loser_key":"durable_fact/HALLUCINATED","winner_key":"durable_fact/B","reason":"hallucinated key"},
        \\  {"loser_key":"durable_fact/A","winner_key":"durable_fact/B","reason":"newer wins"}
        \\]}
    ;
    var verdicts = try parseVerdicts(allocator, response, &facts);
    defer verdicts.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), verdicts.items.len);
    try std.testing.expectEqualStrings("durable_fact/A", verdicts.items[0].loser_key);
    try std.testing.expectEqualStrings("durable_fact/B", verdicts.items[0].winner_key);
}

test "parseVerdicts handles empty contradictions array" {
    const allocator = std.testing.allocator;
    const facts = [_]ProseFact{
        .{ .key = @constCast("k1"), .content = @constCast("c1"), .updated_at_unix = 0 },
        .{ .key = @constCast("k2"), .content = @constCast("c2"), .updated_at_unix = 0 },
    };
    var verdicts = try parseVerdicts(allocator, "{\"contradictions\":[]}", &facts);
    defer verdicts.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), verdicts.items.len);
}

test "parseVerdicts drops self-supersede" {
    const allocator = std.testing.allocator;
    const facts = [_]ProseFact{
        .{ .key = @constCast("dup_key"), .content = @constCast("only one"), .updated_at_unix = 0 },
    };
    const response =
        \\{"contradictions":[{"loser_key":"dup_key","winner_key":"dup_key","reason":"same"}]}
    ;
    var verdicts = try parseVerdicts(allocator, response, &facts);
    defer verdicts.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), verdicts.items.len);
}

test "parseVerdicts strips markdown fence" {
    const allocator = std.testing.allocator;
    const facts = [_]ProseFact{
        .{ .key = @constCast("a"), .content = @constCast("X=1"), .updated_at_unix = 0 },
        .{ .key = @constCast("b"), .content = @constCast("X=2"), .updated_at_unix = 0 },
    };
    const fenced =
        \\```json
        \\{"contradictions":[{"loser_key":"a","winner_key":"b","reason":"newer"}]}
        \\```
    ;
    var verdicts = try parseVerdicts(allocator, fenced, &facts);
    defer verdicts.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), verdicts.items.len);
}

test "buildFactList escapes quotes and newlines" {
    const allocator = std.testing.allocator;
    const facts = [_]ProseFact{
        .{ .key = @constCast("k1"), .content = @constCast("He said \"hi\"\nthen left"), .updated_at_unix = 1234567890 },
    };
    const out = try buildFactList(allocator, &facts);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"hi\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1234567890") != null);
}
