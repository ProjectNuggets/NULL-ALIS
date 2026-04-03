const std = @import("std");
const context_builder = @import("context_builder.zig");
const context_cache = @import("context_cache.zig");

pub const RoleCounts = context_builder.RoleCounts;
pub const Report = context_builder.Snapshot;

pub fn fromAgent(self: anytype) Report {
    return context_builder.buildSnapshot(self);
}

fn boolWord(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

pub fn formatSummary(allocator: std.mem.Allocator, report: Report) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Context: messages={d}, token_estimate={d}, tools={d}, memory_enriched={d}",
        .{ report.history_messages, report.token_estimate, report.tool_count, report.memory_enriched_messages },
    );
}

fn promptRefreshReasonText(allocator: std.mem.Allocator, report: Report) ![]u8 {
    if (!report.last_turn.available or !report.last_turn.prompt_refreshed) {
        return try allocator.dupe(u8, "n/a");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    var wrote = false;

    if (report.last_turn.workspace_prompt_changed) {
        try w.writeAll("workspace");
        wrote = true;
    }
    if (report.last_turn.time_bucket_changed) {
        if (wrote) try w.writeAll("+");
        try w.writeAll("clock");
        wrote = true;
    }
    if (report.last_turn.conversation_context_changed) {
        if (wrote) try w.writeAll("+");
        try w.writeAll("conversation");
        wrote = true;
    }
    if (!wrote) {
        try w.writeAll("cold_start");
    }
    return try out.toOwnedSlice(allocator);
}

fn stablePrefixRefreshReasonText(allocator: std.mem.Allocator, report: Report) ![]u8 {
    if (!report.stable_prefix_cache.refresh_needed) {
        return try allocator.dupe(u8, "n/a");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    var wrote = false;

    if (report.stable_prefix_cache.cold_start) {
        try w.writeAll("cold_start");
        wrote = true;
    }
    if (report.stable_prefix_cache.workspace_prompt_changed) {
        if (wrote) try w.writeAll("+");
        try w.writeAll("workspace");
        wrote = true;
    }
    if (report.stable_prefix_cache.time_bucket_changed) {
        if (wrote) try w.writeAll("+");
        try w.writeAll("clock");
        wrote = true;
    }
    if (report.stable_prefix_cache.conversation_context_changed) {
        if (wrote) try w.writeAll("+");
        try w.writeAll("conversation");
        wrote = true;
    }
    if (!wrote) {
        try w.writeAll("n/a");
    }
    return try out.toOwnedSlice(allocator);
}

fn memorySelectionText(allocator: std.mem.Allocator, report: Report) ![]u8 {
    if (!report.last_turn.memory_selection.available) {
        return try allocator.dupe(u8, "n/a");
    }

    return try std.fmt.allocPrint(
        allocator,
        "summary_latest={s} anchor={s} durable={d} timeline={d} search={d} fallback={d} candidates={d} global_candidates={d}",
        .{
            boolWord(report.last_turn.memory_selection.summary_latest_used),
            boolWord(report.last_turn.memory_selection.context_anchor_used),
            report.last_turn.memory_selection.durable_fact_count,
            report.last_turn.memory_selection.timeline_summary_count,
            report.last_turn.memory_selection.search_match_count,
            report.last_turn.memory_selection.global_fallback_count,
            report.last_turn.memory_selection.candidate_count,
            report.last_turn.memory_selection.global_candidate_count,
        },
    );
}

pub fn formatDetail(allocator: std.mem.Allocator, report: Report) ![]u8 {
    const workspace_fp_text = if (report.workspace_prompt_fingerprint) |fp|
        try std.fmt.allocPrint(allocator, "{d}", .{fp})
    else
        try allocator.dupe(u8, "n/a");
    defer allocator.free(workspace_fp_text);

    const memory_session_text = if (report.memory_session_id) |session_id|
        try allocator.dupe(u8, session_id)
    else
        try allocator.dupe(u8, "n/a");
    defer allocator.free(memory_session_text);

    const refresh_reason_text = try promptRefreshReasonText(allocator, report);
    defer allocator.free(refresh_reason_text);
    const stable_prefix_reason_text = try stablePrefixRefreshReasonText(allocator, report);
    defer allocator.free(stable_prefix_reason_text);
    const memory_selection_text = try memorySelectionText(allocator, report);
    defer allocator.free(memory_selection_text);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll("Context detail:\n");
    try std.fmt.format(w, "  model: {s}\n", .{report.model_name});
    try std.fmt.format(w, "  messages: {d}\n", .{report.history_messages});
    try std.fmt.format(w, "  token_estimate: {d}\n", .{report.token_estimate});
    try std.fmt.format(w, "  budget: window={d} pressure={d}%\n", .{
        report.context_window_tokens,
        report.context_pressure_percent,
    });
    try std.fmt.format(w, "  tools: {d}\n", .{report.tool_count});
    try std.fmt.format(w, "  by_role: system={d} user={d} assistant={d} tool={d}\n", .{
        report.role_counts.system,
        report.role_counts.user,
        report.role_counts.assistant,
        report.role_counts.tool,
    });
    try std.fmt.format(w, "  memory: enabled={s} runtime={s} session={s} enriched_messages={d}\n", .{
        boolWord(report.memory_enabled),
        boolWord(report.memory_runtime_enabled),
        memory_session_text,
        report.memory_enriched_messages,
    });
    try std.fmt.format(w, "  retrieval: mode={s} provider={s} vector={s} rollout={s}\n", .{
        report.retrieval_mode,
        report.embedding_provider,
        report.vector_mode,
        report.rollout_mode,
    });
    try std.fmt.format(w, "  prompt: has_system={s} conversation_context={s} workspace_fp={s}\n", .{
        boolWord(report.has_system_prompt),
        boolWord(report.has_conversation_context),
        workspace_fp_text,
    });
    try std.fmt.format(w, "  runtime: compact_context={s} compacted_last_turn={s}\n", .{
        boolWord(report.compact_context_enabled),
        boolWord(report.context_was_compacted),
    });
    try std.fmt.format(w, "  cache: stable_prefix={s} refresh_needed={s} reason={s}\n", .{
        boolWord(report.stable_prefix_cache.available),
        boolWord(report.stable_prefix_cache.refresh_needed),
        stable_prefix_reason_text,
    });
    try w.writeAll("  buckets:\n");
    try std.fmt.format(w, "    stable_prefix: entries={d} bytes={d} tokens~={d} cache={s}\n", .{
        report.buckets.stable_prefix.entries,
        report.buckets.stable_prefix.bytes,
        report.buckets.stable_prefix.token_estimate,
        context_cache.cacheabilityText(report.buckets.stable_prefix.cacheability),
    });
    try std.fmt.format(w, "    memory_context: entries={d} bytes={d} tokens~={d} cache={s}\n", .{
        report.buckets.memory_context.entries,
        report.buckets.memory_context.bytes,
        report.buckets.memory_context.token_estimate,
        context_cache.cacheabilityText(report.buckets.memory_context.cacheability),
    });
    try std.fmt.format(w, "    recent_history: entries={d} bytes={d} tokens~={d} cache={s}\n", .{
        report.buckets.recent_history.entries,
        report.buckets.recent_history.bytes,
        report.buckets.recent_history.token_estimate,
        context_cache.cacheabilityText(report.buckets.recent_history.cacheability),
    });
    try std.fmt.format(w, "    last_turn_runtime: active={s} bytes={d} tokens~={d} cache={s}\n", .{
        boolWord(report.buckets.last_turn_runtime.active),
        report.buckets.last_turn_runtime.bytes,
        report.buckets.last_turn_runtime.token_estimate,
        context_cache.cacheabilityText(report.buckets.last_turn_runtime.cacheability),
    });
    try std.fmt.format(w, "    conversation_context: active={s} embedded_in_prefix={s}\n", .{
        boolWord(report.buckets.conversation_context.active),
        boolWord(report.buckets.conversation_context.embedded_in_stable_prefix),
    });
    try std.fmt.format(w, "  last_turn: prompt_refresh={s} reason={s} memory_injected={s} bytes={d} enrich_ms={d} cache_hit={s}\n", .{
        boolWord(report.last_turn.prompt_refreshed),
        refresh_reason_text,
        boolWord(report.last_turn.memory_context_injected),
        report.last_turn.memory_context_bytes,
        report.last_turn.memory_enrich_ms,
        boolWord(report.last_turn.cache_hit),
    });
    try std.fmt.format(w, "  trim: events={d} removed_messages={d} removed_bytes={d} history_after={d}\n", .{
        report.last_turn.trim_events,
        report.last_turn.trimmed_messages,
        report.last_turn.trimmed_bytes,
        report.last_turn.history_messages_after_trim,
    });
    try std.fmt.format(w, "  memory_select: {s}", .{memory_selection_text});
    return try out.toOwnedSlice(allocator);
}

pub fn formatJson(allocator: std.mem.Allocator, report: Report) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{
        .model = report.model_name,
        .history_messages = report.history_messages,
        .token_estimate = report.token_estimate,
        .context_window_tokens = report.context_window_tokens,
        .context_pressure_percent = report.context_pressure_percent,
        .tools = report.tool_count,
        .roles = .{
            .system = report.role_counts.system,
            .user = report.role_counts.user,
            .assistant = report.role_counts.assistant,
            .tool = report.role_counts.tool,
        },
        .memory = .{
            .enabled = report.memory_enabled,
            .runtime = report.memory_runtime_enabled,
            .session_id = report.memory_session_id,
            .enriched_messages = report.memory_enriched_messages,
        },
        .prompt = .{
            .has_system = report.has_system_prompt,
            .conversation_context = report.has_conversation_context,
            .workspace_prompt_fingerprint = report.workspace_prompt_fingerprint,
        },
        .retrieval = .{
            .mode = report.retrieval_mode,
            .embedding_provider = report.embedding_provider,
            .vector_mode = report.vector_mode,
            .rollout = report.rollout_mode,
        },
        .cache = .{
            .stable_prefix = .{
                .available = report.stable_prefix_cache.available,
                .refresh_needed = report.stable_prefix_cache.refresh_needed,
                .cold_start = report.stable_prefix_cache.cold_start,
                .workspace_prompt_changed = report.stable_prefix_cache.workspace_prompt_changed,
                .time_bucket_changed = report.stable_prefix_cache.time_bucket_changed,
                .conversation_context_changed = report.stable_prefix_cache.conversation_context_changed,
                .workspace_fingerprint = report.stable_prefix_cache.workspace_fingerprint,
                .time_bucket_min = report.stable_prefix_cache.current_time_bucket_min,
            },
        },
        .buckets = .{
            .stable_prefix = .{
                .entries = report.buckets.stable_prefix.entries,
                .bytes = report.buckets.stable_prefix.bytes,
                .token_estimate = report.buckets.stable_prefix.token_estimate,
                .active = report.buckets.stable_prefix.active,
                .cacheability = @tagName(report.buckets.stable_prefix.cacheability),
            },
            .memory_context = .{
                .entries = report.buckets.memory_context.entries,
                .bytes = report.buckets.memory_context.bytes,
                .token_estimate = report.buckets.memory_context.token_estimate,
                .active = report.buckets.memory_context.active,
                .cacheability = @tagName(report.buckets.memory_context.cacheability),
            },
            .recent_history = .{
                .entries = report.buckets.recent_history.entries,
                .bytes = report.buckets.recent_history.bytes,
                .token_estimate = report.buckets.recent_history.token_estimate,
                .active = report.buckets.recent_history.active,
                .cacheability = @tagName(report.buckets.recent_history.cacheability),
            },
            .last_turn_runtime = .{
                .entries = report.buckets.last_turn_runtime.entries,
                .bytes = report.buckets.last_turn_runtime.bytes,
                .token_estimate = report.buckets.last_turn_runtime.token_estimate,
                .active = report.buckets.last_turn_runtime.active,
                .cacheability = @tagName(report.buckets.last_turn_runtime.cacheability),
            },
            .conversation_context = .{
                .active = report.buckets.conversation_context.active,
                .embedded_in_stable_prefix = report.buckets.conversation_context.embedded_in_stable_prefix,
                .fingerprint = report.buckets.conversation_context.fingerprint,
            },
        },
        .last_turn = .{
            .available = report.last_turn.available,
            .prompt_refreshed = report.last_turn.prompt_refreshed,
            .workspace_prompt_changed = report.last_turn.workspace_prompt_changed,
            .time_bucket_changed = report.last_turn.time_bucket_changed,
            .conversation_context_changed = report.last_turn.conversation_context_changed,
            .memory_context_injected = report.last_turn.memory_context_injected,
            .memory_context_bytes = report.last_turn.memory_context_bytes,
            .memory_enrich_ms = report.last_turn.memory_enrich_ms,
            .cache_hit = report.last_turn.cache_hit,
            .trim_events = report.last_turn.trim_events,
            .trimmed_messages = report.last_turn.trimmed_messages,
            .trimmed_bytes = report.last_turn.trimmed_bytes,
            .history_messages_after_trim = report.last_turn.history_messages_after_trim,
            .memory_selection = .{
                .available = report.last_turn.memory_selection.available,
                .candidate_count = report.last_turn.memory_selection.candidate_count,
                .global_candidate_count = report.last_turn.memory_selection.global_candidate_count,
                .summary_latest_used = report.last_turn.memory_selection.summary_latest_used,
                .context_anchor_used = report.last_turn.memory_selection.context_anchor_used,
                .durable_fact_count = report.last_turn.memory_selection.durable_fact_count,
                .timeline_summary_count = report.last_turn.memory_selection.timeline_summary_count,
                .search_match_count = report.last_turn.memory_selection.search_match_count,
                .global_fallback_count = report.last_turn.memory_selection.global_fallback_count,
            },
        },
        .runtime = .{
            .compact_context = report.compact_context_enabled,
            .compacted_last_turn = report.context_was_compacted,
        },
    }, .{});
}

test "context report counts roles and memory-enriched turns" {
    const FakeRole = enum { system, user, assistant, tool };
    const FakeMessage = struct {
        role: FakeRole,
        content: []const u8,
    };
    const FakeHistory = struct {
        items: []const FakeMessage,
    };
    const FakeTool = u8;
    const messages = [_]FakeMessage{
        .{ .role = .system, .content = "system prompt" },
        .{ .role = .user, .content = "[Memory context]\n- pref: concise\n\nhello" },
        .{ .role = .assistant, .content = "hi" },
        .{ .role = .tool, .content = "tool output" },
    };
    const tools = [_]FakeTool{ 1, 2 };
    const Resolved = struct {
        retrieval_mode: []const u8,
        embedding_provider: []const u8,
        vector_mode: []const u8,
        rollout_mode: []const u8,
    };
    const FakeMemoryRuntime = struct {
        resolved: Resolved,
    };
    var fake_mem_rt = FakeMemoryRuntime{
        .resolved = .{
            .retrieval_mode = "hybrid",
            .embedding_provider = "together",
            .vector_mode = "pgvector",
            .rollout_mode = "on",
        },
    };
    const fake = struct {
        model_name: []const u8,
        history: FakeHistory,
        tools: []const FakeTool,
        mem: ?u8,
        mem_rt: ?*FakeMemoryRuntime,
        memory_session_id: ?[]const u8,
        has_system_prompt: bool,
        conversation_context: ?u8,
        compact_context_enabled: bool,
        context_was_compacted: bool,
        workspace_prompt_fingerprint: ?u64,
    }{
        .mem_rt = &fake_mem_rt,
        .model_name = "openai/gpt-5.2",
        .history = .{ .items = &messages },
        .tools = &tools,
        .mem = 1,
        .memory_session_id = "agent:test:user:1:main",
        .has_system_prompt = true,
        .conversation_context = null,
        .compact_context_enabled = true,
        .context_was_compacted = false,
        .workspace_prompt_fingerprint = 42,
    };

    const report = fromAgent(&fake);
    try std.testing.expectEqual(@as(usize, 4), report.history_messages);
    try std.testing.expectEqual(@as(usize, 1), report.role_counts.system);
    try std.testing.expectEqual(@as(usize, 1), report.role_counts.user);
    try std.testing.expectEqual(@as(usize, 1), report.role_counts.assistant);
    try std.testing.expectEqual(@as(usize, 1), report.role_counts.tool);
    try std.testing.expectEqual(@as(usize, 1), report.memory_enriched_messages);
    try std.testing.expect(report.memory_enabled);
    try std.testing.expect(report.memory_runtime_enabled);
    try std.testing.expectEqualStrings("agent:test:user:1:main", report.memory_session_id.?);
    try std.testing.expectEqual(@as(?u64, 42), report.workspace_prompt_fingerprint);
    try std.testing.expectEqualStrings("together", report.embedding_provider);
    try std.testing.expectEqualStrings("pgvector", report.vector_mode);
    try std.testing.expectEqual(@as(usize, 1), report.buckets.stable_prefix.entries);
    try std.testing.expectEqual(@as(usize, 1), report.buckets.memory_context.entries);
}

test "context report formatters expose structured details" {
    const report = Report{
        .model_name = "openai/gpt-5.2",
        .history_messages = 7,
        .token_estimate = 321,
        .context_window_tokens = 1000,
        .context_pressure_percent = 32,
        .tool_count = 3,
        .role_counts = .{ .system = 1, .user = 2, .assistant = 3, .tool = 1 },
        .memory_enabled = true,
        .memory_runtime_enabled = true,
        .memory_session_id = "agent:test:user:1:main",
        .memory_enriched_messages = 2,
        .has_system_prompt = true,
        .has_conversation_context = false,
        .compact_context_enabled = true,
        .context_was_compacted = false,
        .workspace_prompt_fingerprint = 77,
        .retrieval_mode = "hybrid",
        .embedding_provider = "together",
        .vector_mode = "pgvector",
        .rollout_mode = "on",
        .stable_prefix_cache = .{
            .available = true,
            .refresh_needed = true,
            .workspace_prompt_changed = true,
            .workspace_fingerprint = 77,
            .current_time_bucket_min = 5,
        },
        .buckets = .{
            .stable_prefix = .{ .entries = 1, .bytes = 128, .token_estimate = 32, .active = true, .cacheability = .stable },
            .memory_context = .{ .entries = 2, .bytes = 64, .token_estimate = 16, .active = true, .cacheability = .dynamic },
            .recent_history = .{ .entries = 6, .bytes = 257, .token_estimate = 65, .active = true, .cacheability = .dynamic },
            .last_turn_runtime = .{ .entries = 1, .bytes = 64, .token_estimate = 16, .active = true, .cacheability = .per_turn },
            .conversation_context = .{ .active = false, .embedded_in_stable_prefix = false, .fingerprint = 0 },
        },
        .last_turn = .{
            .available = true,
            .prompt_refreshed = true,
            .workspace_prompt_changed = true,
            .time_bucket_changed = false,
            .conversation_context_changed = false,
            .memory_context_injected = true,
            .memory_context_bytes = 64,
            .memory_enrich_ms = 11,
            .cache_hit = false,
            .trim_events = 1,
            .trimmed_messages = 2,
            .trimmed_bytes = 24,
            .history_messages_after_trim = 5,
            .memory_selection = .{
                .available = true,
                .candidate_count = 5,
                .global_candidate_count = 12,
                .summary_latest_used = true,
                .context_anchor_used = true,
                .durable_fact_count = 1,
                .timeline_summary_count = 2,
                .search_match_count = 1,
                .global_fallback_count = 0,
            },
        },
    };

    const summary = try formatSummary(std.testing.allocator, report);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "memory_enriched=2") != null);

    const detail = try formatDetail(std.testing.allocator, report);
    defer std.testing.allocator.free(detail);
    try std.testing.expect(std.mem.indexOf(u8, detail, "budget: window=1000 pressure=32%") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "memory: enabled=yes runtime=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "retrieval: mode=hybrid provider=together vector=pgvector rollout=on") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "cache: stable_prefix=yes refresh_needed=yes reason=workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "stable_prefix: entries=1 bytes=128 tokens~=32 cache=stable") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "last_turn: prompt_refresh=yes reason=workspace memory_injected=yes bytes=64 enrich_ms=11 cache_hit=no") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "trim: events=1 removed_messages=2 removed_bytes=24 history_after=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "memory_select: summary_latest=yes anchor=yes durable=1 timeline=2 search=1 fallback=0 candidates=5 global_candidates=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "workspace_fp=77") != null);

    const json = try formatJson(std.testing.allocator, report);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stable_prefix\":{\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"buckets\":{\"stable_prefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context_pressure_percent\":32") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enriched_messages\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"embedding_provider\":\"together\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory_context_injected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trimmed_messages\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"summary_latest_used\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workspace_prompt_fingerprint\":77") != null);
}
