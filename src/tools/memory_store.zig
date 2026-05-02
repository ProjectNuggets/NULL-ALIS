const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const MemoryCategory = mem_root.MemoryCategory;
const zaki_state = @import("../zaki_state.zig");
const extraction_persist = @import("../agent/extraction_persist.zig");

/// Memory store tool — lets the agent persist facts to long-term memory.
/// When a MemoryRuntime is available, also triggers vector sync after store.
///
/// V1.7 cmt9.6 (full Gap 3): when the agent supplies subject/predicate/
/// object alongside content, the write is routed through
/// extraction_persist.persistExtracted instead of inline upsertMemory.
/// That activates the contradiction LLM judge + entity coreference +
/// edge insert + source attribution — same pipeline as compaction Pass C
/// extraction. Without the triple, the inline path runs (backwards compat
/// for prose-only memory_store calls).
pub const MemoryStoreTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,
    // V1.7 cmt9.6 — tenant context for the unified write path. When both
    // are present AND the agent supplied a triple, routes through
    // extraction_persist with judge + coref. Wired by tools/root.zig
    // bindStateMgrTenant + bindMemoryStoreExtraction (new in cmt9.6).
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,
    judge_provider: ?@import("../providers/root.zig").Provider = null,
    judge_model_name: ?[]const u8 = null,
    coref_embed: ?@import("../memory/vector/embeddings.zig").EmbeddingProvider = null,

    pub const tool_name = "memory_store";
    pub const tool_description =
        "Store durable user facts, preferences, and decisions in long-term memory. " ++
        "Use category 'core' for stable facts, 'daily' for session notes, 'conversation' " ++
        "for important context only. Do not store routine greetings or every chat message. " ++
        "When the content is a structured fact (e.g. \"User prefers Helix\"), pass the " ++
        "subject/predicate/object fields too — the brain will run contradiction detection " ++
        "against existing facts and link the new fact into the knowledge graph.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"Unique key for this memory"},"content":{"type":"string","description":"The information to remember"},"category":{"type":"string","enum":["core","daily","conversation"],"description":"Memory category"},"scope":{"type":"string","enum":["session","global"],"description":"Memory scope (default: session)"},"session_id":{"type":"string","description":"Optional explicit session lane override"},"subject":{"type":"string","description":"Optional fact subject (e.g. 'user'). When all three of subject/predicate/object present, routes through the contradiction-judge + graph-edge pipeline."},"predicate":{"type":"string","description":"Optional fact predicate in SCREAMING_SNAKE_CASE (e.g. 'PREFERS', 'BIRTHDAY')."},"object":{"type":"string","description":"Optional fact object (e.g. 'Helix')."}},"required":["key","content"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryStoreTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryStoreTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");
        if (content.len == 0) return ToolResult.fail("'content' must not be empty");

        const category_str = root.getString(args, "category") orelse "core";
        const category = MemoryCategory.fromString(category_str);
        const session_id = resolveSessionId(args) catch |err| switch (err) {
            error.InvalidScope => return ToolResult.fail("Invalid 'scope' parameter. Expected 'session' or 'global'."),
            error.InvalidSessionId => return ToolResult.fail("Invalid 'session_id' parameter. Must be non-empty when provided."),
        };

        // V1.7 cmt9.6 (full Gap 3): when caller supplied a structured triple
        // AND tenant context is wired, route through the unified
        // extraction_persist pipeline (judge + coref + edge insert + source
        // attribution). Otherwise fall through to the inline path (backwards
        // compat for prose-only stores).
        const subj = root.getString(args, "subject");
        const pred = root.getString(args, "predicate");
        const obj = root.getString(args, "object");
        const has_triple = subj != null and pred != null and obj != null and
            subj.?.len > 0 and pred.?.len > 0 and obj.?.len > 0;

        if (has_triple) {
            if (self.state_mgr) |smgr| {
                if (self.user_id) |uid| {
                    return self.executeUnifiedWrite(allocator, smgr, uid, content, subj.?, pred.?, obj.?, session_id);
                }
            }
            // Triple supplied but no tenant context → fall through to inline
            // with a log hint so operators see the missed opportunity.
            std.log.scoped(.memory_store).info("memory_store.triple_supplied_but_no_tenant key={s} — using inline path", .{key});
        }

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot store: {s} = {s}", .{ key, content });
            return ToolResult{ .success = false, .output = msg };
        };

        m.store(key, content, category, session_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to store memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .output = msg };
        };

        // Vector sync: embed and upsert. Surface the outcome to the agent
        // so it knows whether the memory is semantically retrievable yet
        // (synced / deferred) or only keyword-retrievable (skipped / failed).
        // Silent drop here caused trust erosion: "Stored memory" implied
        // full retrieval readiness when vector sync had failed.
        const sync_status: ?mem_root.MemoryRuntime.VectorSyncResult = if (self.mem_rt) |rt|
            rt.syncVectorAfterStore(allocator, key, content)
        else
            null;

        const msg = if (sync_status) |status| blk: {
            if (status.isSuccessOrDeferred() or status.isSkipped()) {
                break :blk try std.fmt.allocPrint(allocator, "Stored memory: {s} ({s}, vector_sync={s})", .{ key, category.toString(), status.toSlice() });
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "Stored memory: {s} ({s}, vector_sync={s}) — keyword retrieval works; semantic recall may miss this entry until sync recovers",
                .{ key, category.toString(), status.toSlice() },
            );
        } else try std.fmt.allocPrint(allocator, "Stored memory: {s} ({s})", .{ key, category.toString() });

        return ToolResult{ .success = true, .output = msg };
    }

    /// V1.7 cmt9.6 — unified write path. Constructs a single-element
    /// ExtractedMemory + calls extraction_persist.persistExtracted with
    /// optional judge + coref contexts. The agent's caller-supplied
    /// `key` is IGNORED here — persistExtracted derives a deterministic
    /// `extracted_<hash(s|p|o)>` key (Gap 2). The agent doesn't need to
    /// remember the synthetic key; subsequent recalls + edits work via
    /// the (subject, predicate, object) tuple.
    fn executeUnifiedWrite(
        self: *MemoryStoreTool,
        allocator: std.mem.Allocator,
        smgr: *zaki_state.Manager,
        uid: i64,
        content: []const u8,
        subject: []const u8,
        predicate: []const u8,
        object: []const u8,
        session_id: ?[]const u8,
    ) !ToolResult {
        const mems = [_]extraction_persist.ExtractedMemory{.{
            .text = content,
            .subject = subject,
            .predicate = predicate,
            .object = object,
            .attributed_to = "user", // memory_store is user-attributed by default
            .confidence = 0.95,
        }};

        const judge_ctx: ?extraction_persist.JudgeContext = blk: {
            if (self.judge_provider) |jp| {
                if (self.judge_model_name) |jmn| {
                    break :blk extraction_persist.JudgeContext{ .provider = jp, .model_name = jmn };
                }
            }
            break :blk null;
        };

        const coref_ctx: ?extraction_persist.EntityResolution = blk: {
            if (self.coref_embed) |ep| {
                break :blk extraction_persist.EntityResolution{ .embed_provider = ep, .threshold = 0.95 };
            }
            break :blk null;
        };

        const result = extraction_persist.persistExtracted(
            allocator,
            smgr,
            uid,
            session_id,
            &mems,
            judge_ctx,
            coref_ctx,
        ) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to store memory via unified pipeline: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const verb = if (result.skipped_semantic_dup > 0)
            "skipped (semantic duplicate)"
        else if (result.skipped_md5_dup > 0)
            "skipped (exact duplicate)"
        else if (result.written_count > 0)
            "stored"
        else
            "rejected";

        const msg = try std.fmt.allocPrint(
            allocator,
            "Memory {s}: {s} {s} {s} (judge={s}, coref={s}, contradictions_resolved={d})",
            .{
                verb,
                subject,
                predicate,
                object,
                if (judge_ctx == null) "off" else "on",
                if (coref_ctx == null) "off" else "on",
                result.contradictions_resolved,
            },
        );
        return ToolResult{ .success = true, .output = msg };
    }

    fn resolveSessionId(args: JsonObjectMap) error{ InvalidScope, InvalidSessionId }!?[]const u8 {
        if (root.getString(args, "session_id")) |sid_raw| {
            const sid = std.mem.trim(u8, sid_raw, " \t\r\n");
            if (sid.len == 0) return error.InvalidSessionId;
            return sid;
        }

        const scope_raw = root.getString(args, "scope") orelse "session";
        const scope = std.mem.trim(u8, scope_raw, " \t\r\n");
        if (scope.len == 0) return error.InvalidScope;
        if (std.ascii.eqlIgnoreCase(scope, "global")) return null;
        if (std.ascii.eqlIgnoreCase(scope, "session")) {
            const session_key = root.getTurnContext().session_key orelse return error.InvalidSessionId;
            if (session_key.len == 0) return error.InvalidSessionId;
            return session_key;
        }
        return error.InvalidScope;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_store tool name" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_store", t.name());
}

test "memory_store schema has key and content" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "key") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "content") != null);
}

test "memory_store executes without backend" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"lang\", \"content\": \"Prefers Zig\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "not configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lang") != null);
}

test "memory_store missing key" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"content\": \"no key\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_store missing content" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"no_content\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_store with real backend" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"lang\", \"content\": \"Prefers Zig\", \"category\": \"core\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Stored memory: lang") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "core") != null);
}

test "memory_store default category is core" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"test\", \"content\": \"value\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "core") != null);
}

test "memory_store with daily category" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"note\", \"content\": \"today's note\", \"category\": \"daily\", \"scope\": \"global\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "daily") != null);
}

test "memory_store defaults to session scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryStoreTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"lane_pref\",\"content\":\"session scoped\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(result.success);

    const entry = (try mem.get(allocator, "lane_pref")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expect(entry.session_id != null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", entry.session_id.?);
}

test "memory_store supports explicit global scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryStoreTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"global_pref\",\"content\":\"all lanes\",\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(result.success);

    const entry = (try mem.get(allocator, "global_pref")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expect(entry.session_id == null);
}

test "memory_store rejects invalid scope value" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"x\",\"content\":\"y\",\"scope\":\"tenant\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid 'scope'") != null);
}
