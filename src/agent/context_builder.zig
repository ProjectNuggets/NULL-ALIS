const std = @import("std");
const compaction = @import("compaction.zig");
const context_cache = @import("context_cache.zig");
const prompt = @import("prompt.zig");

pub const RoleCounts = struct {
    system: usize = 0,
    user: usize = 0,
    assistant: usize = 0,
    tool: usize = 0,
};

pub const Snapshot = struct {
    model_name: []const u8,
    history_messages: usize,
    token_estimate: u64,
    context_window_tokens: u64,
    context_pressure_percent: u8,
    history_trim_limit_messages: u32,
    token_compaction_threshold: u64,
    token_compaction_triggered: bool,
    token_reply_reserve: u64,
    token_tool_reserve: u64,
    token_safety_reserve: u64,
    token_total_reserve: u64,
    tool_count: usize,
    role_counts: RoleCounts,
    memory_enabled: bool,
    memory_runtime_enabled: bool,
    memory_session_id: ?[]const u8,
    memory_enriched_messages: usize,
    has_system_prompt: bool,
    has_conversation_context: bool,
    compact_context_enabled: bool,
    context_was_compacted: bool,
    workspace_prompt_fingerprint: ?u64,
    retrieval_mode: []const u8,
    embedding_provider: []const u8,
    vector_mode: []const u8,
    rollout_mode: []const u8,
    stable_prefix_cache: context_cache.StablePrefixState = .{},
    buckets: context_cache.BucketSet = .{},
    last_turn: LastTurnContext = .{},
};

pub const LastTurnContext = struct {
    available: bool = false,
    prompt_refreshed: bool = false,
    workspace_prompt_changed: bool = false,
    time_bucket_changed: bool = false,
    conversation_context_changed: bool = false,
    memory_context_injected: bool = false,
    memory_context_bytes: usize = 0,
    memory_enrich_ms: u64 = 0,
    cache_hit: bool = false,
    trim_events: usize = 0,
    trimmed_messages: usize = 0,
    trimmed_bytes: usize = 0,
    history_messages_after_trim: usize = 0,
    auto_compaction_events: usize = 0,
    auto_compacted_messages: usize = 0,
    force_compression_events: usize = 0,
    force_compressed_messages: usize = 0,
    memory_selection: MemorySelection = .{},
};

pub const MemorySelection = struct {
    available: bool = false,
    candidate_count: usize = 0,
    global_candidate_count: usize = 0,
    summary_latest_used: bool = false,
    context_anchor_used: bool = false,
    durable_fact_count: usize = 0,
    timeline_summary_count: usize = 0,
    search_match_count: usize = 0,
    global_fallback_count: usize = 0,
};

pub const PromptRefreshPlan = struct {
    current_time_bucket_min: i64,
    workspace_prompt_fingerprint: ?u64,
    conversation_context_present: bool,
    conversation_context_fingerprint: u64,
    workspace_prompt_changed: bool,
    time_bucket_changed: bool,
    conversation_context_changed: bool,
    should_refresh_system_prompt: bool,
};

fn hasMemoryContextPrefix(content: []const u8) bool {
    return std.mem.startsWith(u8, content, "[Memory context]\n");
}

fn memoryContextPrefixBytes(content: []const u8) usize {
    if (!hasMemoryContextPrefix(content)) return 0;
    if (std.mem.indexOf(u8, content, "\n\n")) |sep_idx| {
        return sep_idx + 2;
    }
    return content.len;
}

fn tokenEstimateFromHistory(history: anytype) u64 {
    var total_chars: u64 = 0;
    for (history.items) |entry| {
        total_chars += entry.content.len;
    }
    return (total_chars + 3) / 4;
}

fn tokenEstimateFromBytes(bytes: usize) u64 {
    return (@as(u64, @intCast(bytes)) + 3) / 4;
}

fn pressurePercent(used_tokens: u64, context_window_tokens: u64) u8 {
    if (context_window_tokens == 0) return 0;
    const pct = @min(@as(u64, 100), (used_tokens * 100) / context_window_tokens);
    return @intCast(pct);
}

fn conversationContextFingerprintFromAgent(self: anytype) u64 {
    const AgentType = @TypeOf(self.*);
    if (!@hasField(AgentType, "conversation_context")) return conversationContextFingerprint(null);
    if (@TypeOf(self.conversation_context) == ?prompt.ConversationContext) {
        return conversationContextFingerprint(self.conversation_context);
    }
    return conversationContextFingerprint(null);
}

pub fn conversationContextFingerprint(ctx: ?prompt.ConversationContext) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    if (ctx) |cc| {
        hasher.update("present");
        if (cc.channel) |channel| {
            hasher.update("channel:");
            hasher.update(channel);
        }
        if (cc.sender_number) |sender_number| {
            hasher.update("sender_number:");
            hasher.update(sender_number);
        }
        if (cc.sender_uuid) |sender_uuid| {
            hasher.update("sender_uuid:");
            hasher.update(sender_uuid);
        }
        if (cc.group_id) |group_id| {
            hasher.update("group_id:");
            hasher.update(group_id);
        }
        if (cc.is_group) |is_group| {
            hasher.update("is_group:");
            const b: u8 = if (is_group) 1 else 0;
            hasher.update(&[_]u8{b});
        }
    } else {
        hasher.update("absent");
    }
    return hasher.final();
}

pub fn buildSnapshot(self: anytype) Snapshot {
    const AgentType = @TypeOf(self.*);

    var role_counts = RoleCounts{};
    var memory_enriched_messages: usize = 0;
    var stable_prefix_entries: usize = 0;
    var stable_prefix_bytes: usize = 0;
    var memory_context_bytes: usize = 0;
    var recent_history_entries: usize = 0;
    var recent_history_bytes: usize = 0;

    if (@hasField(AgentType, "history")) {
        for (self.history.items) |entry| {
            switch (entry.role) {
                .system => {
                    role_counts.system += 1;
                    stable_prefix_entries += 1;
                    stable_prefix_bytes += entry.content.len;
                },
                .user => {
                    role_counts.user += 1;
                    recent_history_entries += 1;
                    const memory_prefix_bytes = memoryContextPrefixBytes(entry.content);
                    if (memory_prefix_bytes > 0) {
                        memory_enriched_messages += 1;
                        memory_context_bytes += memory_prefix_bytes;
                    }
                    recent_history_bytes += entry.content.len - @min(entry.content.len, memory_prefix_bytes);
                },
                .assistant => {
                    role_counts.assistant += 1;
                    recent_history_entries += 1;
                    recent_history_bytes += entry.content.len;
                },
                .tool => {
                    role_counts.tool += 1;
                    recent_history_entries += 1;
                    recent_history_bytes += entry.content.len;
                },
            }
        }
    }

    const has_system_prompt = if (@hasField(AgentType, "has_system_prompt")) self.has_system_prompt else role_counts.system > 0;
    const has_conversation_context = if (@hasField(AgentType, "conversation_context")) self.conversation_context != null else false;
    const conversation_context_fingerprint = conversationContextFingerprintFromAgent(self);
    const system_prompt_has_conversation_context = if (@hasField(AgentType, "system_prompt_has_conversation_context"))
        self.system_prompt_has_conversation_context
    else
        has_system_prompt and has_conversation_context;
    const prompt_refresh_plan = if (@hasField(AgentType, "has_system_prompt"))
        buildPromptRefreshPlan(self)
    else
        PromptRefreshPlan{
            .current_time_bucket_min = -1,
            .workspace_prompt_fingerprint = null,
            .conversation_context_present = has_conversation_context,
            .conversation_context_fingerprint = conversation_context_fingerprint,
            .workspace_prompt_changed = false,
            .time_bucket_changed = false,
            .conversation_context_changed = false,
            .should_refresh_system_prompt = !has_system_prompt,
        };
    const stable_prefix_cache = context_cache.buildStablePrefixState(prompt_refresh_plan, has_system_prompt);
    const last_turn = if (@hasField(AgentType, "last_turn_context")) self.last_turn_context else LastTurnContext{};
    const memory_context_entries = memory_enriched_messages;
    const token_estimate = if (@hasField(AgentType, "history")) tokenEstimateFromHistory(self.history) else 0;
    const context_window_tokens = if (@hasField(AgentType, "token_limit")) self.token_limit else 0;
    const resolved_max_tokens = if (@hasField(AgentType, "max_tokens")) self.max_tokens else 0;
    const token_budget_policy = compaction.buildTokenBudgetPolicy(context_window_tokens, resolved_max_tokens);

    return .{
        .model_name = if (@hasField(AgentType, "model_name")) self.model_name else "",
        .history_messages = if (@hasField(AgentType, "history")) self.history.items.len else 0,
        .token_estimate = token_estimate,
        .context_window_tokens = context_window_tokens,
        .context_pressure_percent = pressurePercent(token_estimate, context_window_tokens),
        .history_trim_limit_messages = if (@hasField(AgentType, "max_history_messages")) self.max_history_messages else 0,
        .token_compaction_threshold = token_budget_policy.threshold,
        .token_compaction_triggered = token_budget_policy.threshold > 0 and token_estimate > token_budget_policy.threshold,
        .token_reply_reserve = token_budget_policy.reply_reserve,
        .token_tool_reserve = token_budget_policy.tool_reserve,
        .token_safety_reserve = token_budget_policy.safety_reserve,
        .token_total_reserve = token_budget_policy.total_reserve,
        .tool_count = if (@hasField(AgentType, "tools")) self.tools.len else 0,
        .role_counts = role_counts,
        .memory_enabled = if (@hasField(AgentType, "mem")) self.mem != null else false,
        .memory_runtime_enabled = if (@hasField(AgentType, "mem_rt")) self.mem_rt != null else false,
        .memory_session_id = if (@hasField(AgentType, "memory_session_id")) self.memory_session_id else null,
        .memory_enriched_messages = memory_enriched_messages,
        .has_system_prompt = has_system_prompt,
        .has_conversation_context = has_conversation_context,
        .compact_context_enabled = if (@hasField(AgentType, "compact_context_enabled")) self.compact_context_enabled else false,
        .context_was_compacted = if (@hasField(AgentType, "context_was_compacted")) self.context_was_compacted else false,
        .workspace_prompt_fingerprint = if (@hasField(AgentType, "workspace_prompt_fingerprint")) self.workspace_prompt_fingerprint else null,
        .retrieval_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.retrieval_mode else "n/a",
        .embedding_provider = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.embedding_provider else "n/a",
        .vector_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.vector_mode else "n/a",
        .rollout_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.rollout_mode else "n/a",
        .stable_prefix_cache = stable_prefix_cache,
        .buckets = .{
            .stable_prefix = .{
                .entries = stable_prefix_entries,
                .bytes = stable_prefix_bytes,
                .token_estimate = tokenEstimateFromBytes(stable_prefix_bytes),
                .active = stable_prefix_entries > 0,
                .cacheability = .stable,
            },
            .memory_context = .{
                .entries = memory_context_entries,
                .bytes = memory_context_bytes,
                .token_estimate = tokenEstimateFromBytes(memory_context_bytes),
                .active = memory_context_entries > 0,
                .cacheability = .dynamic,
            },
            .recent_history = .{
                .entries = recent_history_entries,
                .bytes = recent_history_bytes,
                .token_estimate = tokenEstimateFromBytes(recent_history_bytes),
                .active = recent_history_entries > 0,
                .cacheability = .dynamic,
            },
            .last_turn_runtime = .{
                .entries = if (last_turn.available) 1 else 0,
                .bytes = last_turn.memory_context_bytes + last_turn.trimmed_bytes,
                .token_estimate = tokenEstimateFromBytes(last_turn.memory_context_bytes + last_turn.trimmed_bytes),
                .active = last_turn.available,
                .cacheability = .per_turn,
            },
            .conversation_context = .{
                .active = has_conversation_context,
                .embedded_in_stable_prefix = system_prompt_has_conversation_context,
                .fingerprint = conversation_context_fingerprint,
            },
        },
        .last_turn = last_turn,
    };
}

pub fn buildPromptRefreshPlan(self: anytype) PromptRefreshPlan {
    const AgentType = @TypeOf(self.*);
    const current_time_bucket_min = @divFloor(std.time.timestamp(), 60);
    const workspace_prompt_fingerprint = if (@hasField(AgentType, "allocator") and @hasField(AgentType, "workspace_dir"))
        prompt.workspacePromptFingerprint(self.allocator, self.workspace_dir) catch null
    else
        null;
    const has_system_prompt = if (@hasField(AgentType, "has_system_prompt")) self.has_system_prompt else false;
    const workspace_prompt_changed = has_system_prompt and
        workspace_prompt_fingerprint != null and
        @hasField(AgentType, "workspace_prompt_fingerprint") and
        self.workspace_prompt_fingerprint != workspace_prompt_fingerprint;
    const time_bucket_changed = has_system_prompt and
        @hasField(AgentType, "system_prompt_time_bucket_min") and
        self.system_prompt_time_bucket_min != current_time_bucket_min;
    const conversation_context_present = @hasField(AgentType, "conversation_context") and self.conversation_context != null;
    const conversation_context_fingerprint = conversationContextFingerprintFromAgent(self);
    const conversation_context_changed = has_system_prompt and
        @hasField(AgentType, "system_prompt_conversation_context_fingerprint") and
        self.system_prompt_conversation_context_fingerprint != conversation_context_fingerprint;

    return .{
        .current_time_bucket_min = current_time_bucket_min,
        .workspace_prompt_fingerprint = workspace_prompt_fingerprint,
        .conversation_context_present = conversation_context_present,
        .conversation_context_fingerprint = conversation_context_fingerprint,
        .workspace_prompt_changed = workspace_prompt_changed,
        .time_bucket_changed = time_bucket_changed,
        .conversation_context_changed = conversation_context_changed,
        .should_refresh_system_prompt = !has_system_prompt or workspace_prompt_changed or time_bucket_changed or conversation_context_changed,
    };
}

pub fn buildLastTurnContext(
    plan: PromptRefreshPlan,
    memory_stats: anytype,
    memory_enrich_ms: u64,
) LastTurnContext {
    return .{
        .available = true,
        .prompt_refreshed = plan.should_refresh_system_prompt,
        .workspace_prompt_changed = plan.workspace_prompt_changed,
        .time_bucket_changed = plan.time_bucket_changed,
        .conversation_context_changed = plan.conversation_context_changed,
        .memory_context_injected = memory_stats.injected,
        .memory_context_bytes = memory_stats.context_bytes,
        .memory_enrich_ms = memory_enrich_ms,
        .cache_hit = false,
        .history_messages_after_trim = 0,
        .memory_selection = selectionFromStats(memory_stats),
    };
}

pub fn recordTrimStats(last_turn: *LastTurnContext, trim_stats: anytype) void {
    if (!last_turn.available) return;
    if (trim_stats.removed_messages == 0 and trim_stats.removed_bytes == 0 and trim_stats.history_after == trim_stats.history_before) return;

    last_turn.trim_events += 1;
    last_turn.trimmed_messages += trim_stats.removed_messages;
    last_turn.trimmed_bytes += trim_stats.removed_bytes;
    last_turn.history_messages_after_trim = trim_stats.history_after;
}

pub fn recordAutoCompaction(last_turn: *LastTurnContext, history_before: usize, history_after: usize) void {
    if (!last_turn.available or history_before <= history_after) return;
    last_turn.auto_compaction_events += 1;
    last_turn.auto_compacted_messages += (history_before - history_after) + 1;
    last_turn.history_messages_after_trim = history_after;
}

pub fn recordForceCompression(last_turn: *LastTurnContext, history_before: usize, history_after: usize) void {
    if (!last_turn.available or history_before <= history_after) return;
    last_turn.force_compression_events += 1;
    last_turn.force_compressed_messages += history_before - history_after;
    last_turn.history_messages_after_trim = history_after;
}

pub fn selectionFromStats(stats: anytype) MemorySelection {
    return .{
        .available = stats.available,
        .candidate_count = stats.candidate_count,
        .global_candidate_count = stats.global_candidate_count,
        .summary_latest_used = stats.summary_latest_used,
        .context_anchor_used = stats.context_anchor_used,
        .durable_fact_count = stats.durable_fact_count,
        .timeline_summary_count = stats.timeline_summary_count,
        .search_match_count = stats.search_match_count,
        .global_fallback_count = stats.global_fallback_count,
    };
}

test "buildSnapshot counts roles and retrieval state" {
    const FakeRole = enum { system, user, assistant, tool };
    const FakeMessage = struct {
        role: FakeRole,
        content: []const u8,
    };
    const FakeHistory = struct {
        items: []const FakeMessage,
    };
    const FakeTool = u8;
    const Resolved = struct {
        retrieval_mode: []const u8,
        embedding_provider: []const u8,
        vector_mode: []const u8,
        rollout_mode: []const u8,
    };
    const FakeMemoryRuntime = struct {
        resolved: Resolved,
    };
    const messages = [_]FakeMessage{
        .{ .role = .system, .content = "system prompt" },
        .{ .role = .user, .content = "[Memory context]\n- pref: concise\n\nhello" },
        .{ .role = .assistant, .content = "hi" },
        .{ .role = .tool, .content = "tool output" },
    };
    const tools = [_]FakeTool{ 1, 2 };
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
        token_limit: u64,
        max_tokens: u32,
        max_history_messages: u32,
        memory_session_id: ?[]const u8,
        conversation_context: ?u8,
        compact_context_enabled: bool,
        context_was_compacted: bool,
        has_system_prompt: bool,
        system_prompt_has_conversation_context: bool,
        system_prompt_time_bucket_min: i64,
        system_prompt_conversation_context_fingerprint: u64,
        workspace_prompt_fingerprint: ?u64,
    }{
        .model_name = "openai/gpt-5.2",
        .history = .{ .items = &messages },
        .tools = &tools,
        .mem = 1,
        .mem_rt = &fake_mem_rt,
        .token_limit = 1_000,
        .max_tokens = 300,
        .max_history_messages = 50,
        .memory_session_id = "agent:test:user:1:main",
        .conversation_context = null,
        .compact_context_enabled = true,
        .context_was_compacted = false,
        .has_system_prompt = true,
        .system_prompt_has_conversation_context = false,
        .system_prompt_time_bucket_min = -1,
        .system_prompt_conversation_context_fingerprint = 0,
        .workspace_prompt_fingerprint = 42,
    };

    const snapshot = buildSnapshot(&fake);
    try std.testing.expectEqual(@as(usize, 4), snapshot.history_messages);
    try std.testing.expectEqual(@as(usize, 1), snapshot.memory_enriched_messages);
    try std.testing.expectEqual(@as(u8, 1), snapshot.context_pressure_percent);
    try std.testing.expectEqual(@as(u32, 50), snapshot.history_trim_limit_messages);
    try std.testing.expectEqual(@as(u64, 650), snapshot.token_compaction_threshold);
    try std.testing.expect(!snapshot.token_compaction_triggered);
    try std.testing.expectEqual(@as(u64, 300), snapshot.token_reply_reserve);
    try std.testing.expectEqual(@as(u64, 2_048), snapshot.token_tool_reserve);
    try std.testing.expectEqual(@as(u64, 1_024), snapshot.token_safety_reserve);
    try std.testing.expectEqual(@as(u64, 3_372), snapshot.token_total_reserve);
    try std.testing.expectEqualStrings("together", snapshot.embedding_provider);
    try std.testing.expectEqualStrings("pgvector", snapshot.vector_mode);
    try std.testing.expect(snapshot.has_system_prompt);
    try std.testing.expectEqual(@as(?u64, 42), snapshot.workspace_prompt_fingerprint);
    try std.testing.expectEqual(@as(usize, 1), snapshot.buckets.stable_prefix.entries);
    try std.testing.expectEqual(@as(usize, 13), snapshot.buckets.stable_prefix.bytes);
    try std.testing.expectEqual(@as(u64, 4), snapshot.buckets.stable_prefix.token_estimate);
    try std.testing.expectEqual(@as(usize, 1), snapshot.buckets.memory_context.entries);
    try std.testing.expectEqual(@as(usize, 34), snapshot.buckets.memory_context.bytes);
    try std.testing.expectEqual(@as(u64, 9), snapshot.buckets.memory_context.token_estimate);
    try std.testing.expectEqual(@as(usize, 3), snapshot.buckets.recent_history.entries);
    try std.testing.expectEqual(@as(usize, 18), snapshot.buckets.recent_history.bytes);
    try std.testing.expectEqual(@as(u64, 5), snapshot.buckets.recent_history.token_estimate);
    try std.testing.expect(snapshot.stable_prefix_cache.available);
}

test "buildPromptRefreshPlan refreshes missing system prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fake = struct {
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
        has_system_prompt: bool,
        workspace_prompt_fingerprint: ?u64,
        system_prompt_time_bucket_min: i64,
        conversation_context: ?prompt.ConversationContext,
        system_prompt_conversation_context_fingerprint: u64,
    }{
        .allocator = std.testing.allocator,
        .workspace_dir = tmp.dir.realpathAlloc(std.testing.allocator, ".") catch unreachable,
        .has_system_prompt = false,
        .workspace_prompt_fingerprint = null,
        .system_prompt_time_bucket_min = -1,
        .conversation_context = null,
        .system_prompt_conversation_context_fingerprint = 0,
    };
    defer std.testing.allocator.free(fake.workspace_dir);

    const plan = buildPromptRefreshPlan(&fake);
    try std.testing.expect(plan.should_refresh_system_prompt);
    try std.testing.expect(!plan.conversation_context_present);
}

test "buildPromptRefreshPlan detects clock and conversation changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const current_ctx: prompt.ConversationContext = .{
        .channel = "signal",
        .sender_uuid = "user-1",
        .is_group = false,
    };
    const stale_bucket = @divFloor(std.time.timestamp(), 60) - 5;
    const fake = struct {
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
        has_system_prompt: bool,
        workspace_prompt_fingerprint: ?u64,
        system_prompt_time_bucket_min: i64,
        conversation_context: ?prompt.ConversationContext,
        system_prompt_conversation_context_fingerprint: u64,
    }{
        .allocator = std.testing.allocator,
        .workspace_dir = tmp.dir.realpathAlloc(std.testing.allocator, ".") catch unreachable,
        .has_system_prompt = true,
        .workspace_prompt_fingerprint = 0,
        .system_prompt_time_bucket_min = stale_bucket,
        .conversation_context = current_ctx,
        .system_prompt_conversation_context_fingerprint = 0,
    };
    defer std.testing.allocator.free(fake.workspace_dir);

    const plan = buildPromptRefreshPlan(&fake);
    try std.testing.expect(plan.time_bucket_changed);
    try std.testing.expect(plan.conversation_context_changed);
    try std.testing.expect(plan.should_refresh_system_prompt);
}

test "buildLastTurnContext captures injected memory bytes" {
    const plan = PromptRefreshPlan{
        .current_time_bucket_min = 1,
        .workspace_prompt_fingerprint = 7,
        .conversation_context_present = false,
        .conversation_context_fingerprint = 0,
        .workspace_prompt_changed = true,
        .time_bucket_changed = false,
        .conversation_context_changed = false,
        .should_refresh_system_prompt = true,
    };

    const stats = struct {
        available: bool,
        candidate_count: usize,
        global_candidate_count: usize,
        summary_latest_used: bool,
        context_anchor_used: bool,
        durable_fact_count: usize,
        timeline_summary_count: usize,
        search_match_count: usize,
        global_fallback_count: usize,
        context_bytes: usize,
        injected: bool,
    }{
        .available = true,
        .candidate_count = 5,
        .global_candidate_count = 12,
        .summary_latest_used = true,
        .context_anchor_used = true,
        .durable_fact_count = 1,
        .timeline_summary_count = 2,
        .search_match_count = 1,
        .global_fallback_count = 0,
        .context_bytes = 34,
        .injected = true,
    };
    const last_turn = buildLastTurnContext(
        plan,
        stats,
        12,
    );

    try std.testing.expect(last_turn.available);
    try std.testing.expect(last_turn.prompt_refreshed);
    try std.testing.expect(last_turn.workspace_prompt_changed);
    try std.testing.expect(last_turn.memory_context_injected);
    try std.testing.expectEqual(@as(usize, 34), last_turn.memory_context_bytes);
    try std.testing.expectEqual(@as(u64, 12), last_turn.memory_enrich_ms);
    try std.testing.expect(!last_turn.cache_hit);
    try std.testing.expect(last_turn.memory_selection.summary_latest_used);
    try std.testing.expect(last_turn.memory_selection.context_anchor_used);
    try std.testing.expectEqual(@as(usize, 2), last_turn.memory_selection.timeline_summary_count);
}

test "recordTrimStats accumulates removed history" {
    var last_turn = LastTurnContext{
        .available = true,
    };

    recordTrimStats(&last_turn, .{
        .history_before = 8,
        .history_after = 5,
        .removed_messages = 3,
        .removed_bytes = 42,
    });
    recordTrimStats(&last_turn, .{
        .history_before = 6,
        .history_after = 5,
        .removed_messages = 1,
        .removed_bytes = 10,
    });

    try std.testing.expectEqual(@as(usize, 2), last_turn.trim_events);
    try std.testing.expectEqual(@as(usize, 4), last_turn.trimmed_messages);
    try std.testing.expectEqual(@as(usize, 52), last_turn.trimmed_bytes);
    try std.testing.expectEqual(@as(usize, 5), last_turn.history_messages_after_trim);
}

test "record compaction events updates last turn lifecycle" {
    var last_turn = LastTurnContext{
        .available = true,
    };

    recordAutoCompaction(&last_turn, 15, 8);
    recordForceCompression(&last_turn, 8, 5);

    try std.testing.expectEqual(@as(usize, 1), last_turn.auto_compaction_events);
    try std.testing.expectEqual(@as(usize, 8), last_turn.auto_compacted_messages);
    try std.testing.expectEqual(@as(usize, 1), last_turn.force_compression_events);
    try std.testing.expectEqual(@as(usize, 3), last_turn.force_compressed_messages);
    try std.testing.expectEqual(@as(usize, 5), last_turn.history_messages_after_trim);
}
