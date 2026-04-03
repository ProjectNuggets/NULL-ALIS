const std = @import("std");
const context_builder = @import("context_builder.zig");

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

    return try std.fmt.allocPrint(
        allocator,
        "Context detail:\n" ++
            "  model: {s}\n" ++
            "  messages: {d}\n" ++
            "  token_estimate: {d}\n" ++
            "  tools: {d}\n" ++
            "  by_role: system={d} user={d} assistant={d} tool={d}\n" ++
            "  memory: enabled={s} runtime={s} session={s} enriched_messages={d}\n" ++
            "  retrieval: mode={s} provider={s} vector={s} rollout={s}\n" ++
            "  prompt: has_system={s} conversation_context={s} workspace_fp={s}\n" ++
            "  runtime: compact_context={s} compacted_last_turn={s}\n" ++
            "  last_turn: prompt_refresh={s} reason={s} memory_injected={s} bytes={d} enrich_ms={d} cache_hit={s}",
        .{
            report.model_name,
            report.history_messages,
            report.token_estimate,
            report.tool_count,
            report.role_counts.system,
            report.role_counts.user,
            report.role_counts.assistant,
            report.role_counts.tool,
            boolWord(report.memory_enabled),
            boolWord(report.memory_runtime_enabled),
            memory_session_text,
            report.memory_enriched_messages,
            report.retrieval_mode,
            report.embedding_provider,
            report.vector_mode,
            report.rollout_mode,
            boolWord(report.has_system_prompt),
            boolWord(report.has_conversation_context),
            workspace_fp_text,
            boolWord(report.compact_context_enabled),
            boolWord(report.context_was_compacted),
            boolWord(report.last_turn.prompt_refreshed),
            refresh_reason_text,
            boolWord(report.last_turn.memory_context_injected),
            report.last_turn.memory_context_bytes,
            report.last_turn.memory_enrich_ms,
            boolWord(report.last_turn.cache_hit),
        },
    );
}

pub fn formatJson(allocator: std.mem.Allocator, report: Report) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{
        .model = report.model_name,
        .history_messages = report.history_messages,
        .token_estimate = report.token_estimate,
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
}

test "context report formatters expose structured details" {
    const report = Report{
        .model_name = "openai/gpt-5.2",
        .history_messages = 7,
        .token_estimate = 321,
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
        },
    };

    const summary = try formatSummary(std.testing.allocator, report);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "memory_enriched=2") != null);

    const detail = try formatDetail(std.testing.allocator, report);
    defer std.testing.allocator.free(detail);
    try std.testing.expect(std.mem.indexOf(u8, detail, "memory: enabled=yes runtime=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "retrieval: mode=hybrid provider=together vector=pgvector rollout=on") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "last_turn: prompt_refresh=yes reason=workspace memory_injected=yes bytes=64 enrich_ms=11 cache_hit=no") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "workspace_fp=77") != null);

    const json = try formatJson(std.testing.allocator, report);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enriched_messages\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"embedding_provider\":\"together\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory_context_injected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workspace_prompt_fingerprint\":77") != null);
}
