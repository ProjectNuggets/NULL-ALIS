const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const zaki_state = @import("../zaki_state.zig");

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

    pub const tool_name = "memory_maintain";
    pub const tool_description =
        "Maintain truth across your memory graph. Single tool, six actions: " ++
        "(1) cascade_update — rename entity across all edges; " ++
        "(2) invalidate_when — close edges matching (predicate, object_name); " ++
        "(3) resolve_contradiction — explicitly pick loser/winner by memory key; " ++
        "(4) propagate_correction — flag prose memories referencing a corrected entity; " ++
        "(5) temporal_decay — lower confidence on stale unreferenced memories; " ++
        "(6) survey — find current edge-graph contradictions and write to pending_conflicts_v2. " ++
        "Use when you notice stale facts, contradictory states, renamed entities, or unresolved corrections. " ++
        "After each call, check `next_consideration` in the response for suggested follow-up actions.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["cascade_update","invalidate_when","resolve_contradiction","propagate_correction","temporal_decay","survey"],"description":"Which truth-maintenance operation to perform."},"old_name":{"type":"string","description":"For cascade_update: the entity name being renamed FROM."},"new_name":{"type":"string","description":"For cascade_update: the entity name being renamed TO."},"predicate":{"type":"string","description":"For invalidate_when: predicate to match (e.g. STATUS, PREFERS, WORKS_AT)."},"object_name":{"type":"string","description":"For invalidate_when: target entity name to match."},"subject_name":{"type":"string","description":"For invalidate_when: optional subject entity name to narrow further."},"loser_key":{"type":"string","description":"For resolve_contradiction: the memory key being closed."},"winner_key":{"type":"string","description":"For resolve_contradiction: the memory key that stays alive."},"correction_key":{"type":"string","description":"For propagate_correction: the memory key holding the correction."},"entity_pattern":{"type":"string","description":"For propagate_correction: substring to match in target memory content."},"threshold_days":{"type":"integer","description":"For temporal_decay: only decay memories untouched for this many days. Default 30."},"half_life_days":{"type":"integer","description":"For temporal_decay: confidence half-life in days. Default 30."}},"required":["action"]}
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
            return ToolResult.fail("Missing 'action' parameter. One of: cascade_update, invalidate_when, resolve_contradiction, propagate_correction, temporal_decay, survey.");

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
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Unknown action '{s}'. Valid: cascade_update, invalidate_when, resolve_contradiction, propagate_correction, temporal_decay, survey.", .{action});
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

        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"cascade_update\",\"found_old\":{s},\"edges_rewritten\":{d},\"edges_closed\":{d},\"next_consideration\":\"{s}\"}}",
            .{
                if (result.found_old) "true" else "false",
                result.edges_rewritten,
                result.edges_closed,
                next_consideration,
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

        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"invalidate_when\",\"predicate\":\"{s}\",\"object_name\":\"{s}\",\"edges_closed\":{d},\"next_consideration\":\"{s}\"}}",
            .{ predicate, object_name, closed, next_consideration },
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

        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"resolve_contradiction\",\"loser_existed\":{s},\"winner_existed\":{s},\"loser_closed\":{s},\"next_consideration\":\"{s}\"}}",
            .{
                if (result.loser_existed) "true" else "false",
                if (result.winner_existed) "true" else "false",
                if (result.loser_closed) "true" else "false",
                next_consideration,
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

        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"propagate_correction\",\"correction_existed\":{s},\"targets_flagged\":{d},\"target_keys\":{s},\"next_consideration\":\"{s}\"}}",
            .{
                if (result.correction_existed) "true" else "false",
                result.targets_flagged,
                keys_buf.items,
                next_consideration,
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

        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"temporal_decay\",\"threshold_days\":{d},\"half_life_days\":{d},\"rows_decayed\":{d},\"avg_decay_amount\":{d:.3},\"floor\":{d:.2},\"next_consideration\":\"{s}\"}}",
            .{
                threshold_days,
                half_life_days,
                result.rows_decayed,
                result.avg_decay_amount,
                result.floor,
                next_consideration,
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

        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"survey\",\"conflicts_found\":{d},\"sentinel_written\":{s},\"conflicts_json\":{s},\"next_consideration\":\"{s}\"}}",
            .{
                result.conflicts_found,
                if (result.sentinel_written) "true" else "false",
                result.conflicts_json,
                next_consideration,
            },
        );
        return ToolResult{ .success = true, .output = output };
    }
};
