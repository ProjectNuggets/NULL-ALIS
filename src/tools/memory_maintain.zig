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
// Package 2a Task 3 (the miner) — pure analysis module + T2's
// provenance-typed behavior-fact store.
const trace_mining = @import("../agent/trace_mining.zig");
const learning = @import("../agent/learning.zig");

const log = std.log.scoped(.memory_maintain);

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
    /// Package 2a Task 3 (the miner) — where `mine_traces` writes
    /// `insights/{ISO-week}.md` + `.json`. Bound at tool-construction
    /// time from the same `workspace_dir` every file_* tool receives
    /// (see tools/root.zig::allTools). Empty when unset (non-test
    /// construction always sets this); `mine_traces` fails cleanly if
    /// empty rather than writing into cwd.
    workspace_dir: []const u8 = "",
    /// Package 2a Task 3 (the miner) — trace-mining gate. Bound from
    /// config.agent.trace_mining_enabled at tenant-runtime construction
    /// (mirrors the config-flag-to-tool-field plumbing pattern; see
    /// config_types.zig's docstring on the flag itself). Defaults TRUE
    /// so the struct's zero-value in ad-hoc test construction matches
    /// the flag's own default.
    trace_mining_enabled: bool = true,

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
        "Maintain truth across your memory graph. Single tool, nine actions: " ++
        "(1) cascade_update — rename entity across all edges; " ++
        "(2) invalidate_when — close edges matching (predicate, object_name); " ++
        "(3) resolve_contradiction — explicitly pick loser/winner by memory key; " ++
        "(4) propagate_correction — flag prose memories referencing a corrected entity; " ++
        "(5) temporal_decay — lower confidence on stale unreferenced memories; " ++
        "(6) survey — find current edge-graph contradictions and write to pending_conflicts_v2; " ++
        "(7) prose_survey — V1.10-B LLM-judge surveyor: scan durable_fact / timeline_summary rows mentioning entity_pattern, " ++
        "use the cheap sidecar judge to find prose-level contradictions, mark losers as superseded with bidirectional pointers. " ++
        "Use when stale prose facts (e.g. \"X is the codename\" + \"X is the OLD codename\") need cleanup that edge-graph survey can't see. " ++
        "(8) phase05_backfill — OPERATOR one-time corpus repair (DRY-RUN by default): re-type legacy core/daily rows by predicate semantics, " ++
        "upgrade 'PROPER' entities to PERSON where a relationship predicate proves it, delete pre-P4 embedded continuity summaries, and collapse " ++
        "EXACT content_hash duplicates (supersede, never delete). Idempotent. Pass apply=true for a live run; all_users=true to repair every user. " ++
        "Use when you notice stale facts, contradictory states, renamed entities, or unresolved corrections. " ++
        "(9) mine_traces — Package 2a: mine recent tool_traces for failure patterns / recurring tool-sequences / tool-fluency stats " ++
        "(deterministic, no LLM), write workspace/insights/{ISO-week}.md + .json, and draft shadow behavior-fact suggestions for " ++
        "recurring failures (not active until you say 'learn adopt'). scope=user (default) mines YOUR OWN traces; " ++
        "scope=fleet is an operator surface returning tool/count shapes ONLY (no run_ids, no content) with no file written. " ++
        "After each call, check `next_consideration` in the response for suggested follow-up actions.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["cascade_update","invalidate_when","resolve_contradiction","propagate_correction","temporal_decay","survey","prose_survey","phase05_backfill","mine_traces"],"description":"Which truth-maintenance operation to perform."},"old_name":{"type":"string","description":"For cascade_update: the entity name being renamed FROM."},"new_name":{"type":"string","description":"For cascade_update: the entity name being renamed TO."},"predicate":{"type":"string","description":"For invalidate_when: predicate to match (e.g. STATUS, PREFERS, WORKS_AT)."},"object_name":{"type":"string","description":"For invalidate_when: target entity name to match."},"subject_name":{"type":"string","description":"For invalidate_when: optional subject entity name to narrow further."},"loser_key":{"type":"string","description":"For resolve_contradiction: the memory key being closed."},"winner_key":{"type":"string","description":"For resolve_contradiction: the memory key that stays alive."},"correction_key":{"type":"string","description":"For propagate_correction: the memory key holding the correction."},"entity_pattern":{"type":"string","description":"For propagate_correction OR prose_survey: substring to match in target memory content (e.g. \"MNDA\", \"Mia\", \"Neptune\")."},"threshold_days":{"type":"integer","description":"For temporal_decay: only decay memories untouched for this many days. Default 30."},"half_life_days":{"type":"integer","description":"For temporal_decay: confidence half-life in days. Default 30."},"max_facts":{"type":"integer","description":"For prose_survey: cap on number of rows the LLM judge sees per call. Default 50, max 200. The result includes `more_available=true` if matching rows exceeded the cap so you can re-run with a tighter pattern."},"dry_run":{"type":"boolean","description":"For prose_survey: if true, returns judge verdicts without writing any metadata (preview mode). Default false."},"apply":{"type":"boolean","description":"For phase05_backfill ONLY: the one-time corpus repair is DRY-RUN by default (reports what WOULD change, writes nothing). Set apply=true to perform a LIVE run that modifies data. Idempotent + safe to re-run."},"all_users":{"type":"boolean","description":"For phase05_backfill ONLY: if true, repair EVERY user's corpus (the general fix). Default false = only the calling tenant's user_id."},"since_days":{"type":"integer","description":"For mine_traces: how many days of tool_traces to mine. Default 7."},"scope":{"type":"string","enum":["user","fleet"],"description":"For mine_traces: 'user' (default) mines your own traces and writes insight files + shadow fact drafts. 'fleet' is an operator surface: cross-user tool/count shapes only, returned in this call's output, no file written."},"session_id":{"type":"string","description":"For mine_traces (scope=user only): optional session lane to scope drafted shadow facts to. Omit for workspace-global scope."}},"required":["action"]}
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
            return ToolResult.fail("Missing 'action' parameter. One of: cascade_update, invalidate_when, resolve_contradiction, propagate_correction, temporal_decay, survey, prose_survey, phase05_backfill, mine_traces.");

        // Package 2a Task 3 (the miner) — dispatched BEFORE the shared
        // state_mgr/user_id unwrap below, because mine_traces owns its
        // OWN tenant-context checks internally (executeMineTraces):
        // the flag-off path must work with NEITHER bound (a disabled
        // gate is not a "tenant not configured" error), and fleet scope
        // needs state_mgr but explicitly NOT a numeric user_id. Folding
        // it into the shared guard below would make every mine_traces
        // call fail with a misleading "requires postgres state manager"
        // message even when the real reason is simply the flag being off.
        if (std.mem.eql(u8, action, "mine_traces")) {
            return executeMineTraces(allocator, self, args);
        }

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
        } else if (std.mem.eql(u8, action, "phase05_backfill")) {
            return executePhase05Backfill(allocator, smgr, uid, args);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Unknown action '{s}'. Valid: cascade_update, invalidate_when, resolve_contradiction, propagate_correction, temporal_decay, survey, prose_survey, phase05_backfill, mine_traces.", .{action});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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

    /// C0 (memory-phase-0.5) — operator-triggered one-time corpus backfill.
    ///
    /// SAFETY: DRY-RUN is the DEFAULT. With no `apply` arg (or `apply=false`)
    /// this COMPUTES + REPORTS what would change and writes NOTHING. A live run
    /// requires the explicit `apply=true` flag. `all_users=true` repairs every
    /// user's corpus (the general fix); default is the calling tenant only.
    ///
    /// Idempotent: re-running (dry or live) on already-backfilled data is a
    /// no-op — already-typed rows are skipped, entity re-typing only touches
    /// 'PROPER', exact-dedup gates on live rows, un-embed only removes existing
    /// continuity embeddings. The five operation counters are the whole output.
    fn executePhase05Backfill(
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        // DRY-RUN DEFAULT. `apply=true` is the ONLY way to write. Anything
        // else (absent, false) → dry_run.
        const apply = root.getBool(args, "apply") orelse false;
        const dry_run = !apply;
        const all_users = root.getBool(args, "all_users") orelse false;
        const user_scope: ?i64 = if (all_users) null else uid;

        const report = smgr.phase05Backfill(allocator, user_scope, dry_run) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "phase05_backfill failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        const next_consideration = if (dry_run)
            "Dry-run complete — nothing was written. Review the counters, then re-run with apply=true to perform the live repair. The operation is idempotent and safe to re-run."
        else if (report.near_dup_clusters > 0)
            "Live backfill applied. Note `near_dup_clusters` > 0: those are near-duplicate candidates (same subject+predicate, different content) DEFERRED to Phase 1's write-time MERGE — they were reported, not merged (merging here is data-loss risk)."
        else
            "Live backfill applied. Corpus re-typed, entities upgraded where determinable, embedded continuity removed, and exact duplicates superseded. Idempotent — a second run is a clean no-op.";

        const nc_esc = try jsonEscape(allocator, next_consideration);
        defer allocator.free(nc_esc);
        // Brain-leak Fix C (polish) — render via the pure helper so the
        // result JSON includes the scaffold_entities_purged /
        // scaffold_edges_purged counters an operator needs to see.
        const output = try formatPhase05Result(allocator, report, all_users, nc_esc);
        return ToolResult{ .success = true, .output = output };
    }
};

/// Brain-leak Fix C (polish) — render the phase05_backfill report as the
/// tool's JSON result string. Extracted as a pure helper so the output
/// shape (incl. the scaffold-purge counters) is unit-testable without a
/// live Postgres Manager. `next_consideration` must already be
/// JSON-escaped by the caller. Caller owns the returned slice.
fn formatPhase05Result(
    allocator: std.mem.Allocator,
    report: mem_root.Phase05BackfillReport,
    all_users: bool,
    next_consideration_escaped: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"action\":\"phase05_backfill\",\"dry_run\":{s},\"all_users\":{s},\"users_scanned\":{d}," ++
            "\"rows_retyped\":{d},\"entities_retyped\":{d},\"continuity_embeddings_removed\":{d}," ++
            "\"exact_dups_collapsed\":{d},\"near_dup_clusters\":{d}," ++
            // Brain-leak Fix C — surface the scaffold-purge blast radius so an
            // operator running the tool sees the purge counts in the result,
            // not just in log.info.
            "\"scaffold_entities_purged\":{d},\"scaffold_edges_purged\":{d}," ++
            "\"next_consideration\":\"{s}\"}}",
        .{
            if (report.dry_run) "true" else "false",
            if (all_users) "true" else "false",
            report.users_scanned,
            report.rows_retyped,
            report.entities_retyped,
            report.continuity_embeddings_removed,
            report.exact_dups_collapsed,
            report.near_dup_clusters,
            report.scaffold_entities_purged,
            report.scaffold_edges_purged,
            next_consideration_escaped,
        },
    );
}

test "brain-leak C polish: phase05_backfill output surfaces scaffold-purge counts" {
    const allocator = std.testing.allocator;
    const report = mem_root.Phase05BackfillReport{
        .dry_run = true,
        .users_scanned = 1,
        .rows_retyped = 5,
        .entities_retyped = 2,
        .continuity_embeddings_removed = 0,
        .exact_dups_collapsed = 1,
        .near_dup_clusters = 0,
        .scaffold_entities_purged = 3,
        .scaffold_edges_purged = 7,
    };
    const out = try formatPhase05Result(allocator, report, false, "ok");
    defer allocator.free(out);

    // The two scaffold counters are present with their values.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scaffold_entities_purged\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scaffold_edges_purged\":7") != null);
    // Existing counters still present (no regression in the result shape).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rows_retyped\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"near_dup_clusters\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"dry_run\":true") != null);
}

// ── mine_traces action (Package 2a Task 3 — the miner) ──────────────
//
// Governed by docs/learning-contract.md invariants 2, 4, 5. The pure
// analyze()/render*() calls live in trace_mining.zig (inv. 2 —
// observational, no LLM). This file orchestrates: flag check -> Manager
// read (thin) -> analyze -> write files (inv. 4 — rebuildable, tested
// for byte-identical idempotency below) -> draft shadow facts via T2's
// storeLearnedFact (inv. 1 — birthed shadow, never self-promoted).

/// Writes `{insights_dir}/{week_label}.md` + `.json` from a
/// MiningReport. Overwrite semantics (not append): re-running the miner
/// for the same window replaces both files, and because
/// renderInsightsMarkdown/renderInsightsJson are pure deterministic
/// functions of the report (trace_mining.zig), re-mining an
/// EQUIVALENT set of trace rows produces byte-identical files (learning
/// contract inv. 4 — insights are rebuildable). Creates insights_dir if
/// it does not already exist.
///
/// Uses plain create+writeAll (not file_write.zig's temp+rename+
/// symlink-defense machinery) deliberately: insights_dir/week_label are
/// derived internally by this tool (never a user-supplied path), so the
/// path-traversal/symlink-escape threat model file_write.zig defends
/// against does not apply here — matching this project's stated
/// preference for the simplest correct implementation over reused
/// machinery built for a different threat model.
fn writeInsightFiles(
    allocator: std.mem.Allocator,
    insights_dir: []const u8,
    week_label: []const u8,
    report: trace_mining.MiningReport,
) !void {
    std.fs.cwd().makePath(insights_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try std.fs.cwd().openDir(insights_dir, .{});
    defer dir.close();

    const md = try trace_mining.renderInsightsMarkdown(allocator, report, week_label);
    defer allocator.free(md);
    const md_name = try std.fmt.allocPrint(allocator, "{s}.md", .{week_label});
    defer allocator.free(md_name);
    try dir.writeFile(.{ .sub_path = md_name, .data = md });

    const json_str = try trace_mining.renderInsightsJson(allocator, report);
    defer allocator.free(json_str);
    const json_name = try std.fmt.allocPrint(allocator, "{s}.json", .{week_label});
    defer allocator.free(json_name);
    try dir.writeFile(.{ .sub_path = json_name, .data = json_str });
}

fn fixtureReportForFiles(allocator: std.mem.Allocator) !trace_mining.MiningReport {
    var fp_evidence = try allocator.alloc([]const u8, 1);
    fp_evidence[0] = try allocator.dupe(u8, "r-1-1");
    var failure_patterns = try allocator.alloc(trace_mining.FailurePattern, 1);
    failure_patterns[0] = .{
        .tool = try allocator.dupe(u8, "web_search"),
        .label = try allocator.dupe(u8, "timeout"),
        .count = 3,
        .evidence_run_ids = fp_evidence,
    };
    return .{
        .failure_patterns = failure_patterns,
        .recurrences = try allocator.alloc(trace_mining.RecurrenceCluster, 0),
        .tool_stats = try allocator.alloc(trace_mining.ToolStat, 0),
    };
}

test "writeInsightFiles: writes both .md and .json into the insights directory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const ws_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws_path);
    const insights_dir = try std.fs.path.join(allocator, &.{ ws_path, "insights" });
    defer allocator.free(insights_dir);

    var report = try fixtureReportForFiles(allocator);
    defer report.deinit(allocator);

    try writeInsightFiles(allocator, insights_dir, "2026-W28", report);

    const md_content = try tmp_dir.dir.readFileAlloc(allocator, "insights/2026-W28.md", 1 << 20);
    defer allocator.free(md_content);
    try std.testing.expect(std.mem.indexOf(u8, md_content, "web_search") != null);

    const json_content = try tmp_dir.dir.readFileAlloc(allocator, "insights/2026-W28.json", 1 << 20);
    defer allocator.free(json_content);
    try std.testing.expect(std.mem.indexOf(u8, json_content, "web_search") != null);
}

test "writeInsightFiles: re-running for the same window overwrites idempotently (byte-identical, inv. 4)" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const ws_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws_path);
    const insights_dir = try std.fs.path.join(allocator, &.{ ws_path, "insights" });
    defer allocator.free(insights_dir);

    var report_1 = try fixtureReportForFiles(allocator);
    defer report_1.deinit(allocator);
    try writeInsightFiles(allocator, insights_dir, "2026-W28", report_1);

    const md_1 = try tmp_dir.dir.readFileAlloc(allocator, "insights/2026-W28.md", 1 << 20);
    defer allocator.free(md_1);
    const json_1 = try tmp_dir.dir.readFileAlloc(allocator, "insights/2026-W28.json", 1 << 20);
    defer allocator.free(json_1);

    // Second mining run over an equivalent report (same content, freshly
    // built) — the re-derived files must be byte-identical (rebuildability).
    var report_2 = try fixtureReportForFiles(allocator);
    defer report_2.deinit(allocator);
    try writeInsightFiles(allocator, insights_dir, "2026-W28", report_2);

    const md_2 = try tmp_dir.dir.readFileAlloc(allocator, "insights/2026-W28.md", 1 << 20);
    defer allocator.free(md_2);
    const json_2 = try tmp_dir.dir.readFileAlloc(allocator, "insights/2026-W28.json", 1 << 20);
    defer allocator.free(json_2);

    try std.testing.expectEqualStrings(md_1, md_2);
    try std.testing.expectEqualStrings(json_1, json_2);
}

test "writeInsightFiles: creates the insights directory if it does not exist" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const ws_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws_path);
    const insights_dir = try std.fs.path.join(allocator, &.{ ws_path, "insights" });
    defer allocator.free(insights_dir);

    // Directory does not exist yet — writeInsightFiles must create it.
    var report = try fixtureReportForFiles(allocator);
    defer report.deinit(allocator);
    try writeInsightFiles(allocator, insights_dir, "2026-W28", report);

    var dir = try tmp_dir.dir.openDir("insights", .{});
    dir.close();
}

// ── draftShadowFactsForFailures: shadow drafts from FailurePatterns ──
//
// Learning contract inv. 1 (no self-promotion): every drafted fact is
// origin=mined_aggregate, which birthState() (learning.zig) always
// starts at state=shadow — never active without an external
// /learn adopt. This function only DRAFTS; it never promotes.

/// Summary of one draftShadowFactsForFailures call, for the tool's
/// JSON result / next_consideration text.
const DraftSummary = struct {
    drafted: usize = 0,
    skipped_duplicate: usize = 0,
    dropped_invalid_run_ids: usize = 0,
};

/// For each FailurePattern in `report`, drafts a one-line shadow
/// behavior fact ("When using <tool>, avoid <label> — failed <n>x
/// recently") via learning.storeLearnedFact(origin=.mined_aggregate,
/// ...). BINDING (review-mandated): evidence_run_ids are
/// format-validated via trace_mining.isValidRunId BEFORE they reach
/// storeLearnedFact or any renderer — anything not shaped like
/// `r-<digits>-<digits>` (including a run_id carrying a newline or
/// comma, closing T2's flagged content-header injection residual) is
/// dropped with a log.warn and excluded from the evidence passed to
/// storeLearnedFact. Dedup: if factKey(content) already exists in
/// memory (ANY state — shadow OR active), the draft is skipped
/// entirely (no duplicate write, no re-drafting an already-adopted or
/// already-shadow fact).
fn draftShadowFactsForFailures(
    allocator: std.mem.Allocator,
    mem: Memory,
    report: trace_mining.MiningReport,
    session_id: ?[]const u8,
) !DraftSummary {
    var summary = DraftSummary{};

    for (report.failure_patterns) |p| {
        if (p.count < trace_mining.MIN_PATTERN_COUNT) continue; // defensive; analyze() already gates this

        var valid_evidence: std.ArrayListUnmanaged([]const u8) = .empty;
        defer valid_evidence.deinit(allocator);
        for (p.evidence_run_ids) |rid| {
            if (trace_mining.isValidRunId(rid)) {
                try valid_evidence.append(allocator, rid);
            } else {
                summary.dropped_invalid_run_ids += 1;
                log.warn("mine_traces.invalid_run_id dropped tool={s} run_id_len={d}", .{ p.tool, rid.len });
            }
        }

        const content = if (p.label.len == 0)
            try std.fmt.allocPrint(allocator, "When using {s}, avoid recent failures — failed {d}x recently", .{ p.tool, p.count })
        else
            try std.fmt.allocPrint(allocator, "When using {s}, avoid {s} — failed {d}x recently", .{ p.tool, p.label, p.count });
        defer allocator.free(content);

        const key = try learning.factKey(allocator, content);
        defer allocator.free(key);
        if (try mem.get(allocator, key)) |existing| {
            var e = existing;
            e.deinit(allocator);
            summary.skipped_duplicate += 1;
            continue;
        }

        const result = try learning.storeLearnedFact(
            allocator,
            mem,
            content,
            .mined_aggregate,
            valid_evidence.items,
            session_id,
        );
        defer result.deinit(allocator);
        if (result.stored) summary.drafted += 1;
    }

    return summary;
}

test "draftShadowFactsForFailures: drafts a shadow fact for a qualifying failure pattern" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var report = try fixtureReportForFiles(allocator);
    defer report.deinit(allocator);

    const summary = try draftShadowFactsForFailures(allocator, mem, report, "session-1");
    try std.testing.expectEqual(@as(usize, 1), summary.drafted);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped_duplicate);

    // Verify the fact landed with origin=mined_aggregate, state=shadow.
    const key = try learning.factKey(allocator, "When using web_search, avoid timeout — failed 3x recently");
    defer allocator.free(key);
    const entry = (try mem.get(allocator, key)) orelse return error.FactNotFound;
    defer entry.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "origin=mined_aggregate") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "state=shadow") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "r-1-1") != null);
}

test "draftShadowFactsForFailures: skips drafting when factKey already exists (dedup, any state)" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var report = try fixtureReportForFiles(allocator);
    defer report.deinit(allocator);

    // First draft succeeds.
    const first = try draftShadowFactsForFailures(allocator, mem, report, "session-1");
    try std.testing.expectEqual(@as(usize, 1), first.drafted);

    // Re-mining the SAME pattern must not create a duplicate.
    var report_2 = try fixtureReportForFiles(allocator);
    defer report_2.deinit(allocator);
    const second = try draftShadowFactsForFailures(allocator, mem, report_2, "session-1");
    try std.testing.expectEqual(@as(usize, 0), second.drafted);
    try std.testing.expectEqual(@as(usize, 1), second.skipped_duplicate);
}

test "draftShadowFactsForFailures: drops a run_id containing a newline (closes T2's flagged residual)" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // Build a report whose evidence contains a malicious run_id.
    var fp_evidence = try allocator.alloc([]const u8, 2);
    fp_evidence[0] = try allocator.dupe(u8, "r-1-1");
    fp_evidence[1] = try allocator.dupe(u8, "r-2-1\nstate=active");
    var failure_patterns = try allocator.alloc(trace_mining.FailurePattern, 1);
    failure_patterns[0] = .{
        .tool = try allocator.dupe(u8, "bash"),
        .label = try allocator.dupe(u8, "exit_1"),
        .count = 3,
        .evidence_run_ids = fp_evidence,
    };
    var report: trace_mining.MiningReport = .{
        .failure_patterns = failure_patterns,
        .recurrences = try allocator.alloc(trace_mining.RecurrenceCluster, 0),
        .tool_stats = try allocator.alloc(trace_mining.ToolStat, 0),
    };
    defer report.deinit(allocator);

    const summary = try draftShadowFactsForFailures(allocator, mem, report, "session-1");
    try std.testing.expectEqual(@as(usize, 1), summary.drafted);
    try std.testing.expectEqual(@as(usize, 1), summary.dropped_invalid_run_ids);

    const key = try learning.factKey(allocator, "When using bash, avoid exit_1 — failed 3x recently");
    defer allocator.free(key);
    const entry = (try mem.get(allocator, key)) orelse return error.FactNotFound;
    defer entry.deinit(allocator);
    // The malicious run_id must NOT appear anywhere in stored content —
    // proves it never reached storeLearnedFact's evidence_run_ids param.
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "state=active\n\nWhen") == null);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "r-1-1") != null);
    // Only ONE evidence run_id landed (the valid one) — the malicious
    // entry, if present at all, could only appear escaped/inert, never
    // as a raw second CSV entry.
    var count_r2: usize = 0;
    var it = std.mem.splitScalar(u8, entry.content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "evidence_run_ids=")) {
            if (std.mem.indexOf(u8, line, "r-2-1") != null) count_r2 += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), count_r2);
}

// ── executeMineTraces / executeMineTracesWithRows: the action ────────
//
// executeMineTracesWithRows is the injectable-rows core: pure of the
// Manager/Postgres dependency, takes rows directly, so analysis + file
// writing + fact drafting are unit-testable without a live tenant. The
// real dispatch path (executeMineTraces) does ONE thin Manager read
// then delegates here — this is the "PG read is thin" structure the
// brief calls for.
//
// Default DAYS_DEFAULT=7 matches the brief's "since_days default 7".

const MINE_TRACES_DEFAULT_SINCE_DAYS: u32 = 7;

/// The injectable-rows core of `mine_traces`. Caller (executeMineTraces)
/// has already read the rows from Postgres (or, for fleet scope, from
/// ALL users); this function owns everything else: the flag check,
/// analysis, file writing (user scope only), and fact drafting (user
/// scope only — fleet is an operator surface with no per-tenant
/// behavior to influence, see the fleet branch below).
///
/// `rows` ownership: caller-owned; this function does NOT free them
/// (mirrors the analyze() borrowing contract — rows must outlive this
/// call, but this function never takes ownership).
fn executeMineTracesWithRows(
    allocator: std.mem.Allocator,
    self: *MemoryMaintainTool,
    rows: []const trace_mining.ToolTraceDigestRow,
    args: JsonObjectMap,
) !ToolResult {
    if (!self.trace_mining_enabled) {
        // Heap-allocated (not ToolResult.ok(literal)) — every other
        // branch of this action returns heap-allocated output, and
        // callers uniformly free result.output. Keeping this branch's
        // output on the same footing avoids a special-cased "this one
        // literal must not be freed" contract for callers to remember.
        const output = try allocator.dupe(u8, "{\"action\":\"mine_traces\",\"disabled\":true,\"message\":\"trace mining disabled via trace_mining_enabled=false\"}");
        return ToolResult{ .success = true, .output = output };
    }

    const scope = root.getString(args, "scope") orelse "user";
    const is_fleet = std.mem.eql(u8, scope, "fleet");

    var report = try trace_mining.analyze(allocator, rows);
    defer report.deinit(allocator);

    const week_label = trace_mining.isoWeekLabel(std.time.timestamp());

    if (is_fleet) {
        // Fleet scope (learning contract inv. 5 — operator surface):
        // NO file write (workspace/insights/ belongs to the invoking
        // user's own tenant; a fleet aggregate written there would be
        // an operator artifact leaking into a tenant's workspace — the
        // brief's own binding call: "fleet mode returns the JSON in the
        // ToolResult output ONLY"). NO fact drafting either — shadow
        // behavior facts are per-tenant learning, meaningless at fleet
        // aggregate scope. Labels are STRIPPED (fleet FailurePatterns
        // carry tool+count only — see stripLabelsForFleet below).
        const fleet_json = try renderFleetJson(allocator, report);
        defer allocator.free(fleet_json);
        const output = try allocator.dupe(u8, fleet_json);
        return ToolResult{ .success = true, .output = output };
    }

    // User scope: write insight files + draft shadow facts.
    if (self.workspace_dir.len == 0) {
        return ToolResult.fail("mine_traces requires workspace_dir (tool not fully constructed).");
    }
    const insights_dir = try std.fs.path.join(allocator, &.{ self.workspace_dir, "insights" });
    defer allocator.free(insights_dir);
    try writeInsightFiles(allocator, insights_dir, &week_label, report);

    var draft_summary = DraftSummary{};
    if (self.memory) |mem| {
        const session_id = root.getString(args, "session_id");
        draft_summary = try draftShadowFactsForFailures(allocator, mem, report, session_id);
    }

    const output = try std.fmt.allocPrint(
        allocator,
        "{{\"action\":\"mine_traces\",\"scope\":\"user\",\"week\":\"{s}\",\"failure_patterns\":{d},\"recurrences\":{d}," ++
            "\"tool_stats\":{d},\"facts_drafted\":{d},\"facts_skipped_duplicate\":{d},\"run_ids_dropped_invalid\":{d}}}",
        .{
            &week_label,
            report.failure_patterns.len,
            report.recurrences.len,
            report.tool_stats.len,
            draft_summary.drafted,
            draft_summary.skipped_duplicate,
            draft_summary.dropped_invalid_run_ids,
        },
    );
    return ToolResult{ .success = true, .output = output };
}

/// Fleet-scope JSON: tool_stats carry the full shape (tool, uses,
/// success_rate, p50_duration_ms — no user content), failure_patterns
/// carry tool+count ONLY (label is DROPPED — labels can carry tenant
/// content, e.g. an error message embedding a fragment of the failing
/// argument; see the privacy sentinel test below), and evidence_run_ids
/// / recurrences (which cite run_ids) are OMITTED ENTIRELY — no run_id,
/// user_id, argument, or content string ever appears in fleet output
/// (learning contract inv. 5).
fn renderFleetJson(allocator: std.mem.Allocator, report: trace_mining.MiningReport) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"scope\":\"fleet\",\"failure_patterns\":[");
    for (report.failure_patterns, 0..) |p, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"tool\":\"");
        try appendJsonEscapedFleet(allocator, &buf, p.tool);
        try buf.writer(allocator).print("\",\"count\":{d}}}", .{p.count});
    }
    try buf.appendSlice(allocator, "],\"tool_stats\":[");
    for (report.tool_stats, 0..) |t, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"tool\":\"");
        try appendJsonEscapedFleet(allocator, &buf, t.tool);
        try buf.writer(allocator).print(
            "\",\"uses\":{d},\"success_rate\":{d:.4},\"p50_duration_ms\":{d}}}",
            .{ t.uses, t.success_rate, t.p50_duration_ms },
        );
    }
    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

fn appendJsonEscapedFleet(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.writer(allocator).print("\\u{x:0>4}", .{c});
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
}

/// Real dispatch path: reads recent tool_traces rows from the tenant's
/// Manager (user scope) or across all users (fleet scope), then
/// delegates to executeMineTracesWithRows. "PG read is thin" — no
/// analysis logic lives here.
fn executeMineTraces(
    allocator: std.mem.Allocator,
    self: *MemoryMaintainTool,
    args: JsonObjectMap,
) !ToolResult {
    if (!self.trace_mining_enabled) {
        return executeMineTracesWithRows(allocator, self, &.{}, args);
    }

    const smgr = self.state_mgr orelse
        return ToolResult.fail("mine_traces requires postgres state manager (tenant context not wired).");

    const since_days_raw = root.getInt(args, "since_days") orelse @as(i64, MINE_TRACES_DEFAULT_SINCE_DAYS);
    const since_days: u32 = if (since_days_raw <= 0) MINE_TRACES_DEFAULT_SINCE_DAYS else @intCast(since_days_raw);

    const scope = root.getString(args, "scope") orelse "user";
    const is_fleet = std.mem.eql(u8, scope, "fleet");

    const rows = if (is_fleet)
        smgr.listRecentToolTracesAllUsers(allocator, since_days) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "mine_traces fleet read failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        }
    else blk: {
        const uid = self.user_id orelse
            return ToolResult.fail("mine_traces requires user_id (tenant context not wired).");
        break :blk smgr.listRecentToolTraces(allocator, uid, since_days) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "mine_traces read failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
    };
    defer {
        for (rows) |r| r.deinit(allocator);
        allocator.free(rows);
    }

    return executeMineTracesWithRows(allocator, self, rows, args);
}

test "mine_traces: flag off returns a disabled result and performs NO writes" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const ws_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws_path);

    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();

    var tool = MemoryMaintainTool{
        .workspace_dir = ws_path,
        .trace_mining_enabled = false,
        .memory = sqlite_mem.memory(),
    };

    const rows = try allocator.alloc(trace_mining.ToolTraceDigestRow, 0);
    const parsed_args = try root.parseTestArgs("{}");
    defer parsed_args.deinit();
    const result = try executeMineTracesWithRows(allocator, &tool, rows, parsed_args.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    // NOTE: error_msg is intentionally NOT freed here — every failure
    // branch in executeMineTracesWithRows returns ToolResult.fail(literal)
    // (see the "requires workspace_dir"/"requires postgres"/"requires
    // user_id" guards), matching this codebase's established convention
    // (see file_write.zig's tests) that literal error results must not be
    // freed. These tests all assert result.success, so error_msg is null
    // in the intended path regardless.

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "disabled") != null);

    // No insights directory was created.
    var dir_check = tmp_dir.dir.openDir("insights", .{});
    try std.testing.expectError(error.FileNotFound, dir_check);
    if (dir_check) |*d| d.close() else |_| {}
}

/// Builds a ToolTraceDigestRow whose events contain one failed
/// tool_call for `tool`/`label`. Used to construct multi-row fixtures
/// exercising the full mine_traces pipeline (read-rows -> analyze ->
/// write -> draft).
fn digestRow(allocator: std.mem.Allocator, run_id: []const u8, tool: []const u8, label: []const u8) !trace_mining.ToolTraceDigestRow {
    const events_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"kind\":\"tool_call\",\"tool\":\"{s}\",\"label\":\"{s}\",\"success\":false,\"duration_ms\":10}}]",
        .{ tool, label },
    );
    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .events_json = events_json,
        .created_at_unix = 0,
    };
}

test "mine_traces: user scope end-to-end — writes insight files AND drafts a shadow fact" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const ws_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws_path);

    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();

    var tool = MemoryMaintainTool{
        .workspace_dir = ws_path,
        .trace_mining_enabled = true,
        .memory = sqlite_mem.memory(),
    };

    var rows = [_]trace_mining.ToolTraceDigestRow{
        try digestRow(allocator, "r-1-1", "web_search", "timeout"),
        try digestRow(allocator, "r-2-1", "web_search", "timeout"),
        try digestRow(allocator, "r-3-1", "web_search", "timeout"),
    };
    defer for (rows) |r| r.deinit(allocator);

    const parsed_args = try root.parseTestArgs("{}");
    defer parsed_args.deinit();
    const result = try executeMineTracesWithRows(allocator, &tool, &rows, parsed_args.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    // NOTE: error_msg is intentionally NOT freed here — every failure
    // branch in executeMineTracesWithRows returns ToolResult.fail(literal)
    // (see the "requires workspace_dir"/"requires postgres"/"requires
    // user_id" guards), matching this codebase's established convention
    // (see file_write.zig's tests) that literal error results must not be
    // freed. These tests all assert result.success, so error_msg is null
    // in the intended path regardless.

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"failure_patterns\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"facts_drafted\":1") != null);

    // Insight files landed on disk with the current ISO week's name.
    const week_label = trace_mining.isoWeekLabel(std.time.timestamp());
    const md_path = try std.fmt.allocPrint(allocator, "insights/{s}.md", .{week_label});
    defer allocator.free(md_path);
    const md_content = try tmp_dir.dir.readFileAlloc(allocator, md_path, 1 << 20);
    defer allocator.free(md_content);
    try std.testing.expect(std.mem.indexOf(u8, md_content, "web_search") != null);

    // The shadow fact landed with origin=mined_aggregate, state=shadow.
    const mem = sqlite_mem.memory();
    const key = try learning.factKey(allocator, "When using web_search, avoid timeout — failed 3x recently");
    defer allocator.free(key);
    const entry = (try mem.get(allocator, key)) orelse return error.FactNotFound;
    defer entry.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "origin=mined_aggregate") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "state=shadow") != null);
}

test "mine_traces: fleet scope — privacy sentinel: a secret string in a label field never reaches fleet output" {
    const allocator = std.testing.allocator;
    var tool = MemoryMaintainTool{ .trace_mining_enabled = true };

    const SENTINEL = "SUPER_SECRET_TENANT_ARGUMENT_XYZZY_42";
    var rows = [_]trace_mining.ToolTraceDigestRow{
        try digestRow(allocator, "r-1-1", "web_search", SENTINEL),
        try digestRow(allocator, "r-2-1", "web_search", SENTINEL),
        try digestRow(allocator, "r-3-1", "web_search", SENTINEL),
    };
    defer for (rows) |r| r.deinit(allocator);

    const parsed_args = try root.parseTestArgs("{\"scope\":\"fleet\"}");
    defer parsed_args.deinit();
    const result = try executeMineTracesWithRows(allocator, &tool, &rows, parsed_args.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    // NOTE: error_msg is intentionally NOT freed here — every failure
    // branch in executeMineTracesWithRows returns ToolResult.fail(literal)
    // (see the "requires workspace_dir"/"requires postgres"/"requires
    // user_id" guards), matching this codebase's established convention
    // (see file_write.zig's tests) that literal error results must not be
    // freed. These tests all assert result.success, so error_msg is null
    // in the intended path regardless.

    try std.testing.expect(result.success);
    // The sentinel (which only ever appears in the LABEL field) must
    // NEVER appear in fleet output — labels are dropped entirely at
    // fleet scope (learning contract inv. 5).
    try std.testing.expect(std.mem.indexOf(u8, result.output, SENTINEL) == null);
    // The tool NAME (a shape, not content) IS allowed to appear.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "web_search") != null);
    // Run_ids must NEVER appear at fleet scope either.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "r-1-1") == null);
}

test "mine_traces: fleet scope writes NO files (returns JSON in ToolResult output only)" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const ws_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws_path);

    var tool = MemoryMaintainTool{ .workspace_dir = ws_path, .trace_mining_enabled = true };

    var rows = [_]trace_mining.ToolTraceDigestRow{
        try digestRow(allocator, "r-1-1", "bash", "exit_1"),
        try digestRow(allocator, "r-2-1", "bash", "exit_1"),
        try digestRow(allocator, "r-3-1", "bash", "exit_1"),
    };
    defer for (rows) |r| r.deinit(allocator);

    const parsed_args = try root.parseTestArgs("{\"scope\":\"fleet\"}");
    defer parsed_args.deinit();
    const result = try executeMineTracesWithRows(allocator, &tool, &rows, parsed_args.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    // NOTE: error_msg is intentionally NOT freed here — every failure
    // branch in executeMineTracesWithRows returns ToolResult.fail(literal)
    // (see the "requires workspace_dir"/"requires postgres"/"requires
    // user_id" guards), matching this codebase's established convention
    // (see file_write.zig's tests) that literal error results must not be
    // freed. These tests all assert result.success, so error_msg is null
    // in the intended path regardless.

    try std.testing.expect(result.success);
    var dir_check = tmp_dir.dir.openDir("insights", .{});
    try std.testing.expectError(error.FileNotFound, dir_check);
    if (dir_check) |*d| d.close() else |_| {}
}

test "mine_traces: dispatched correctly through the public Tool.execute() entry point (flag off, no tenant context needed)" {
    // Closes the loop on the execute()-level routing: mine_traces must
    // be reachable via the SAME dispatch path an agent actually calls
    // (tool.execute(args)), not just the injectable-rows test seam
    // above. Uses flag-off specifically because it needs NO state_mgr/
    // user_id — proving mine_traces's dispatch doesn't fall through the
    // top-level "requires postgres state manager" guard that gates
    // every OTHER action (cascade_update, invalidate_when, ...).
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const ws_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws_path);

    var tool = MemoryMaintainTool{
        .workspace_dir = ws_path,
        .trace_mining_enabled = false,
        // Deliberately state_mgr=null, user_id=null — proves mine_traces
        // does not require tenant context when the flag is off.
    };
    const t = tool.tool();

    const parsed_args = try root.parseTestArgs("{\"action\":\"mine_traces\"}");
    defer parsed_args.deinit();
    const result = try t.execute(allocator, parsed_args.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "disabled") != null);
}

test "mine_traces: missing 'action' error message lists mine_traces as a valid action" {
    // Exercises the VERY FIRST guard in execute() (missing 'action'
    // entirely), which fires before both the mine_traces early-dispatch
    // and the shared state_mgr/user_id guard — so this reaches the
    // literal error message unconditionally, without needing a
    // constructed tenant context. error_msg here is a static literal
    // (ToolResult.fail(...)) — matches this file's other tests'
    // "do not free a literal error result" convention.
    const allocator = std.testing.allocator;
    var tool = MemoryMaintainTool{};
    const t = tool.tool();

    const parsed_args = try root.parseTestArgs("{}");
    defer parsed_args.deinit();
    const result = try t.execute(allocator, parsed_args.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "mine_traces") != null);
}
