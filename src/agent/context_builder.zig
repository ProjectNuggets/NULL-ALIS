const std = @import("std");
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

fn tokenEstimateFromHistory(history: anytype) u64 {
    var total_chars: u64 = 0;
    for (history.items) |entry| {
        total_chars += entry.content.len;
    }
    return (total_chars + 3) / 4;
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

    if (@hasField(AgentType, "history")) {
        for (self.history.items) |entry| {
            switch (entry.role) {
                .system => role_counts.system += 1,
                .user => {
                    role_counts.user += 1;
                    if (hasMemoryContextPrefix(entry.content)) memory_enriched_messages += 1;
                },
                .assistant => role_counts.assistant += 1,
                .tool => role_counts.tool += 1,
            }
        }
    }

    return .{
        .model_name = if (@hasField(AgentType, "model_name")) self.model_name else "",
        .history_messages = if (@hasField(AgentType, "history")) self.history.items.len else 0,
        .token_estimate = if (@hasField(AgentType, "history")) tokenEstimateFromHistory(self.history) else 0,
        .tool_count = if (@hasField(AgentType, "tools")) self.tools.len else 0,
        .role_counts = role_counts,
        .memory_enabled = if (@hasField(AgentType, "mem")) self.mem != null else false,
        .memory_runtime_enabled = if (@hasField(AgentType, "mem_rt")) self.mem_rt != null else false,
        .memory_session_id = if (@hasField(AgentType, "memory_session_id")) self.memory_session_id else null,
        .memory_enriched_messages = memory_enriched_messages,
        .has_system_prompt = if (@hasField(AgentType, "has_system_prompt")) self.has_system_prompt else role_counts.system > 0,
        .has_conversation_context = if (@hasField(AgentType, "conversation_context")) self.conversation_context != null else false,
        .compact_context_enabled = if (@hasField(AgentType, "compact_context_enabled")) self.compact_context_enabled else false,
        .context_was_compacted = if (@hasField(AgentType, "context_was_compacted")) self.context_was_compacted else false,
        .workspace_prompt_fingerprint = if (@hasField(AgentType, "workspace_prompt_fingerprint")) self.workspace_prompt_fingerprint else null,
        .retrieval_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.retrieval_mode else "n/a",
        .embedding_provider = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.embedding_provider else "n/a",
        .vector_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.vector_mode else "n/a",
        .rollout_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.rollout_mode else "n/a",
        .last_turn = if (@hasField(AgentType, "last_turn_context")) self.last_turn_context else .{},
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
    const conversation_context_fingerprint = if (@hasField(AgentType, "conversation_context"))
        conversationContextFingerprint(self.conversation_context)
    else
        conversationContextFingerprint(null);
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
    user_message: []const u8,
    enriched_message: []const u8,
    memory_enrich_ms: u64,
) LastTurnContext {
    const memory_context_injected = std.mem.startsWith(u8, enriched_message, "[Memory context]\n") and
        enriched_message.len >= user_message.len and
        std.mem.endsWith(u8, enriched_message, user_message);
    const memory_context_bytes = if (memory_context_injected) enriched_message.len - user_message.len else 0;

    return .{
        .available = true,
        .prompt_refreshed = plan.should_refresh_system_prompt,
        .workspace_prompt_changed = plan.workspace_prompt_changed,
        .time_bucket_changed = plan.time_bucket_changed,
        .conversation_context_changed = plan.conversation_context_changed,
        .memory_context_injected = memory_context_injected,
        .memory_context_bytes = memory_context_bytes,
        .memory_enrich_ms = memory_enrich_ms,
        .cache_hit = false,
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
        memory_session_id: ?[]const u8,
        conversation_context: ?u8,
        compact_context_enabled: bool,
        context_was_compacted: bool,
        has_system_prompt: bool,
        workspace_prompt_fingerprint: ?u64,
    }{
        .model_name = "openai/gpt-5.2",
        .history = .{ .items = &messages },
        .tools = &tools,
        .mem = 1,
        .mem_rt = &fake_mem_rt,
        .memory_session_id = "agent:test:user:1:main",
        .conversation_context = null,
        .compact_context_enabled = true,
        .context_was_compacted = false,
        .has_system_prompt = true,
        .workspace_prompt_fingerprint = 42,
    };

    const snapshot = buildSnapshot(&fake);
    try std.testing.expectEqual(@as(usize, 4), snapshot.history_messages);
    try std.testing.expectEqual(@as(usize, 1), snapshot.memory_enriched_messages);
    try std.testing.expectEqualStrings("together", snapshot.embedding_provider);
    try std.testing.expectEqualStrings("pgvector", snapshot.vector_mode);
    try std.testing.expect(snapshot.has_system_prompt);
    try std.testing.expectEqual(@as(?u64, 42), snapshot.workspace_prompt_fingerprint);
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

    const user_message = "actual user request";
    const enriched_message = "[Memory context]\n- pref: concise\n\nactual user request";
    const last_turn = buildLastTurnContext(
        plan,
        user_message,
        enriched_message,
        12,
    );

    try std.testing.expect(last_turn.available);
    try std.testing.expect(last_turn.prompt_refreshed);
    try std.testing.expect(last_turn.workspace_prompt_changed);
    try std.testing.expect(last_turn.memory_context_injected);
    try std.testing.expectEqual(enriched_message.len - user_message.len, last_turn.memory_context_bytes);
    try std.testing.expectEqual(@as(u64, 12), last_turn.memory_enrich_ms);
    try std.testing.expect(!last_turn.cache_hit);
}
