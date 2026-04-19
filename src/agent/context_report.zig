const std = @import("std");
const config_types = @import("../config_types.zig");
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
        "Context: messages={d}, token_estimate={d}, tools={d}, memory_enriched={d}, last_turn_memory={s}",
        .{ report.history_messages, report.token_estimate, report.tool_count, report.memory_enriched_messages, boolWord(report.last_turn.memory_context_injected) },
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
        "summary_latest={s} anchor={s} durable={d} timeline={d} search={d} fallback={d} continuity_bucket={d}/{d} semantic_bucket={d}/{d} fallback_bucket={d}/{d} candidates={d} global_candidates={d}",
        .{
            boolWord(report.last_turn.memory_selection.summary_latest_used),
            boolWord(report.last_turn.memory_selection.context_anchor_used),
            report.last_turn.memory_selection.durable_fact_count,
            report.last_turn.memory_selection.timeline_summary_count,
            report.last_turn.memory_selection.search_match_count,
            report.last_turn.memory_selection.global_fallback_count,
            report.last_turn.memory_selection.continuity_bucket_entries,
            report.last_turn.memory_selection.continuity_bucket_bytes,
            report.last_turn.memory_selection.semantic_bucket_entries,
            report.last_turn.memory_selection.semantic_bucket_bytes,
            report.last_turn.memory_selection.fallback_bucket_entries,
            report.last_turn.memory_selection.fallback_bucket_bytes,
            report.last_turn.memory_selection.candidate_count,
            report.last_turn.memory_selection.global_candidate_count,
        },
    );
}

fn transcriptRetentionText(allocator: std.mem.Allocator, retention_days: ?u32) ![]u8 {
    const days = retention_days orelse return try allocator.dupe(u8, "n/a");
    if (days == 0) return try allocator.dupe(u8, "forever");
    return try std.fmt.allocPrint(allocator, "{d}d", .{days});
}

fn continuityRefreshReasonText(allocator: std.mem.Allocator, report: Report) ![]u8 {
    if (!report.last_turn.durable_continuity_refreshed) {
        return try allocator.dupe(u8, "n/a");
    }
    return try allocator.dupe(u8, "compaction:auto");
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
    const transcript_retention_text = try transcriptRetentionText(allocator, report.conversation_retention_days);
    defer allocator.free(transcript_retention_text);
    const continuity_refresh_reason_text = try continuityRefreshReasonText(allocator, report);
    defer allocator.free(continuity_refresh_reason_text);

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
    try std.fmt.format(w, "  policy: history_limit={d} token_compact_threshold={d} token_trigger={s}\n", .{
        report.history_trim_limit_messages,
        report.token_compaction_threshold,
        boolWord(report.token_compaction_triggered),
    });
    try std.fmt.format(w, "  reserve: reply={d} tool={d} safety={d} total={d}\n", .{
        report.token_reply_reserve,
        report.token_tool_reserve,
        report.token_safety_reserve,
        report.token_total_reserve,
    });
    try std.fmt.format(w, "  tools: {d}\n", .{report.tool_count});
    try std.fmt.format(w, "  by_role: system={d} user={d} assistant={d} tool={d}\n", .{
        report.role_counts.system,
        report.role_counts.user,
        report.role_counts.assistant,
        report.role_counts.tool,
    });
    try std.fmt.format(w, "  memory: enabled={s} runtime={s} session={s} enriched_messages={d} last_turn_injected={s}\n", .{
        boolWord(report.memory_enabled),
        boolWord(report.memory_runtime_enabled),
        memory_session_text,
        report.memory_enriched_messages,
        boolWord(report.last_turn.memory_context_injected),
    });
    try std.fmt.format(w, "  retrieval: mode={s} provider={s} vector={s} rollout={s}\n", .{
        report.retrieval_mode,
        report.embedding_provider,
        report.vector_mode,
        report.rollout_mode,
    });
    try w.writeAll("  continuity:\n");
    try std.fmt.format(w, "    hot: last_n={d} raw_only=yes\n", .{
        report.history_trim_limit_messages,
    });
    // W2.6: `recall_cap` is the intended per-turn cap (static). `search` below
    // is the actual delivered count on this turn. Keep them distinct in the
    // label so the operator can tell capacity from delivery at a glance.
    try std.fmt.format(w, "    warm: summary_latest={s} anchor={s} recall_cap={d} timeline_fallback_cap={d} durable={d} timeline={d} search={d} fallback={d} continuity_bucket={d}/{d} semantic_bucket={d}/{d} fallback_bucket={d}/{d}\n", .{
        boolWord(report.last_turn.memory_selection.summary_latest_used),
        boolWord(report.last_turn.memory_selection.context_anchor_used),
        config_types.DEFAULT_MEMORY_ENRICH_RECALL_LIMIT,
        config_types.DEFAULT_MEMORY_TIMELINE_FALLBACK_LIMIT,
        report.last_turn.memory_selection.durable_fact_count,
        report.last_turn.memory_selection.timeline_summary_count,
        report.last_turn.memory_selection.search_match_count,
        report.last_turn.memory_selection.global_fallback_count,
        report.last_turn.memory_selection.continuity_bucket_entries,
        report.last_turn.memory_selection.continuity_bucket_bytes,
        report.last_turn.memory_selection.semantic_bucket_entries,
        report.last_turn.memory_selection.semantic_bucket_bytes,
        report.last_turn.memory_selection.fallback_bucket_entries,
        report.last_turn.memory_selection.fallback_bucket_bytes,
    });
    try std.fmt.format(w, "    cold: tools=memory_recall,memory_timeline,memory_list discovery=timeline_index transcripts=autosave(exact_history) retention={s}\n", .{
        transcript_retention_text,
    });
    try std.fmt.format(w, "    durable_refresh: triggered={s} reason={s}\n", .{
        boolWord(report.last_turn.durable_continuity_refreshed),
        continuity_refresh_reason_text,
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
    try std.fmt.format(w, "  compaction: auto_events={d} auto_messages~={d} force_events={d} force_messages={d}\n", .{
        report.last_turn.auto_compaction_events,
        report.last_turn.auto_compacted_messages,
        report.last_turn.force_compression_events,
        report.last_turn.force_compressed_messages,
    });
    try std.fmt.format(w, "  memory_select: {s}", .{memory_selection_text});
    return try out.toOwnedSlice(allocator);
}

pub fn formatJson(allocator: std.mem.Allocator, report: Report) ![]u8 {
    const transcript_retention_text = try transcriptRetentionText(allocator, report.conversation_retention_days);
    defer allocator.free(transcript_retention_text);
    const continuity_refresh_reason_text = try continuityRefreshReasonText(allocator, report);
    defer allocator.free(continuity_refresh_reason_text);

    return try std.json.Stringify.valueAlloc(allocator, .{
        .model = report.model_name,
        .history_messages = report.history_messages,
        .token_estimate = report.token_estimate,
        .context_window_tokens = report.context_window_tokens,
        .context_pressure_percent = report.context_pressure_percent,
        .history_trim_limit_messages = report.history_trim_limit_messages,
        .token_compaction_threshold = report.token_compaction_threshold,
        .token_compaction_triggered = report.token_compaction_triggered,
        .token_reply_reserve = report.token_reply_reserve,
        .token_tool_reserve = report.token_tool_reserve,
        .token_safety_reserve = report.token_safety_reserve,
        .token_total_reserve = report.token_total_reserve,
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
            .conversation_retention_days = report.conversation_retention_days,
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
        .continuity = .{
            .hot = .{
                .last_n = report.history_trim_limit_messages,
                .raw_only = true,
            },
            .warm = .{
                .summary_latest = report.last_turn.memory_selection.summary_latest_used,
                .context_anchor = report.last_turn.memory_selection.context_anchor_used,
                .recall_limit = config_types.DEFAULT_MEMORY_ENRICH_RECALL_LIMIT,
                .timeline_fallback_limit = config_types.DEFAULT_MEMORY_TIMELINE_FALLBACK_LIMIT,
                .durable_facts = report.last_turn.memory_selection.durable_fact_count,
                .timeline_summaries = report.last_turn.memory_selection.timeline_summary_count,
                .search_matches = report.last_turn.memory_selection.search_match_count,
                .fallback_matches = report.last_turn.memory_selection.global_fallback_count,
                .continuity_bucket_entries = report.last_turn.memory_selection.continuity_bucket_entries,
                .continuity_bucket_bytes = report.last_turn.memory_selection.continuity_bucket_bytes,
                .semantic_bucket_entries = report.last_turn.memory_selection.semantic_bucket_entries,
                .semantic_bucket_bytes = report.last_turn.memory_selection.semantic_bucket_bytes,
                .fallback_bucket_entries = report.last_turn.memory_selection.fallback_bucket_entries,
                .fallback_bucket_bytes = report.last_turn.memory_selection.fallback_bucket_bytes,
            },
            .cold = .{
                .tools = .{ "memory_recall", "memory_timeline", "memory_list" },
                .transcripts = "autosave",
                .retention_mode = transcript_retention_text,
            },
            .durable_refresh = .{
                .triggered = report.last_turn.durable_continuity_refreshed,
                .reason = continuity_refresh_reason_text,
            },
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
            .auto_compaction_events = report.last_turn.auto_compaction_events,
            .auto_compacted_messages = report.last_turn.auto_compacted_messages,
            .force_compression_events = report.last_turn.force_compression_events,
            .force_compressed_messages = report.last_turn.force_compressed_messages,
            .durable_continuity_refreshed = report.last_turn.durable_continuity_refreshed,
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
                .continuity_bucket_entries = report.last_turn.memory_selection.continuity_bucket_entries,
                .continuity_bucket_bytes = report.last_turn.memory_selection.continuity_bucket_bytes,
                .semantic_bucket_entries = report.last_turn.memory_selection.semantic_bucket_entries,
                .semantic_bucket_bytes = report.last_turn.memory_selection.semantic_bucket_bytes,
                .fallback_bucket_entries = report.last_turn.memory_selection.fallback_bucket_entries,
                .fallback_bucket_bytes = report.last_turn.memory_selection.fallback_bucket_bytes,
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
        conversation_retention_days: u32,
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
            .conversation_retention_days = 0,
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
    try std.testing.expectEqual(@as(?u32, 0), report.conversation_retention_days);
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
        .history_trim_limit_messages = 80,
        .token_compaction_threshold = 650,
        .token_compaction_triggered = false,
        .token_reply_reserve = 300,
        .token_tool_reserve = 2048,
        .token_safety_reserve = 1024,
        .token_total_reserve = 3372,
        .tool_count = 3,
        .role_counts = .{ .system = 1, .user = 2, .assistant = 3, .tool = 1 },
        .memory_enabled = true,
        .memory_runtime_enabled = true,
        .memory_session_id = "agent:test:user:1:main",
        .conversation_retention_days = 0,
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
            .auto_compaction_events = 1,
            .auto_compacted_messages = 8,
            .force_compression_events = 1,
            .force_compressed_messages = 3,
            .durable_continuity_refreshed = true,
            .memory_selection = .{
                .available = true,
                .candidate_count = 5,
                .global_candidate_count = 12,
                .summary_latest_used = true,
                .context_anchor_used = false,
                .durable_fact_count = 1,
                .timeline_summary_count = 2,
                .search_match_count = 1,
                .global_fallback_count = 0,
                .continuity_bucket_entries = 1,
                .continuity_bucket_bytes = 12,
                .semantic_bucket_entries = 3,
                .semantic_bucket_bytes = 18,
                .fallback_bucket_entries = 0,
                .fallback_bucket_bytes = 0,
            },
        },
    };

    const summary = try formatSummary(std.testing.allocator, report);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "memory_enriched=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "last_turn_memory=yes") != null);

    const detail = try formatDetail(std.testing.allocator, report);
    defer std.testing.allocator.free(detail);
    try std.testing.expect(std.mem.indexOf(u8, detail, "budget: window=1000 pressure=32%") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "policy: history_limit=80 token_compact_threshold=650 token_trigger=no") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "reserve: reply=300 tool=2048 safety=1024 total=3372") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "memory: enabled=yes runtime=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "retrieval: mode=hybrid provider=together vector=pgvector rollout=on") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "hot: last_n=80 raw_only=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "warm: summary_latest=yes anchor=no recall_cap=10 timeline_fallback_cap=2 durable=1 timeline=2 search=1 fallback=0 continuity_bucket=1/12 semantic_bucket=3/18 fallback_bucket=0/0") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "cold: tools=memory_recall,memory_timeline,memory_list discovery=timeline_index transcripts=autosave(exact_history) retention=forever") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "durable_refresh: triggered=yes reason=compaction:auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "cache: stable_prefix=yes refresh_needed=yes reason=workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "stable_prefix: entries=1 bytes=128 tokens~=32 cache=stable") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "last_turn: prompt_refresh=yes reason=workspace memory_injected=yes bytes=64 enrich_ms=11 cache_hit=no") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "trim: events=1 removed_messages=2 removed_bytes=24 history_after=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "compaction: auto_events=1 auto_messages~=8 force_events=1 force_messages=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "memory_select: summary_latest=yes anchor=no durable=1 timeline=2 search=1 fallback=0 continuity_bucket=1/12 semantic_bucket=3/18 fallback_bucket=0/0 candidates=5 global_candidates=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "workspace_fp=77") != null);

    const json = try formatJson(std.testing.allocator, report);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stable_prefix\":{\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"buckets\":{\"stable_prefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context_pressure_percent\":32") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"token_compaction_threshold\":650") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"token_total_reserve\":3372") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enriched_messages\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"conversation_retention_days\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"embedding_provider\":\"together\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory_context_injected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trimmed_messages\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"auto_compaction_events\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"durable_continuity_refreshed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"retention_mode\":\"forever\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"summary_latest_used\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workspace_prompt_fingerprint\":77") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"semantic_bucket_entries\":3") != null);
}
