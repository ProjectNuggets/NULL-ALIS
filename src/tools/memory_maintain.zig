const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const zaki_state = @import("../zaki_state.zig");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const prose_judge = @import("prose_judge.zig");

/// V1.9-Rev finding #25 — escape a string for safe embedding inside
/// a JSON string value. Caller frees the returned slice. All
/// `next_consideration` strings in this tool are routed through
/// this helper before being interpolated into output JSON via
/// `{s}`, so a future contributor adding a quoted phrase or
/// backslash-bearing string can't silently break the JSON contract.
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, ch),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// V1.9-5 — `memory_maintain(action, params)`. The unified
/// truth-maintenance toolkit ZAKI asked for in his self-diagnostic
/// letter:
///
///   > "I don't want 5 separate tools. I want one:
///   >   memory_maintain(action, params)
///   > where action is one of: cascade_update, invalidate, resolve,
///   > decay, propagate. One tool. Five operations. Clean brain."
///
/// V1.9-1 through V1.9-7 shipped the SQL primitives. V1.9-5 ties
/// them into the agent-callable surface ZAKI invokes when he sees
/// rot.
///
/// Six actions:
///
///   • `cascade_update`         — rename entity across the live graph
///                                (V1.9-1 cascadeRenameEntity)
///   • `invalidate_when`        — close edges matching pattern
///                                (V1.9-2 invalidateEdgesByPattern)
///   • `resolve_contradiction`  — explicit-pick loser/winner close
///                                (V1.9-2 resolveContradiction)
///   • `propagate_correction`   — flag prose memories referencing
///                                a corrected entity, bidirectional
///                                superseded-by pointer
///                                (V1.9-3 propagateCorrection)
///   • `temporal_decay`         — exponential confidence decay over
///                                age, reinforce-by-use
///                                (V1.9-4 temporalDecay)
///   • `survey`                 — proactive contradiction surveyor
///                                writes pending_conflicts_v2
///                                (V1.9-7 surveyContradictions)
///
/// ## Agent self-questioning hook (next-gen aug C)
///
/// After every successful action, the response includes a
/// `next_consideration` field with a deterministic suggested
/// follow-up — turning a single correction into a chain of
/// related cleanups. ZAKI gets surfaced "you fixed X; consider
/// also checking Y" without a separate LLM call. Reactive →
/// emergent.
///
/// ## Tenant context
///
/// Wired by tools/root.zig::bindStateMgrTenant: state_mgr +
/// user_id. Without both, every action returns a clean
/// "tenant not configured" failure (graceful degrade for
/// non-postgres builds + standalone deployments).
pub const MemoryMaintainTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,
    memory: ?Memory = null,
    /// V1.10-B — sidecar provider for the LLM-judge prose surveyor.
    /// Wired by tools/root.zig::bindMemoryMaintainSidecar (called from
    /// gateway.zig once the per-tenant runtime is built). Without it,
    /// `prose_survey` returns a clean "sidecar not configured" failure.
    judge_provider: ?Provider = null,
    /// V1.10-B — model name for the sidecar judge call. Empty when not
    /// configured. The action handler treats `judge_provider != null`
    /// AND `judge_model.len > 0` as the wired-up state.
    judge_model: []const u8 = "",

    pub const tool_name = "memory_maintain";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Memory-graph janitor: rename entities, close stale edges, resolve contradictions, decay confidence.",
        .use_when = &.{
            "An entity was renamed and edges across the graph need cascade_update",
            "Two facts contradict and need resolve_contradiction (winner/loser by key)",
            "Stale prose facts mention an old codename and need prose_survey + supersession",
        },
        .do_not_use_for = &.{
            "memory_edit — for changing a single fact's surface text rather than graph-wide cleanup",
            "memory_archive — for closing one specific fact rather than running a janitorial sweep",
            "memory_purge_topic — for bulk-removing agent-generated artifacts on a topic",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_maintain", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Maintain truth across your memory graph. Single tool, seven actions: " ++
        "(1) cascade_update — rename entity across all edges; " ++
        "(2) invalidate_when — close edges matching (predicate, object_name); " ++
        "(3) resolve_contradiction — explicitly pick loser/winner by memory key; " ++
        "(4) propagate_correction — flag prose memories referencing a corrected entity; " ++
        "(5) temporal_decay — lower confidence on stale unreferenced memories; " ++
        "(6) survey — find current edge-graph contradictions and write to pending_conflicts_v2; " ++
        "(7) prose_survey — V1.10-B LLM-judge surveyor: scan durable_fact / timeline_summary rows mentioning entity_pattern, " ++
        "use the cheap sidecar judge to find prose-level contradictions, mark losers as superseded with bidirectional pointers. " ++
        "Use when stale prose facts (e.g. \"X is the codename\" + \"X is the OLD codename\") need cleanup that edge-graph survey can't see. " ++
        "Use when you notice stale facts, contradictory states, renamed entities, or unresolved corrections. " ++
        "After each call, check `next_consideration` in the response for suggested follow-up actions.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["cascade_update","invalidate_when","resolve_contradiction","propagate_correction","temporal_decay","survey","prose_survey"],"description":"Which truth-maintenance operation to perform."},"old_name":{"type":"string","description":"For cascade_update: the entity name being renamed FROM."},"new_name":{"type":"string","description":"For cascade_update: the entity name being renamed TO."},"predicate":{"type":"string","description":"For invalidate_when: predicate to match (e.g. STATUS, PREFERS, WORKS_AT)."},"object_name":{"type":"string","description":"For invalidate_when: target entity name to match."},"subject_name":{"type":"string","description":"For invalidate_when: optional subject entity name to narrow further."},"loser_key":{"type":"string","description":"For resolve_contradiction: the memory key being closed."},"winner_key":{"type":"string","description":"For resolve_contradiction: the memory key that stays alive."},"correction_key":{"type":"string","description":"For propagate_correction: the memory key holding the correction."},"entity_pattern":{"type":"string","description":"For propagate_correction OR prose_survey: substring to match in target memory content (e.g. \"MNDA\", \"Mia\", \"Neptune\")."},"threshold_days":{"type":"integer","description":"For temporal_decay: only decay memories untouched for this many days. Default 30."},"half_life_days":{"type":"integer","description":"For temporal_decay: confidence half-life in days. Default 30."},"max_facts":{"type":"integer","description":"For prose_survey: cap on number of rows the LLM judge sees per call. Default 50, max 200. The result includes `more_available=true` if matching rows exceeded the cap so you can re-run with a tighter pattern."},"dry_run":{"type":"boolean","description":"For prose_survey: if true, returns judge verdicts without writing any metadata (preview mode). Default false."}},"required":["action"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryMaintainTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryMaintainTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter. One of: cascade_update, invalidate_when, resolve_contradiction, propagate_correction, temporal_decay, survey, prose_survey.");

        const smgr = self.state_mgr orelse
            return ToolResult.fail("memory_maintain requires postgres state manager (tenant context not wired).");
        const uid = self.user_id orelse
            return ToolResult.fail("memory_maintain requires user_id (tenant context not wired).");

        if (std.mem.eql(u8, action, "cascade_update")) {
            return executeCascadeUpdate(allocator, smgr, uid, args);
        } else if (std.mem.eql(u8, action, "invalidate_when")) {
            return executeInvalidateWhen(allocator, smgr, uid, args);
        } else if (std.mem.eql(u8, action, "resolve_contradiction")) {
            return executeResolveContradiction(allocator, smgr, uid, args);
        } else if (std.mem.eql(u8, action, "propagate_correction")) {
            return executePropagateCorrection(allocator, smgr, uid, args);
        } else if (std.mem.eql(u8, action, "temporal_decay")) {
            return executeTemporalDecay(allocator, smgr, uid, args);
        } else if (std.mem.eql(u8, action, "survey")) {
            return executeSurvey(allocator, smgr, uid);
        } else if (std.mem.eql(u8, action, "prose_survey")) {
            return executeProseSurvey(allocator, smgr, uid, self.judge_provider, self.judge_model, args);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Unknown action '{s}'. Valid: cascade_update, invalidate_when, resolve_contradiction, propagate_correction, temporal_decay, survey, prose_survey.", .{action});
            return ToolResult{ .success = false, .output = msg };
        }
    }

    // ── Per-action dispatchers ─────────────────────────────────────

    fn executeCascadeUpdate(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const old_name = root.getString(args, "old_name") orelse
            return ToolResult.fail("cascade_update requires 'old_name' parameter.");
        const new_name = root.getString(args, "new_name") orelse
            return ToolResult.fail("cascade_update requires 'new_name' parameter.");
        if (old_name.len == 0 or new_name.len == 0) {
            return ToolResult.fail("cascade_update: 'old_name' and 'new_name' must not be empty.");
        }

        var result = smgr.cascadeRenameEntity(allocator, uid, old_name, new_name) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "cascade_update failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer result.deinit(allocator);

        const next_consideration = if (result.found_old and result.edges_rewritten > 0)
            "Consider also running propagate_correction with the new name to flag any prose memories (durable_facts / timeline_summaries) still referencing the old name."
        else if (!result.found_old)
            "No existing entity matched 'old_name'. If you intended to write a fresh fact, use memory_store. If you expected the entity to exist, double-check the spelling."
        else
            "No edges to rewrite (entity exists but is unconnected, or names already canonical). Nothing to follow up on.";

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"cascade_update\",\"found_old\":{s},\"edges_rewritten\":{d},\"edges_closed\":{d},\"next_consideration\":\"{s}\"}}",
            .{
                if (result.found_old) "true" else "false",
                result.edges_rewritten,
                result.edges_closed,
                nc_esc,
            },
        );
        return ToolResult{ .success = true, .output = output };
    }

    fn executeInvalidateWhen(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const predicate = root.getString(args, "predicate") orelse
            return ToolResult.fail("invalidate_when requires 'predicate' parameter.");
        const object_name = root.getString(args, "object_name") orelse
            return ToolResult.fail("invalidate_when requires 'object_name' parameter.");
        const subject_name = root.getString(args, "subject_name");

        const closed = smgr.invalidateEdgesByPattern(uid, predicate, object_name, subject_name) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "invalidate_when failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const next_consideration = if (closed > 0)
            "Edges closed. Consider writing a fresh replacement fact via memory_store (with subject/predicate/object) so the new value enters the graph."
        else
            "No edges matched the pattern. Either the object_name doesn't exist, no edges have that predicate, or they're already closed. Verify the entity exists via memory_recall first.";

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"invalidate_when\",\"predicate\":\"{s}\",\"object_name\":\"{s}\",\"edges_closed\":{d},\"next_consideration\":\"{s}\"}}",
            .{ predicate, object_name, closed, nc_esc },
        );
        return ToolResult{ .success = true, .output = output };
    }

    fn executeResolveContradiction(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const loser_key = root.getString(args, "loser_key") orelse
            return ToolResult.fail("resolve_contradiction requires 'loser_key' parameter.");
        const winner_key = root.getString(args, "winner_key") orelse
            return ToolResult.fail("resolve_contradiction requires 'winner_key' parameter.");

        const result = smgr.resolveContradiction(uid, loser_key, winner_key) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "resolve_contradiction failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const next_consideration = if (result.loser_closed)
            "Loser closed + edges cascaded. Consider running propagate_correction with the winner_key to flag any timeline_summaries / durable_facts still echoing the loser."
        else if (!result.loser_existed)
            "Loser key not found. Either it was already closed, or the key is mistyped. Use memory_recall to verify before retrying."
        else
            "No close occurred (unexpected — loser existed but didn't close). Check logs for SQL error.";

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"resolve_contradiction\",\"loser_existed\":{s},\"winner_existed\":{s},\"loser_closed\":{s},\"next_consideration\":\"{s}\"}}",
            .{
                if (result.loser_existed) "true" else "false",
                if (result.winner_existed) "true" else "false",
                if (result.loser_closed) "true" else "false",
                nc_esc,
            },
        );
        return ToolResult{ .success = true, .output = output };
    }

    fn executePropagateCorrection(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const correction_key = root.getString(args, "correction_key") orelse
            return ToolResult.fail("propagate_correction requires 'correction_key' parameter.");
        const entity_pattern = root.getString(args, "entity_pattern") orelse
            return ToolResult.fail("propagate_correction requires 'entity_pattern' parameter.");

        var result = smgr.propagateCorrection(allocator, uid, correction_key, entity_pattern) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "propagate_correction failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer result.deinit(allocator);

        const next_consideration = if (result.correction_existed and result.targets_flagged > 0)
            "Targets flagged with bidirectional pointers. Future memory_loader passes will surface 'this row was superseded' instead of presenting flagged content as live truth. Consider also running survey to find any edge-graph contradictions not caught by content match."
        else if (!result.correction_existed)
            "Correction key not found. Verify the key exists via memory_recall before retrying."
        else
            "No memories matched the entity_pattern. Either the pattern is too specific, or the corrected entity is only mentioned in skipped families (autosave/checkpoint/extracted).";

        // Build a JSON array of flagged keys for transparency.
        var keys_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer keys_buf.deinit(allocator);
        try keys_buf.append(allocator, '[');
        for (result.target_keys, 0..) |k, i| {
            if (i > 0) try keys_buf.append(allocator, ',');
            try keys_buf.append(allocator, '"');
            for (k) |ch| {
                if (ch == '"' or ch == '\\') try keys_buf.append(allocator, '\\');
                try keys_buf.append(allocator, ch);
            }
            try keys_buf.append(allocator, '"');
        }
        try keys_buf.append(allocator, ']');

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"propagate_correction\",\"correction_existed\":{s},\"targets_flagged\":{d},\"target_keys\":{s},\"next_consideration\":\"{s}\"}}",
            .{
                if (result.correction_existed) "true" else "false",
                result.targets_flagged,
                keys_buf.items,
                nc_esc,
            },
        );
        return ToolResult{ .success = true, .output = output };
    }

    fn executeTemporalDecay(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const threshold_days_raw = root.getInt(args, "threshold_days") orelse 30;
        const half_life_days_raw = root.getInt(args, "half_life_days") orelse 30;
        const threshold_days: u32 = if (threshold_days_raw <= 0) 30 else @intCast(threshold_days_raw);
        const half_life_days: u32 = if (half_life_days_raw <= 0) 30 else @intCast(half_life_days_raw);

        const result = smgr.temporalDecay(uid, threshold_days, half_life_days) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "temporal_decay failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const next_consideration = if (result.rows_decayed > 0)
            "Confidence dropped on stale rows. Future recalls will reinforce confidence on rows that are still current; rows that stay untouched continue to decay each tick. Consider running survey to find any contradictions among the freshly-decayed cohort."
        else
            "No rows met the decay threshold. Either threshold_days is too high, or all eligible memories were recently accessed (reinforce-by-use is keeping them fresh).";

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"temporal_decay\",\"threshold_days\":{d},\"half_life_days\":{d},\"rows_decayed\":{d},\"avg_decay_amount\":{d:.3},\"floor\":{d:.2},\"next_consideration\":\"{s}\"}}",
            .{
                threshold_days,
                half_life_days,
                result.rows_decayed,
                result.avg_decay_amount,
                result.floor,
                nc_esc,
            },
        );
        return ToolResult{ .success = true, .output = output };
    }

    fn executeSurvey(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
    ) !ToolResult {
        var result = smgr.surveyContradictions(allocator, uid) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "survey failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer result.deinit(allocator);

        const next_consideration = if (result.conflicts_found > 0)
            "Conflicts detected and written to pending_conflicts_v2. For each entry in conflicts_json, decide which target is current and call resolve_contradiction with loser/winner keys, OR use invalidate_when to close all matching edges by pattern."
        else
            "No edge-graph contradictions detected. Note: this surveyor is edge-graph-only; prose-level contradictions (e.g. multiple durable_facts saying different things about the same subject) require the V1.10 LLM-judge surveyor to detect.";

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"survey\",\"conflicts_found\":{d},\"sentinel_written\":{s},\"conflicts_json\":{s},\"next_consideration\":\"{s}\"}}",
            .{
                result.conflicts_found,
                if (result.sentinel_written) "true" else "false",
                result.conflicts_json,
                nc_esc,
            },
        );
        return ToolResult{ .success = true, .output = output };
    }

    /// V1.10-B — LLM-judge prose-contradiction surveyor.
    ///
    /// Closes ZAKI's 2026-05-06 stress-test gap: prose-level zombies
    /// (durable_fact rows saying "Project Neptune" coexisting with
    /// "Project Nullalis") that the edge-graph surveyor can't see and
    /// the W-INT-01 immortality guard correctly protects from
    /// agent-side mutation. The judge call uses the cheap sidecar
    /// (Groq Llama 8B free at typical scale; $0.18/M-tok on Together
    /// fallback). On contradictions, writes
    /// `metadata.superseded_by_correction` on the loser via the
    /// metadata-write seam (V1.9-3 path) — bypasses the immortality
    /// guard, leaves content/memory_type untouched, V1.10-A's
    /// loader-side filter then hides the row at retrieval time.
    ///
    /// Required params:
    ///   - entity_pattern : substring to scope the prose scan (e.g.
    ///     "MNDA", "Mia", "Neptune"). Empty pattern is rejected to
    ///     prevent a full-corpus judge call.
    ///
    /// Optional params:
    ///   - max_facts : cap on rows the judge sees per call. Default 50,
    ///     hard cap 200. V1.10-D-rev raised both from the original
    ///     12/25 after the MNDA diagnostic showed the original cap
    ///     silently truncated ZAKI's first sweep (7 zombies existed,
    ///     only 5 were judged). At 50 facts the judge prompt is ~4K
    ///     input tokens (3% of Llama 8B's 128K context); 200 is ~16K
    ///     tokens / 13%. Both within the cleanup-operation envelope.
    ///     When matching rows exceed the cap, the result JSON includes
    ///     `more_available=true` so the agent knows to re-run with a
    ///     tighter pattern or larger cap.
    ///   - dry_run  : if true, returns judge verdicts WITHOUT writing
    ///     any metadata. Preview mode.
    ///
    /// Failure modes (graceful):
    ///   - sidecar not configured -> clear error message
    ///   - sidecar call fails / returns garbage -> empty verdicts,
    ///     caller writes nothing
    ///   - LLM hallucinates a key -> dropped by prose_judge guard
    ///   - 0/1 facts matched -> nothing to compare, returns "no work"
    fn executeProseSurvey(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        judge_provider_opt: ?Provider,
        judge_model: []const u8,
        args: JsonObjectMap,
    ) !ToolResult {
        const entity_pattern = root.getString(args, "entity_pattern") orelse
            return ToolResult.fail("prose_survey requires 'entity_pattern' parameter (e.g. \"MNDA\", \"Mia\", \"Neptune\").");
        if (entity_pattern.len == 0) {
            return ToolResult.fail("prose_survey: 'entity_pattern' must not be empty (use a specific substring).");
        }

        const judge_provider = judge_provider_opt orelse
            return ToolResult.fail("prose_survey requires the sidecar judge provider (not wired). Set sidecar provider in config.");
        if (judge_model.len == 0) {
            return ToolResult.fail("prose_survey requires the sidecar judge model name (not configured).");
        }

        // V1.10-D-rev (2026-05-06): defaults bumped after the MNDA
        // diagnostic showed the original 12/25 cap silently truncated
        // ZAKI's first sweep — 7 zombies existed, only 5 were judged.
        // Cost analysis at 50 facts × ~80 tokens/fact ≈ 4K input
        // tokens (3% of Llama 8B's 128K context); latency ~2-3s on
        // Groq. At 200 cap × 80 ≈ 16K tokens (13% of context); ~5-8s
        // latency. Both well within the cleanup-operation envelope.
        // The previous 12/25 cap was conservative-without-measurement;
        // measuring once and removing the artificial guard is the
        // Karpathy keep/discard answer.
        const max_facts_raw = root.getInt(args, "max_facts") orelse 50;
        const max_facts: usize = blk: {
            if (max_facts_raw <= 0) break :blk 50;
            const cap: usize = @intCast(max_facts_raw);
            if (cap > 200) break :blk 200;
            break :blk cap;
        };
        const dry_run: bool = root.getBool(args, "dry_run") orelse false;

        // 1. Fetch matching prose facts.
        const facts = smgr.fetchProseFactsByPattern(allocator, uid, entity_pattern, max_facts) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "prose_survey fetch failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer mem_root.freeProseFacts(allocator, facts);

        // V1.9-Rev finding #25 — escape entity_pattern before
        // interpolating into output JSON. Even though ZAKI's typical
        // patterns ("MNDA", "Mia") are bare words, defensive escape
        // covers the case where an agent passes a quoted or
        // backslash-bearing pattern.
        const ep_esc = try jsonEscape(allocator, entity_pattern);
        defer allocator.free(ep_esc);

        if (facts.len < 2) {
            const nc = if (facts.len == 0)
                "No prose facts matched the entity_pattern. Either the pattern is too specific, the entity isn't mentioned in durable_fact / timeline_summary / summary_latest rows, or matching rows are already superseded. Try a shorter pattern or use survey for edge-graph conflicts."
            else
                "Only one prose fact matched — no contradictions possible (need at least two competing assertions). If you expected more, try a shorter or broader entity_pattern.";
            const nc_esc = try jsonEscape(allocator, nc);
            defer allocator.free(nc_esc);
            // V1.10-D-rev: include `more_available` field even on the
            // early-return path for JSON shape consistency. With
            // facts.len < 2, saturation is impossible by definition.
            const output = try std.fmt.allocPrint(
                allocator,
                "{{\"action\":\"prose_survey\",\"entity_pattern\":\"{s}\",\"facts_examined\":{d},\"more_available\":false,\"contradictions_found\":0,\"marked_keys\":[],\"dry_run\":{s},\"next_consideration\":\"{s}\"}}",
                .{
                    ep_esc,
                    facts.len,
                    if (dry_run) "true" else "false",
                    nc_esc,
                },
            );
            return ToolResult{ .success = true, .output = output };
        }

        // 2. Run the LLM judge.
        var verdicts = prose_judge.judgeProseContradictions(
            allocator,
            judge_provider,
            judge_model,
            facts,
        ) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "prose_survey judge failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer verdicts.deinit(allocator);

        // 3. Apply marks (or skip if dry_run). Track which keys actually
        // got marked vs which the SQL refused (e.g. loser_key not found,
        // which can happen if the row was deleted between fetch and mark).
        var marked: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (marked.items) |k| allocator.free(k);
            marked.deinit(allocator);
        }
        var skipped: usize = 0;

        if (!dry_run) {
            for (verdicts.items) |v| {
                const ok = smgr.markMemorySupersededByKey(uid, v.loser_key, v.winner_key) catch |err| blk: {
                    std.log.scoped(.tool).warn("prose_survey.mark_failed loser={s} winner={s} error={s}", .{
                        v.loser_key, v.winner_key, @errorName(err),
                    });
                    break :blk false;
                };
                if (ok) {
                    const k_owned = try allocator.dupe(u8, v.loser_key);
                    errdefer allocator.free(k_owned);
                    try marked.append(allocator, k_owned);
                } else {
                    skipped += 1;
                }
            }
        }

        // 4. Build a JSON array of verdicts for transparency. Always
        // includes loser/winner/reason, regardless of dry_run.
        var verdicts_json: std.ArrayListUnmanaged(u8) = .empty;
        defer verdicts_json.deinit(allocator);
        try verdicts_json.append(allocator, '[');
        for (verdicts.items, 0..) |v, i| {
            if (i > 0) try verdicts_json.append(allocator, ',');
            const loser_esc = try jsonEscape(allocator, v.loser_key);
            defer allocator.free(loser_esc);
            const winner_esc = try jsonEscape(allocator, v.winner_key);
            defer allocator.free(winner_esc);
            const reason_esc = try jsonEscape(allocator, v.reason);
            defer allocator.free(reason_esc);
            const entry = try std.fmt.allocPrint(
                allocator,
                "{{\"loser_key\":\"{s}\",\"winner_key\":\"{s}\",\"reason\":\"{s}\"}}",
                .{ loser_esc, winner_esc, reason_esc },
            );
            defer allocator.free(entry);
            try verdicts_json.appendSlice(allocator, entry);
        }
        try verdicts_json.append(allocator, ']');

        // 5. Build a JSON array of marked_keys (post-write).
        var marked_json: std.ArrayListUnmanaged(u8) = .empty;
        defer marked_json.deinit(allocator);
        try marked_json.append(allocator, '[');
        for (marked.items, 0..) |k, i| {
            if (i > 0) try marked_json.append(allocator, ',');
            try marked_json.append(allocator, '"');
            for (k) |ch| {
                if (ch == '"' or ch == '\\') try marked_json.append(allocator, '\\');
                try marked_json.append(allocator, ch);
            }
            try marked_json.append(allocator, '"');
        }
        try marked_json.append(allocator, ']');

        // V1.10-D-rev — `more_available` flags saturation: if the
        // fetch returned exactly max_facts rows, the SQL LIMIT likely
        // truncated. Caller can re-run with a higher cap or tighter
        // pattern to sweep deeper. Approximation (false-positive iff
        // matching rows == cap exactly), but the right UX answer:
        // "if you hit the cap, assume there might be more."
        const more_available = facts.len >= max_facts;

        const base_consideration = if (verdicts.items.len == 0)
            "Judge found no contradictions among the matched prose facts. Either they're complementary / non-conflicting, or the contradictions are too subtle for the small judge model. Consider rerunning with a tighter entity_pattern, or call survey for edge-graph contradictions on related triples."
        else if (dry_run)
            "Dry-run complete — verdicts shown but nothing written. Re-run without dry_run=true to apply the supersede marks. After applying, the marked rows become invisible at retrieval time via V1.10-A's loader filter."
        else if (marked.items.len > 0)
            "Loser rows flagged with bidirectional supersede pointers. They're now invisible to memory retrieval (V1.10-A) but still present in the database for audit. Consider running prose_survey on adjacent entities (e.g. anything the marked rows referenced) to cascade the cleanup."
        else
            "Judge identified contradictions but no marks landed (skipped count > 0 — likely loser_key already deleted or schema mismatch). Verify with memory_recall on the loser keys.";

        // V1.10-D-rev — append a saturation hint when the fetch hit
        // the cap. Without this, the agent has no way to know that
        // older zombies might exist beyond the judged window.
        const next_consideration_owned: ?[]u8 = if (more_available)
            try std.fmt.allocPrint(
                allocator,
                "{s} Note: matching rows hit the max_facts cap ({d}); rerun with a higher max_facts or a tighter entity_pattern to sweep deeper.",
                .{ base_consideration, max_facts },
            )
        else
            null;
        defer if (next_consideration_owned) |s| allocator.free(s);
        const next_consideration: []const u8 = next_consideration_owned orelse base_consideration;

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"prose_survey\",\"entity_pattern\":\"{s}\",\"facts_examined\":{d},\"more_available\":{s},\"contradictions_found\":{d},\"marked_keys\":{s},\"verdicts\":{s},\"skipped\":{d},\"dry_run\":{s},\"next_consideration\":\"{s}\"}}",
            .{
                ep_esc,
                facts.len,
                if (more_available) "true" else "false",
                verdicts.items.len,
                marked_json.items,
                verdicts_json.items,
                skipped,
                if (dry_run) "true" else "false",
                nc_esc,
            },
        );
        return ToolResult{ .success = true, .output = output };
    }
};
