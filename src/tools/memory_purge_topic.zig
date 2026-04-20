const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;

/// Memory purge-topic tool — cleanup lever for already-accumulated pollution.
///
/// When the agent has repeatedly hallucinated about a topic across prior turns,
/// those prior replies are cached in memory (autosave_assistant_*) and in
/// session checkpoints, and re-seed every future turn on the same topic.
/// The summarizer-side hygiene (C) and runtime history filter (iter11)
/// prevent new laundering and elide replay, but they cannot retroactively
/// delete content created before those guards were in place.
///
/// This tool gives the agent (and therefore the user via natural language
/// request, "forget everything you said about X") an explicit purge path:
/// for a given topic string, delete all autosave_* and session_checkpoint_*
/// entries whose content contains the topic. Continuity artifacts
/// (timeline_summary, summary_latest, durable_fact) are also purged when
/// their content mentions the topic, since they may contain laundered
/// versions of the same hallucination.
///
/// Scope is conservative: user-authored memory keys (memory_store output)
/// are NEVER purged by this tool — only agent-generated audit/continuity
/// artifacts and raw autosave chatter.
pub const MemoryPurgeTopicTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,

    pub const tool_name = "memory_purge_topic";
    pub const tool_description = "Delete agent-generated memory entries (autosave, checkpoints, summaries) that mention a given topic. Use when the agent has been repeatedly wrong about something (prior hallucinations polluting future turns) and the user asks to 'forget' or 'start fresh' on that topic. Does NOT delete user-authored memories created via memory_store.";
    pub const tool_params =
        \\{"type":"object","properties":{"topic":{"type":"string","description":"The topic / entity / keyword to scrub from agent-generated memory. Case-insensitive substring match against content."}},"required":["topic"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryPurgeTopicTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Returns true when `key` belongs to an agent-generated artifact family
    /// that is safe to purge on demand. User-authored keys (memory_store
    /// output) are NOT in-scope and return false.
    fn isPurgeableFamily(key: []const u8) bool {
        return std.mem.startsWith(u8, key, "autosave_assistant_") or
            std.mem.startsWith(u8, key, "autosave_user_") or
            std.mem.startsWith(u8, key, "session_checkpoint_") or
            std.mem.startsWith(u8, key, "timeline_summary/") or
            std.mem.startsWith(u8, key, "summary_latest/") or
            std.mem.startsWith(u8, key, "durable_fact/") or
            // iter33: iter29 continuity families. Polluted content in these
            // namespaces must be scrubbable via the topic purge lever, same
            // as the older families. Without this the agent could not clean
            // hallucinations that landed in Pass C summaries or fallback
            // stores.
            std.mem.startsWith(u8, key, "compaction_summary/") or
            std.mem.startsWith(u8, key, "summary_fallback/") or
            std.mem.startsWith(u8, key, "compaction_dropped/");
    }

    pub fn execute(self: *MemoryPurgeTopicTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const topic = root.getString(args, "topic") orelse
            return ToolResult.fail("Missing 'topic' parameter");
        if (topic.len == 0) return ToolResult.fail("'topic' must not be empty");
        if (topic.len < 3) return ToolResult.fail("'topic' too short (minimum 3 chars) — overly broad topics would purge unrelated content");

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot purge topic: {s}", .{topic});
            return ToolResult{ .success = false, .output = msg };
        };

        // Enumerate all entries (both scoped and global). List with no
        // category filter returns everything the backend has.
        const scoped = m.list(allocator, null, null) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to enumerate memory: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer mem_root.freeEntries(allocator, scoped);

        var purged: usize = 0;
        // iter33: extended counters for the iter29 families so the agent's
        // purge summary reports accurately.
        var by_family = [_]usize{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        // autosave_a, autosave_u, checkpoint, timeline, summary_latest,
        // durable_fact, compaction_summary, summary_fallback, compaction_dropped
        for (scoped) |entry| {
            if (!isPurgeableFamily(entry.key)) continue;
            if (std.ascii.indexOfIgnoreCase(entry.content, topic) == null) continue;

            const forgotten = m.forget(entry.key) catch continue;
            if (!forgotten) continue;
            purged += 1;

            if (std.mem.startsWith(u8, entry.key, "autosave_assistant_")) by_family[0] += 1
            else if (std.mem.startsWith(u8, entry.key, "autosave_user_")) by_family[1] += 1
            else if (std.mem.startsWith(u8, entry.key, "session_checkpoint_")) by_family[2] += 1
            else if (std.mem.startsWith(u8, entry.key, "timeline_summary/")) by_family[3] += 1
            else if (std.mem.startsWith(u8, entry.key, "summary_latest/")) by_family[4] += 1
            else if (std.mem.startsWith(u8, entry.key, "durable_fact/")) by_family[5] += 1
            else if (std.mem.startsWith(u8, entry.key, "compaction_summary/")) by_family[6] += 1
            else if (std.mem.startsWith(u8, entry.key, "summary_fallback/")) by_family[7] += 1
            else if (std.mem.startsWith(u8, entry.key, "compaction_dropped/")) by_family[8] += 1;

            // Best-effort vector store cleanup
            if (self.mem_rt) |rt| rt.deleteFromVectorStore(entry.key);
        }

        const msg = try std.fmt.allocPrint(
            allocator,
            "Purged {d} agent-generated entries matching topic \"{s}\" (autosave_assistant={d}, autosave_user={d}, session_checkpoint={d}, timeline_summary={d}, summary_latest={d}, durable_fact={d}, compaction_summary={d}, summary_fallback={d}, compaction_dropped={d}). User-authored memories untouched.",
            .{ purged, topic, by_family[0], by_family[1], by_family[2], by_family[3], by_family[4], by_family[5], by_family[6], by_family[7], by_family[8] },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_purge_topic tool name" {
    var mt = MemoryPurgeTopicTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_purge_topic", t.name());
}

test "memory_purge_topic rejects empty topic" {
    var mt = MemoryPurgeTopicTool{};
    const t = mt.tool();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("topic", .{ .string = "" });

    const result = try t.execute(std.testing.allocator, obj);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(!result.success);
    const err_msg = result.error_msg orelse return error.TestExpectedErrorMsg;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "not be empty") != null);
}

test "memory_purge_topic rejects too-short topic" {
    var mt = MemoryPurgeTopicTool{};
    const t = mt.tool();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("topic", .{ .string = "ab" });

    const result = try t.execute(std.testing.allocator, obj);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(!result.success);
    const err_msg = result.error_msg orelse return error.TestExpectedErrorMsg;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "too short") != null);
}

test "isPurgeableFamily flags agent-generated keys only" {
    try std.testing.expect(MemoryPurgeTopicTool.isPurgeableFamily("autosave_assistant_123"));
    try std.testing.expect(MemoryPurgeTopicTool.isPurgeableFamily("autosave_user_456"));
    try std.testing.expect(MemoryPurgeTopicTool.isPurgeableFamily("session_checkpoint_789"));
    try std.testing.expect(MemoryPurgeTopicTool.isPurgeableFamily("timeline_summary/agent:x:user:1:main/123"));
    try std.testing.expect(MemoryPurgeTopicTool.isPurgeableFamily("summary_latest/agent:x:user:1:main"));
    try std.testing.expect(MemoryPurgeTopicTool.isPurgeableFamily("durable_fact/123/0"));

    // User-authored keys (no matching prefix) must not be purgeable
    try std.testing.expect(!MemoryPurgeTopicTool.isPurgeableFamily("user_preference_theme"));
    try std.testing.expect(!MemoryPurgeTopicTool.isPurgeableFamily("my_custom_fact"));
    try std.testing.expect(!MemoryPurgeTopicTool.isPurgeableFamily("context_anchor_current"));
}
