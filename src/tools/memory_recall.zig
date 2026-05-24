const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const query_expansion = @import("../memory/retrieval/query_expansion.zig");
const Memory = mem_root.Memory;
const MemoryEntry = mem_root.MemoryEntry;
const zaki_state = @import("../zaki_state.zig");
const supersede_filter = @import("supersede_filter.zig");
const text_norm = @import("../memory/text_norm.zig");

// F-T1 (V1.14.6 SOTA context): per-result content cap. Each individual
// memory_recall hit's content is capped at this many bytes (UTF-8-safe
// truncation at codepoint boundary). Stops the firehose at the source.
//
// Pre-fix observation: each result was 500-2000 chars. With ~5 results
// per call and ~2.4 calls per QA in our LoCoMo bench, raw output per
// QA averaged 5-25KB. Across 30 QAs, ~150-750KB accumulated in
// conversation history → token-pressure climbed 1.5pp/QA.
//
// Post-fix: each result ≤ 500 chars. Total per-call output ≤ ~3KB,
// per-QA ≤ ~7KB. Pressure growth roughly halved.
//
// The agent's brain still HAS the full content via re-call; this cap
// is on the in-context PROJECTION, not the underlying data.
const PER_RESULT_CONTENT_CAP: usize = 500;

/// Memory recall tool — lets the agent search its own memory.
/// When a MemoryRuntime is available, uses the full retrieval pipeline
/// (hybrid search, RRF merge, temporal decay, MMR, etc.) instead of
/// raw `mem.recall()`.
pub const MemoryRecallTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,
    /// V1.10-D — supersede filter binding. When wired, this tool
    /// fetches the supersede skip-set upfront and drops flagged rows
    /// from results before the agent sees them. Without it, retrieval
    /// degrades to V1.9-era behavior (superseded rows surface as
    /// truth-equivalent — the bug ZAKI named in his 2026-05-06
    /// stress-test report).
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "memory_recall";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Retrieve facts, preferences, and decisions from long-term memory.",
        .use_when = &.{
            "Finding previously stored user facts or preferences by key or semantic search",
            "Checking what decisions or preferences were recorded in earlier sessions",
            "Validating whether a fact exists before taking action based on it",
        },
        .do_not_use_for = &.{
            "memory_store — for persistence instead of retrieval",
            "todo — for short-lived transient decisions",
            "web_search — for current facts",
        },
        .cost_note = "Retrieval is free. Semantic search may incur embedding cost.",
        .completion_hint = "Returns matched memories with timestamps.",
        .see_also = &.{
            "memory_store — persist new facts and preferences",
            "memory_timeline — view fact change history",
        },
    };
    // Comptime validation of tool_description_struct
    comptime {
        @import("lint.zig").lintToolDescription("memory_recall", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description = "Search canonical memory for relevant facts, preferences, or context. Defaults to the current session unless scope=global is provided.";
    pub const tool_params =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Keywords or phrase to search for in canonical memory"},"limit":{"type":"integer","description":"Max results to return (default: 5)"},"scope":{"type":"string","enum":["session","global"],"description":"Recall scope (default: session). Use global for durable or cross-session facts."},"session_id":{"type":"string","description":"Optional explicit session lane override"}},"required":["query"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryRecallTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryRecallTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing 'query' parameter");
        if (query.len == 0) return ToolResult.fail("'query' must not be empty");

        // R18 (2026-04-28) → SwissWatch (2026-04-28): hard cap REMOVED
        // entirely. Per Nova: "let the agent remember as much as he
        // wants. We control this by increasing or decreasing the
        // similarity index." Quality is governed by the retrieval
        // pipeline's similarity threshold, NOT an arbitrary count cap.
        // Default when no limit specified stays 5 (agent's typical
        // use). Negative or zero limit_raw → 5 (sensible default).
        // Postgres ORDER BY ... LIMIT N is bounded by N, not by the
        // memory store size, so a large N just returns more rows
        // (slower, but never broken).
        const limit_raw = root.getInt(args, "limit") orelse 5;
        const limit: usize = if (limit_raw > 0) @intCast(limit_raw) else 5;
        const session_id = resolveSessionId(args) catch |err| switch (err) {
            error.InvalidScope => return ToolResult.fail("Invalid 'scope' parameter. Expected 'session' or 'global'."),
            error.InvalidSessionId => return ToolResult.fail("Invalid 'session_id' parameter. Must be non-empty when provided."),
        };

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot search for: {s}", .{query});
            return ToolResult{ .success = false, .output = msg };
        };

        // V1.10-D — fetch supersede skip-set once at the tool boundary.
        // Drops rows whose `metadata.superseded_by_correction` is set so
        // the agent doesn't see flagged zombies surface as truth-equivalent
        // alongside the live row. Graceful degrade on null state_mgr or
        // SQL error → empty skip-set, behavior matches V1.9.
        const superseded_keys = supersede_filter.fetchSupersededKeys(allocator, self.state_mgr, self.user_id);
        defer supersede_filter.freeKeys(allocator, superseded_keys);

        // Use retrieval engine (hybrid pipeline) when MemoryRuntime is available,
        // fall back to raw mem.recall() otherwise.
        if (self.mem_rt) |rt| {
            const candidates = rt.search(allocator, query, limit, session_id) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to search memories for '{s}': {s}", .{ query, @errorName(err) });
                return ToolResult{ .success = false, .output = msg };
            };
            defer mem_root.retrieval.freeCandidates(allocator, candidates);

            const visible_candidates = countVisibleCandidates(candidates, superseded_keys);
            if (visible_candidates > 0) {
                return formatCandidates(allocator, candidates, visible_candidates, superseded_keys);
            }

            const fallback_entries = try recallFallbackByKeywords(allocator, m, query, limit, session_id);
            defer mem_root.freeEntries(allocator, fallback_entries);

            const fallback_visible = countVisibleEntries(fallback_entries, superseded_keys);
            if (fallback_visible > 0) {
                return formatEntries(allocator, fallback_entries, fallback_visible, superseded_keys);
            }

            const msg = try std.fmt.allocPrint(allocator, "No memories found matching: {s}", .{query});
            return ToolResult{ .success = true, .output = msg };
        }

        const entries = m.recall(allocator, query, limit, session_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to recall memories for '{s}': {s}", .{ query, @errorName(err) });
            return ToolResult{ .success = false, .output = msg };
        };
        defer mem_root.freeEntries(allocator, entries);

        const visible_entries = countVisibleEntries(entries, superseded_keys);
        if (visible_entries > 0) {
            return formatEntries(allocator, entries, visible_entries, superseded_keys);
        }

        const fallback_entries = try recallFallbackByKeywords(allocator, m, query, limit, session_id);
        defer mem_root.freeEntries(allocator, fallback_entries);

        const fallback_visible = countVisibleEntries(fallback_entries, superseded_keys);
        if (fallback_visible > 0) {
            return formatEntries(allocator, fallback_entries, fallback_visible, superseded_keys);
        }

        const msg = try std.fmt.allocPrint(allocator, "No memories found matching: {s}", .{query});
        return ToolResult{ .success = true, .output = msg };
    }

    fn countVisibleEntries(entries: []const MemoryEntry, superseded_keys: []const []u8) usize {
        var count: usize = 0;
        for (entries) |entry| {
            if (mem_root.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
            if (supersede_filter.isKeySuperseded(entry.key, superseded_keys)) continue;
            count += 1;
        }
        return count;
    }

    fn countVisibleCandidates(candidates: []const mem_root.RetrievalCandidate, superseded_keys: []const []u8) usize {
        var count: usize = 0;
        for (candidates) |cand| {
            if (mem_root.isInternalMemoryEntryKeyOrContent(cand.key, cand.snippet)) continue;
            if (supersede_filter.isKeySuperseded(cand.key, superseded_keys)) continue;
            count += 1;
        }
        return count;
    }

    fn recallFallbackByKeywords(
        allocator: std.mem.Allocator,
        mem: Memory,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
    ) ![]MemoryEntry {
        const keywords = query_expansion.extractKeywords(allocator, query) catch return allocator.alloc(MemoryEntry, 0);
        defer {
            for (keywords) |keyword| allocator.free(keyword);
            allocator.free(keywords);
        }

        if (keywords.len == 0) return allocator.alloc(MemoryEntry, 0);

        var out: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (out.items) |*entry| entry.deinit(allocator);
            out.deinit(allocator);
        }

        for (keywords) |keyword| {
            if (keyword.len < 2) continue;
            const matches = mem.recall(allocator, keyword, limit, session_id) catch continue;
            defer mem_root.freeEntries(allocator, matches);

            for (matches) |entry| {
                if (mem_root.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
                if (containsEntryKey(out.items, entry.key)) continue;
                try out.append(allocator, try cloneEntry(allocator, entry));
                if (out.items.len >= limit) {
                    return out.toOwnedSlice(allocator);
                }
            }
        }

        return out.toOwnedSlice(allocator);
    }

    fn containsEntryKey(entries: []const MemoryEntry, key: []const u8) bool {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return true;
        }
        return false;
    }

    fn cloneEntry(allocator: std.mem.Allocator, entry: MemoryEntry) !MemoryEntry {
        const id = try allocator.dupe(u8, entry.id);
        errdefer allocator.free(id);
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        const content = try allocator.dupe(u8, entry.content);
        errdefer allocator.free(content);
        const timestamp = try allocator.dupe(u8, entry.timestamp);
        errdefer allocator.free(timestamp);
        const category = switch (entry.category) {
            .custom => |name| mem_root.MemoryCategory{ .custom = try allocator.dupe(u8, name) },
            else => entry.category,
        };
        errdefer switch (category) {
            .custom => |name| allocator.free(name),
            else => {},
        };
        const session = if (entry.session_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (session) |value| allocator.free(value);

        return .{
            .id = id,
            .key = key,
            .content = content,
            .category = category,
            .timestamp = timestamp,
            .session_id = session,
            .score = entry.score,
        };
    }

    fn formatEntries(allocator: std.mem.Allocator, entries: []const MemoryEntry, visible_count: usize, superseded_keys: []const []u8) !ToolResult {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "Found ");
        var count_buf: [20]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{visible_count}) catch "?";
        try buf.appendSlice(allocator, count_str);
        try buf.appendSlice(allocator, if (visible_count == 1) " memory:\n" else " memories:\n");

        var shown_idx: usize = 0;
        for (entries, 0..) |entry, i| {
            _ = i;
            if (mem_root.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
            if (supersede_filter.isKeySuperseded(entry.key, superseded_keys)) continue;
            var idx_buf: [20]u8 = undefined;
            shown_idx += 1;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{shown_idx}) catch "?";
            const provenance = mem_root.resolveStoredMemoryProvenance(entry.content, entry.session_id, entry.key);
            try buf.appendSlice(allocator, idx_str);
            try buf.appendSlice(allocator, ". [");
            try buf.appendSlice(allocator, entry.key);
            try buf.appendSlice(allocator, "] [");
            try buf.appendSlice(allocator, entry.category.toString());
            try buf.appendSlice(allocator, "] role=");
            try buf.appendSlice(allocator, mem_root.classifyArtifactKey(entry.key).toSlice());
            try buf.appendSlice(allocator, " channel=");
            try buf.appendSlice(allocator, provenance.channel);
            try buf.appendSlice(allocator, " lane=");
            try buf.appendSlice(allocator, provenance.lane);
            if (provenance.session_id) |session_id| {
                try buf.appendSlice(allocator, " session=");
                try buf.appendSlice(allocator, session_id);
            }
            if (entry.timestamp.len > 0) {
                try buf.appendSlice(allocator, " at=");
                try buf.appendSlice(allocator, entry.timestamp);
            }
            try buf.appendSlice(allocator, ": ");
            // F-T1: cap per-result content. Source content stays full
            // in the underlying memory layer; this only caps the in-
            // context projection of the recall result.
            const capped = text_norm.truncateUtf8(entry.content, PER_RESULT_CONTENT_CAP);
            try buf.appendSlice(allocator, capped);
            if (capped.len < entry.content.len) {
                try buf.appendSlice(allocator, " […recall again for full]");
            }
            try buf.append(allocator, '\n');
        }

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    fn resolveSessionId(args: JsonObjectMap) error{ InvalidScope, InvalidSessionId }!?[]const u8 {
        if (root.getString(args, "session_id")) |sid_raw| {
            const sid = std.mem.trim(u8, sid_raw, " \t\r\n");
            if (sid.len == 0) return error.InvalidSessionId;
            return sid;
        }

        // F-A7.1 (2026-05-24): if scope was not explicitly supplied AND the
        // caller is the MCP server (no agent-side session_key in the turn
        // context), fall back to global recall instead of erroring.
        // IDE / external MCP clients have no concept of nullalis session
        // lanes, so requiring one would break every memory_recall they make.
        // Agent-turn callers ALWAYS get an explicit session_key plumbed in;
        // the .mcp origin is the only path that lands here with a null key.
        const scope_explicit = root.getString(args, "scope") != null;
        const scope_raw = root.getString(args, "scope") orelse "session";
        const scope = std.mem.trim(u8, scope_raw, " \t\r\n");
        if (scope.len == 0) return error.InvalidScope;
        if (std.ascii.eqlIgnoreCase(scope, "global")) return null;
        if (std.ascii.eqlIgnoreCase(scope, "session")) {
            const ctx = root.getTurnContext();
            const session_key = ctx.session_key orelse {
                if (!scope_explicit and ctx.origin == .mcp) return null; // graceful MCP default
                return error.InvalidSessionId;
            };
            if (session_key.len == 0) {
                if (!scope_explicit and ctx.origin == .mcp) return null;
                return error.InvalidSessionId;
            }
            return session_key;
        }
        return error.InvalidScope;
    }

    fn formatCandidates(
        allocator: std.mem.Allocator,
        candidates: []const mem_root.RetrievalCandidate,
        visible_count: usize,
        superseded_keys: []const []u8,
    ) !ToolResult {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "Found ");
        var count_buf: [20]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{visible_count}) catch "?";
        try buf.appendSlice(allocator, count_str);
        try buf.appendSlice(allocator, if (visible_count == 1) " memory:\n" else " memories:\n");

        var shown_idx: usize = 0;
        for (candidates, 0..) |cand, i| {
            _ = i;
            if (mem_root.isInternalMemoryEntryKeyOrContent(cand.key, cand.snippet)) continue;
            if (supersede_filter.isKeySuperseded(cand.key, superseded_keys)) continue;
            var idx_buf: [20]u8 = undefined;
            shown_idx += 1;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{shown_idx}) catch "?";
            const provenance = mem_root.resolveStoredMemoryProvenance(cand.snippet, null, cand.key);
            try buf.appendSlice(allocator, idx_str);
            try buf.appendSlice(allocator, ". [");
            try buf.appendSlice(allocator, cand.key);
            try buf.appendSlice(allocator, "] [");
            try buf.appendSlice(allocator, cand.source);
            try buf.appendSlice(allocator, "] channel=");
            try buf.appendSlice(allocator, provenance.channel);
            try buf.appendSlice(allocator, " lane=");
            try buf.appendSlice(allocator, provenance.lane);
            if (provenance.session_id) |session_id| {
                try buf.appendSlice(allocator, " session=");
                try buf.appendSlice(allocator, session_id);
            }
            var score_buf: [20]u8 = undefined;
            const score_str = std.fmt.bufPrint(&score_buf, " score={d:.2}", .{cand.final_score}) catch "";
            try buf.appendSlice(allocator, score_str);
            try buf.appendSlice(allocator, ": ");
            // F-T1: cap per-candidate snippet. Same rationale as
            // formatEntries above — context-projection cap, not data
            // truncation. Snippet is already a slice of full content;
            // re-call returns the full snippet from the retrieval
            // pipeline if needed.
            const capped = text_norm.truncateUtf8(cand.snippet, PER_RESULT_CONTENT_CAP);
            try buf.appendSlice(allocator, capped);
            if (capped.len < cand.snippet.len) {
                try buf.appendSlice(allocator, " […recall again for full]");
            }
            try buf.append(allocator, '\n');
        }

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_recall tool name" {
    var mt = MemoryRecallTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_recall", t.name());
}

test "memory_recall schema has query" {
    var mt = MemoryRecallTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "query") != null);
}

test "memory_recall executes without backend" {
    var mt = MemoryRecallTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\": \"Zig\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "not configured") != null);
}

test "memory_recall missing query" {
    var mt = MemoryRecallTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_recall with real backend empty result" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryRecallTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\": \"Zig\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No memories found") != null);
}

test "memory_recall with custom limit" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryRecallTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\": \"test\", \"limit\": 10, \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
}

test "memory_recall filters internal bootstrap keys" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("__bootstrap.prompt.SOUL.md", "internal-soul", .core, null);
    try mem.store("user_pref", "loves zig", .core, null);

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\": \"zig\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "user_pref") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__bootstrap.prompt.SOUL.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "internal-soul") == null);
}

test "memory_recall filters audit and index artifacts by default" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("session_checkpoint_1", "type=session_checkpoint\nrecent_user:\n- shipping\n", .daily, null);
    try mem.store("timeline_index/current", "{\"session\":\"agent:zaki-bot:user:1:main\"}", .core, null);
    try mem.store("timeline_summary/agent:zaki-bot:user:1:main/1", "focus: shipping\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\": \"shipping\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timeline_summary/agent:zaki-bot:user:1:main/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session_checkpoint_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timeline_index/current") == null);
}

test "memory_recall filters markdown encoded internal keys" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("MEMORY:3", "**last_hygiene_at**: 1772051598", .core, null);
    try mem.store("MEMORY:4", "**Name**: User", .core, null);

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\": \"User\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "last_hygiene_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "**Name**: User") != null);
}

test "memory_recall defaults to session scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("global_fact", "banana global", .core, null);
    try mem.store("session_fact", "banana session", .core, "agent:zaki-bot:user:1:main");

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"banana\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "global_fact") == null);
}

test "memory_recall supports explicit global scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("global_fact", "banana global", .core, null);

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"banana\",\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "global_fact") != null);
}

test "memory_recall falls back to keyword tokens when phrase misses" {
    const allocator = std.testing.allocator;
    var mem_impl = mem_root.InMemoryLruMemory.init(allocator, 32);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    try mem.store(
        "hrs_deal",
        "hrs deal confirmed (30gb, kickoff april 7)",
        .daily,
        null,
    );

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"30gb project\",\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hrs_deal") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "30gb") != null);
}

test "memory_recall shows derived provenance" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "timeline_summary/agent:zaki-bot:user:1:thread:rollout/1774400000",
        "focus: rollout recap",
        .daily,
        null,
    );

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"rollout\",\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "channel=app") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lane=thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session=agent:zaki-bot:user:1:thread:rollout") != null);
}

test "memory_recall prefers explicit origin metadata" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "timeline_summary/agent:zaki-bot:user:1:thread:telegram:thread:1110331014/1774400000",
        "origin_channel=telegram\norigin_lane=thread\norigin_chat_id=1110331014\n\nfocus: telegram rollout\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n",
        .daily,
        null,
    );

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"telegram\",\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "channel=telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lane=thread") != null);
}

test "memory_recall rejects invalid scope value" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryRecallTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"banana\",\"scope\":\"tenant\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid 'scope'") != null);
}

// F-A7.1 regression guard (2026-05-24). MCP-context calls (origin=.mcp,
// no session_key, no explicit scope/session_id) used to error out with
// "Invalid 'session_id'" because the default scope=session demanded a
// turn-context session_key and the MCP server provided none. The fix
// teaches resolveSessionId to gracefully fall through to global recall
// in that exact shape. This test pins the contract so a future refactor
// can't silently regress IDE / external-MCP-client UX.
test "memory_recall MCP-origin falls back to global when no session_key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("global_fact", "kiwi global", .core, null);
    try mem.store("session_fact", "kiwi session", .core, "agent:zaki-bot:user:1:main");

    // MCP-origin context: origin=.mcp, session_key=null. Same shape as
    // src/mcp/server_handlers.zig:handleToolsCall sets up around the
    // tool.execute call.
    root.setTurnContext(.{ .origin = .mcp });
    defer root.clearTurnContext();

    var mt = MemoryRecallTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"kiwi\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    // Global recall surfaces BOTH facts (no session scoping applied).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "global_fact") != null);
}

// F-A7.1 negative guard: an agent-origin call without a session_key is
// still an error (that shape indicates a real wiring bug, not an MCP
// caller). Only the .mcp origin earns the graceful fallback.
test "memory_recall non-MCP origin still errors without session_key" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    root.setTurnContext(.{ .origin = .user, .session_key = null });
    defer root.clearTurnContext();

    var mt = MemoryRecallTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"x\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid 'session_id'") != null);
}
