//! Executable form of docs/memory-contract.md's truth table.
//! One assertion per row. If you change a predicate or the doc, change this.
const std = @import("std");
const memory_root = @import("root.zig");
const context_builder = @import("../agent/context_builder.zig");
const extraction_runner = @import("../agent/extraction/runner.zig");

test "memory contract: assistant scaffold markers are rejected at the write boundary" {
    const rejected = [_][]const u8{
        "[[ZAKI_MEMORY_CONTEXT_V2]]private fuel[[/ZAKI_MEMORY_CONTEXT_V2]]",
        "prefix [[ zaki_doc_context_v1 ]] suffix",
        "<memory_for_turn>private fuel</memory_for_turn>",
        "<MEMORY_FOR_TURN role=\"context\">private fuel",
        "truncated private fuel</memory_for_turn>",
        "< /memory_context >truncated private fuel",
        "<memory_context>legacy private fuel</memory_context>",
    };
    for (rejected) |content| {
        try std.testing.expect(memory_root.containsAssistantScaffold(content));
    }

    const allowed = [_][]const u8{
        "User prefers concise answers.",
        "A legitimate note about memory architecture.",
        "Use [ZAKI] as the project label.",
        "The user typed memory_for_turn without an XML tag.",
    };
    for (allowed) |content| {
        try std.testing.expect(!memory_root.containsAssistantScaffold(content));
    }
}

test "memory contract: derived-artifact keys are semantic-bookkeeping, unembedded, brain-hidden but injectable" {
    const derived_keys = [_][]const u8{
        "summary_latest/main", "timeline_summary/main",
        "session_summary/s1",  "summary_fallback/s1",
    };
    for (derived_keys) |k| {
        try std.testing.expect(memory_root.isContinuitySummaryKey(k));
        try std.testing.expect(memory_root.isSemanticBookkeepingKey(k));
        try std.testing.expect(!memory_root.shouldEmbedMemoryEntry(k, "some content"));
        // Hidden from the /brain VIEW…
        try std.testing.expect(!memory_root.isBrainVisibleKey(k));
        // …but NOT default-hidden: they must stay injectable for warm-start (P4).
        try std.testing.expect(!memory_root.isDefaultHiddenMemoryKey(k));
    }
}

test "memory contract: bookkeeping keys are hidden from the /brain view" {
    const bookkeeping_keys = [_][]const u8{
        "audit_shell/2026-07-01", "__tombstone__/x",
        "compaction_summary/s1",  "autosave_user_1",
        "session_checkpoint_1",
    };
    for (bookkeeping_keys) |k| {
        try std.testing.expect(!memory_root.isBrainVisibleKey(k));
    }
    // The narrow default-hidden predicate covers only internal/audit/index families.
    try std.testing.expect(memory_root.isDefaultHiddenMemoryKey("audit_shell/2026-07-01"));
    try std.testing.expect(memory_root.isDefaultHiddenMemoryKey("__tombstone__/x"));
    try std.testing.expect(memory_root.isDefaultHiddenMemoryKey("autosave_user_1"));
    try std.testing.expect(!memory_root.isDefaultHiddenMemoryKey("compaction_summary/s1"));
    try std.testing.expect(memory_root.isDefaultHiddenMemoryKey("session_checkpoint_1"));
}

test "memory contract: history/ supersede-audit keys are append-only, unembedded, brain-hidden" {
    // Package 3 Task 1 (M2): editMemorySupersede writes a born-closed
    // `history/<key>/<ts>-<ns>` snapshot of the OLD version (fix-wave I2:
    // the nanosecond component keeps same-second edits collision-free). It
    // is bookkeeping — an internal audit trail of a superseded wording, not
    // user-facing knowledge — so it is append-only (immutable), never
    // embedded (the old wording must not compete with the live key at
    // recall), and hidden from the /brain view. The live key keeps current
    // truth.
    const k = "history/favorite_editor/1700000000-042117333";
    try std.testing.expect(memory_root.isAppendOnlyMemoryKey(k));
    try std.testing.expect(memory_root.isSystemManagedMemoryKey(k));
    try std.testing.expect(memory_root.isSemanticBookkeepingKey(k));
    try std.testing.expect(!memory_root.shouldEmbedMemoryEntry(k, "some content"));
    try std.testing.expect(!memory_root.isBrainVisibleKey(k));
}

test "memory contract: knowledge keys are visible, embeddable, and durable_fact is curable" {
    try std.testing.expect(!memory_root.isDefaultHiddenMemoryKey("favorite_editor"));
    try std.testing.expect(memory_root.shouldEmbedMemoryEntry("favorite_editor", "User prefers Helix"));
    // H1: durable_fact/* is user knowledge — curable despite system write-discipline.
    try std.testing.expect(memory_root.isEditableMemoryEntry("durable_fact/abc123", .{ .custom = "preference" }));
    try std.testing.expect(memory_root.isSystemManagedMemoryKey("durable_fact/abc123"));
}

test "memory contract: durability axis — EVERGREEN ⊂ DURABLE, open_loop decays but is durable" {
    for (memory_root.EVERGREEN_MEMORY_TYPES) |t| {
        try std.testing.expect(memory_root.isDurableMemoryType(t));
        try std.testing.expect(memory_root.isEvergreenMemoryType(t));
    }
    try std.testing.expect(memory_root.isDurableMemoryType("open_loop"));
    try std.testing.expect(!memory_root.isEvergreenMemoryType("open_loop"));
    try std.testing.expect(!memory_root.isDurableMemoryType("daily"));
}

test "memory contract: scaffold entity names are denied, near-misses are not" {
    try std.testing.expect(context_builder.isScaffoldEntityName("Brain Architecture"));
    try std.testing.expect(context_builder.isScaffoldEntityName("Memory Link Types"));
    try std.testing.expect(context_builder.isScaffoldEntityName("  working   memory ")); // normalized match
    for (memory_root.ALL_LINK_TYPES) |link_type| {
        try std.testing.expect(context_builder.isScaffoldEntityName(link_type));
    }
    const extended_scaffold_names = [_][]const u8{
        "Layer 3",       "Layer 4",          "Layer 5",      "Layer 6",      "Layer 7",
        "Brain graph",   "Canonical memory", "Dream cycle",  "File read",    "Knowledge graph",
        "Memory recall", "Memory timeline",  "Tool routing", "Vector index", "Web search",
    };
    for (extended_scaffold_names) |name| {
        try std.testing.expect(context_builder.isScaffoldEntityName(name));
    }
    try std.testing.expect(!context_builder.isScaffoldEntityName("Brain Architecture course"));
    try std.testing.expect(!context_builder.isScaffoldEntityName("MEMORY.md"));
    try std.testing.expect(!context_builder.isScaffoldEntityName("Acme Corp"));
}

test "memory contract: extraction persistence rejects non-relational sentinel predicates" {
    // extraction_persist imports memory/root, so importing it back from this
    // root-hosted contract test would create a module cycle. Pin the exact
    // write-boundary constant block instead: moving or removing either entry
    // now requires an intentional contract update.
    const source = @embedFile("../agent/extraction_persist.zig");
    const block_start = std.mem.indexOf(u8, source, "const REJECTED_PREDICATES") orelse
        return error.ContractSourceMissing;
    const block_tail = source[block_start..];
    const block_end = std.mem.indexOf(u8, block_tail, "};") orelse
        return error.ContractSourceMissing;
    const rejected_predicates = block_tail[0 .. block_end + 2];
    try std.testing.expect(std.mem.indexOf(u8, rejected_predicates, "\"NO_CONNECTION_FOUND\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected_predicates, "\"DESCRIPTION\"") != null);
}

test "memory contract: extraction tool denylist is exactly the contracted set" {
    const contracted = [_][]const u8{
        "memory_doctor",    "memory_maintain", "brain_graph",
        "context_snapshot", "trace_query",     "runtime_info",
        "memory_list",      "memory_timeline", "transcript_read",
    };
    try std.testing.expectEqual(contracted.len, extraction_runner.internal_extraction_tool_names.len);
    for (contracted) |name| {
        var found = false;
        for (extraction_runner.internal_extraction_tool_names) |t| {
            if (std.mem.eql(u8, name, t)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "memory contract: extraction denylist entries are real registered tools (no typo drift)" {
    const tools_root = @import("../tools/root.zig");
    const registry = tools_root.defaultMetadataRegistry();
    for (extraction_runner.internal_extraction_tool_names) |denied| {
        var found = false;
        for (registry) |meta| {
            if (std.mem.eql(u8, meta.name, denied)) found = true;
        }
        if (!found) {
            std.debug.print("denylist entry matches no registered tool: {s}\n", .{denied});
            return error.DenylistDrift;
        }
    }
}

test "memory contract: memory event retention is explicit opt-in" {
    const lifecycle = @import("../config_types.zig").MemoryLifecycleConfig{};
    try std.testing.expectEqual(@as(u32, 0), lifecycle.memory_events_retention_days);
}
