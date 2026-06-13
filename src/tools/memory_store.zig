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
const pii_detect = @import("../memory/pii_detect.zig");
const observability = @import("../observability.zig");

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
    /// V1.14.12 (M2 review CRITICAL) — cardinality fast-path flag,
    /// threaded from tool binding so memory_store's JudgeContext
    /// honors operator config. Default true preserves M2 behavior.
    cardinality_fastpath_enabled: bool = true,
    /// P3 (memory-phase-0.5) — semantic type-routing flag, threaded from
    /// tool binding so memory_store's JudgeContext routes memory_type by
    /// fact meaning per operator config. Default true.
    semantic_type_routing_enabled: bool = true,
    coref_embed: ?@import("../memory/vector/embeddings.zig").EmbeddingProvider = null,

    pub const tool_name = "memory_store";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Store durable user facts, preferences, and decisions in long-term memory.",
        .use_when = &.{
            "Recording new user preferences or facts that should persist across sessions",
            "Storing structured facts with subject/predicate/object for knowledge graph linkage",
            "Capturing important context from conversation for future recall",
        },
        .do_not_use_for = &.{
            "memory_recall — for fact retrieval instead",
            "todo — for short-lived transient decisions",
            "set_execution_mode — for proper scoping",
        },
        .cost_note = "No API cost; local write to memory backend.",
        .completion_hint = "Returns success with stored memory ID.",
        .see_also = &.{
            "memory_recall — retrieve stored facts and preferences",
            "memory_timeline — view fact change history",
        },
    };
    // Comptime validation of tool_description_struct
    comptime {
        @import("lint.zig").lintToolDescription("memory_store", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Store user facts, preferences, decisions, and session notes in canonical memory. " ++
        "Default scope is session; session-scoped writes default to category 'daily', while scope=global defaults to 'core'. " ++
        "Use category 'core' only for stable durable facts, 'daily' for session notes, and 'conversation' " ++
        "for important context only. Do not store routine greetings or every chat message. " ++
        "When the content is a structured fact (e.g. \"User prefers Helix\"), pass the " ++
        "subject/predicate/object fields too — the brain will run contradiction detection " ++
        "against existing facts and link the new fact into the knowledge graph.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"Unique key for this memory"},"content":{"type":"string","description":"The information to remember"},"category":{"type":"string","enum":["core","daily","conversation"],"description":"Memory category. Defaults to daily for scope=session and core for scope=global."},"scope":{"type":"string","enum":["session","global"],"description":"Memory scope (default: session). Use scope=global only for durable cross-session facts."},"session_id":{"type":"string","description":"Optional explicit session lane override"},"subject":{"type":"string","description":"Optional fact subject (e.g. 'user'). When all three of subject/predicate/object present, routes through the contradiction-judge + graph-edge pipeline."},"predicate":{"type":"string","description":"Optional fact predicate in SCREAMING_SNAKE_CASE (e.g. 'PREFERS', 'BIRTHDAY')."},"object":{"type":"string","description":"Optional fact object (e.g. 'Helix')."},"valid_at":{"type":"string","description":"Optional ISO-8601 date (YYYY-MM-DD) when this fact became true. Persisted as memory_edges.temporal_anchor_unix; enables time-range queries like 'what did I do in March?'. Only applied when subject/predicate/object are also supplied (the inline path doesn't write graph edges). Invalid dates are silently ignored — write-time is the fallback anchor."}},"required":["key","content"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryStoreTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// S5 (2026-05-29, prod-readiness) — public entry point wraps the
    /// underlying executor with latency + result emit so SLO dashboards
    /// can chart memory-tool error-rate and tail latency. The wrapper
    /// shape lets every existing `return ToolResult.fail(...)` /
    /// `return ToolResult{ ... .success = false }` path inside the
    /// inner function light up "err" without touching each return.
    pub fn execute(self: *MemoryStoreTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const start_ms = std.time.milliTimestamp();
        const result = self.executeInner(allocator, args) catch |err| {
            const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_ms));
            observability.recordMetricGlobal(.{ .memory_op_total = .{ .op = "store", .result = "err" } });
            observability.recordMetricGlobal(.{ .memory_op_latency_ms = .{ .op = "store", .value = elapsed_ms } });
            return err;
        };
        const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_ms));
        const label: []const u8 = if (result.success) "ok" else "err";
        observability.recordMetricGlobal(.{ .memory_op_total = .{ .op = "store", .result = label } });
        observability.recordMetricGlobal(.{ .memory_op_latency_ms = .{ .op = "store", .value = elapsed_ms } });
        return result;
    }

    fn executeInner(self: *MemoryStoreTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");
        if (content.len == 0) return ToolResult.fail("'content' must not be empty");

        const session_id = resolveSessionId(args) catch |err| switch (err) {
            error.InvalidScope => return ToolResult.fail("Invalid 'scope' parameter. Expected 'session' or 'global'."),
            error.InvalidSessionId => return ToolResult.fail("Invalid 'session_id' parameter. Must be non-empty when provided."),
        };
        const category_explicit = root.getString(args, "category") != null;
        const category_str = root.getString(args, "category") orelse if (session_id == null) "core" else "daily";
        var category = MemoryCategory.fromString(category_str);

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

        // D55 (2026-05-24): optional ISO-8601 date for "when this fact
        // became true" — populates memory_edges.temporal_anchor_unix on
        // the triple path. Failure-soft: invalid/missing → null (write-
        // time fallback). Only applies when the triple path is taken;
        // the inline path doesn't write graph edges, so valid_at has no
        // attachment surface there.
        const valid_at_unix: ?i64 = extraction_persist.parseValidAtIso(root.getString(args, "valid_at"));

        if (has_triple) {
            if (self.state_mgr) |smgr| {
                if (self.user_id) |uid| {
                    return self.executeUnifiedWrite(allocator, smgr, uid, content, subj.?, pred.?, obj.?, session_id, valid_at_unix);
                }
            }
            // Triple supplied but no tenant context → fall through to inline
            // with a log hint so operators see the missed opportunity.
            std.log.scoped(.memory_store).info("memory_store.triple_supplied_but_no_tenant key={s} — using inline path", .{key});
        }

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot store: {s} = {s}", .{ key, content });
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        var effective_key: []const u8 = key;
        var owned_effective_key: ?[]u8 = null;
        defer if (owned_effective_key) |owned| allocator.free(owned);
        var derived_session_copy = false;
        if (session_id) |sid| {
            if (m.get(allocator, key) catch null) |existing| {
                defer existing.deinit(allocator);
                if (existing.session_id == null and existing.category == .core) {
                    owned_effective_key = try sessionScopedConflictKey(allocator, key, sid);
                    effective_key = owned_effective_key.?;
                    if (!category_explicit) category = .daily;
                    derived_session_copy = true;
                }
            }
        }

        // D52 Pillar 2 (2026-05-28, prod-readiness Sprint 1) — when
        // detection fires on the inline path (no triple supplied),
        // route through `storeWithMetadata` so `metadata->'pii_tags'`
        // is queryable by the `memory_purge_pii` tool. Backends without
        // metadata support gracefully degrade — `storeWithMetadata`
        // falls back to plain `store` (see memory/root.zig:1730). The
        // triple path is already PII-tagged inside
        // `extraction_persist.buildExtractionMetadata`.
        const pii_flags = pii_detect.detect(content);
        if (pii_flags.any()) {
            var meta_buf: std.ArrayListUnmanaged(u8) = .{};
            defer meta_buf.deinit(allocator);
            const w = meta_buf.writer(allocator);
            w.writeAll("{\"write_origin\":\"memory_store_tool\",") catch {
                return ToolResult.fail("Failed to build PII metadata");
            };
            pii_detect.writeTagsJson(w, pii_flags) catch {
                return ToolResult.fail("Failed to write PII tags");
            };
            w.writeAll("}") catch {
                return ToolResult.fail("Failed to close PII metadata");
            };
            m.storeWithMetadata(effective_key, content, category, session_id, meta_buf.items) catch |err| {
                std.log.scoped(.memory_store).warn("memory_store inline+metadata path failed key='{s}' err={s}", .{ effective_key, @errorName(err) });
                const msg = try std.fmt.allocPrint(allocator, "Failed to store memory '{s}': {s}", .{ effective_key, @errorName(err) });
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            };
        } else {
            m.store(effective_key, content, category, session_id) catch |err| {
                std.log.scoped(.memory_store).warn("memory_store inline path failed key='{s}' err={s}", .{ effective_key, @errorName(err) });
                const msg = try std.fmt.allocPrint(allocator, "Failed to store memory '{s}': {s}", .{ effective_key, @errorName(err) });
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            };
        }

        // Vector sync: embed and upsert. Surface the outcome to the agent
        // so it knows whether the memory is semantically retrievable yet
        // (synced / deferred) or only keyword-retrievable (skipped / failed).
        // Silent drop here caused trust erosion: "Stored memory" implied
        // full retrieval readiness when vector sync had failed.
        const sync_status: ?mem_root.MemoryRuntime.VectorSyncResult = if (self.mem_rt) |rt|
            rt.syncVectorAfterStore(allocator, effective_key, content)
        else
            null;

        const scope_label = if (session_id == null) "global" else "session";
        const session_suffix = if (session_id) |sid|
            try std.fmt.allocPrint(allocator, ", session_ref={x}", .{std.hash.Wyhash.hash(0, sid)})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(session_suffix);
        const key_note = if (derived_session_copy)
            try std.fmt.allocPrint(allocator, ", requested_key={s}, stored_key={s}", .{ key, effective_key })
        else
            try std.fmt.allocPrint(allocator, ", key={s}", .{effective_key});
        defer allocator.free(key_note);

        const msg = if (sync_status) |status| blk: {
            if (status.isSuccessOrDeferred() or status.isSkipped()) {
                break :blk try std.fmt.allocPrint(allocator, "Stored memory: {s} ({s}, scope={s}{s}{s}, vector_sync={s})", .{ effective_key, category.toString(), scope_label, session_suffix, key_note, status.toSlice() });
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "Stored memory: {s} ({s}, scope={s}{s}{s}, vector_sync={s}) — keyword retrieval works; semantic recall may miss this entry until sync recovers",
                .{ effective_key, category.toString(), scope_label, session_suffix, key_note, status.toSlice() },
            );
        } else try std.fmt.allocPrint(allocator, "Stored memory: {s} ({s}, scope={s}{s}{s})", .{ effective_key, category.toString(), scope_label, session_suffix, key_note });

        return ToolResult{ .success = true, .output = msg };
    }

    fn sessionScopedConflictKey(allocator: std.mem.Allocator, key: []const u8, session_id: []const u8) ![]u8 {
        const hash = std.hash.Wyhash.hash(0, session_id);
        return std.fmt.allocPrint(allocator, "{s}/session/{x}", .{ key, hash });
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
        valid_at_unix: ?i64,
    ) !ToolResult {
        const mems = [_]extraction_persist.ExtractedMemory{.{
            .text = content,
            .subject = subject,
            .predicate = predicate,
            .object = object,
            .attributed_to = "user", // memory_store is user-attributed by default
            .confidence = 0.95,
            // D55 (2026-05-24): pass-through of the agent-supplied
            // valid_at. null when caller didn't provide; the existing
            // memory_edges.temporal_anchor_unix persist plumbing
            // handles both cases.
            .temporal_anchor_unix = valid_at_unix,
        }};

        const judge_ctx: ?extraction_persist.JudgeContext = blk: {
            if (self.judge_provider) |jp| {
                if (self.judge_model_name) |jmn| {
                    break :blk extraction_persist.JudgeContext{ .provider = jp, .model_name = jmn, .cardinality_fastpath_enabled = self.cardinality_fastpath_enabled, .semantic_type_routing_enabled = self.semantic_type_routing_enabled };
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
            self.mem_rt, // V1.8-2: vector coverage on agent memory_store tool
            .memory_store_tool, // V1.14.12 (M1) — per-path telemetry tag
            0, // P3: not a boundary caller — no boundary ID
        ) catch |err| {
            std.log.scoped(.memory_store).warn("memory_store unified pipeline failed subject='{s}' predicate='{s}' err={s}", .{ subject, predicate, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to store memory via unified pipeline: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "lang") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "daily") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "scope=session") != null);

    const entry = (try mem.get(allocator, "lane_pref")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expect(entry.session_id != null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", entry.session_id.?);
    try std.testing.expectEqual(mem_root.MemoryCategory.daily, entry.category);
}

test "memory_store session conflict with global core creates scoped copy" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("operator_preference/context_probe_format", "global durable preference", .core, null);

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryStoreTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"operator_preference/context_probe_format\",\"content\":\"Context probes should print native/XML ratio.\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "stored_key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session_id=") == null);

    const global_entry = (try mem.get(allocator, "operator_preference/context_probe_format")) orelse return error.TestUnexpectedResult;
    defer global_entry.deinit(allocator);
    try std.testing.expect(global_entry.session_id == null);
    try std.testing.expectEqualStrings("global durable preference", global_entry.content);

    const entries = try mem.list(allocator, null, "agent:zaki-bot:user:1:main");
    defer mem_root.freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(std.mem.startsWith(u8, entries[0].key, "operator_preference/context_probe_format/session/"));
    try std.testing.expectEqualStrings("Context probes should print native/XML ratio.", entries[0].content);
    try std.testing.expectEqual(mem_root.MemoryCategory.daily, entries[0].category);

    var recall_tool = @import("memory_recall.zig").MemoryRecallTool{ .memory = mem };
    const recall = recall_tool.tool();
    const recall_args = try root.parseTestArgs("{\"query\":\"operator_preference/context_probe_format\"}");
    defer recall_args.deinit();
    const recall_result = try recall.execute(allocator, recall_args.value.object);
    defer if (recall_result.output.len > 0) allocator.free(recall_result.output);
    try std.testing.expect(recall_result.success);
    try std.testing.expect(std.mem.indexOf(u8, recall_result.output, "Context probes should print native/XML ratio.") != null);
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
