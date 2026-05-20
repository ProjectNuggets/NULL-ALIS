//! V1.12 — wiki_link agent tool.
//!
//! Wraps `agent/entity_pipeline.runOnTurn` so the agent (or a user-
//! invoked button via the gateway) can run the entity-mention extractor
//! on demand over arbitrary text.
//!
//! ## When the agent invokes this
//!
//! Rarely. As of V1.14.7, the entity_pipeline is no longer per-turn
//! auto-triggered (the every-3-turn enqueue site was removed). Entity
//! edges now land via Pass A drop-window extraction (compaction.zig
//! extractFromDropWindow), Pass C summary JSON tail, and inline session-
//! end persistExtracted. The agent does not need to call this manually
//! during normal turns. The tool exists primarily so that:
//!
//! 1. The agent CAN re-link a specific historical block of prose if a
//!    user asks ("ZAKI, reconnect the brain with what I just said").
//! 2. The /brain "Re-link this session" button can dispatch a tool
//!    invocation with full transparency (the user sees the tool call in
//!    the run log).
//! 3. Admin CLI (`nullalis admin wiki-relink ...`) shares the same code
//!    path — one entry, one log shape, one set of stats.
//!
//! ## Design contract
//!
//! - Multilingual: input text can be any language; the underlying
//!   pipeline handles it. NO surface-form pattern matching here.
//! - Idempotent: running twice over the same text adds the same edges
//!   the second time (existing upsertMemoryEdge ON CONFLICT logic just
//!   bumps weight by 1.0). This is correct: re-mentions are evidence.
//! - Async-safe: tool returns when the pipeline completes; never blocks
//!   on more than one LLM call (the extractor) plus N cosine resolutions.
//! - Failure-soft: any internal error is logged and reflected in the
//!   returned RunStats (failed_mentions counter), but the tool itself
//!   returns success=true with stats. Hard failure only on missing
//!   tenant context (no state_mgr or no user_id wired).

const std = @import("std");
const log = std.log.scoped(.wiki_link_tool);

const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const zaki_state = @import("../zaki_state.zig");
const entity_pipeline = @import("../agent/entity_pipeline.zig");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const embeddings = @import("../memory/vector/embeddings.zig");

pub const WikiLinkTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,
    /// LLM provider used for entity mention extraction. Same provider as
    /// the chat path — wired by tools/root.zig at agent boot.
    provider: ?Provider = null,
    /// Model name for the extraction call. Same model the agent uses for
    /// chat by default (Kimi K2.6); operators can override via config.
    model_name: ?[]const u8 = null,
    /// Embedding provider for cosine entity coreference. Reuses the
    /// existing memory_embeddings pipeline.
    embedder: ?embeddings.EmbeddingProvider = null,
    /// Per-extraction timeout. Defaults to 30s.
    timeout_secs: u32 = 30,

    pub const tool_name = "wiki_link";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "wiki_link tool.",
        .use_when = &.{
            "first scenario",
            "second scenario",
        },
        .do_not_use_for = &.{
            "web_search — for web queries",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("wiki_link", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Run the entity-mention extractor over a block of prose. Identifies " ++
        "named entities (people, organizations, projects, products, places, " ++
        "events, concepts), resolves them against the entity graph (cosine " ++
        "coreference), and emits co-occurrence edges. Multilingual — works " ++
        "in any language. Idempotent — re-running over the same text bumps " ++
        "edge weights, never duplicates rows. The agent rarely invokes this " ++
        "directly: every-3-turns auto-trigger handles forward-flow ingestion. " ++
        "Use this tool when the user explicitly asks the agent to 'reconnect' " ++
        "or 'relink' some prose, or when re-running over older content.";
    pub const tool_params =
        \\{"type":"object","properties":{"text":{"type":"string","description":"The prose to extract entity mentions from. Can be any length up to ~4KB; longer inputs are truncated."}},"required":["text"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *WikiLinkTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *WikiLinkTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const text = root.getString(args, "text") orelse
            return ToolResult.fail("Missing 'text' parameter");
        if (text.len == 0) return ToolResult.fail("'text' must not be empty");

        // Tenant + provider gates. Without these we cannot persist edges
        // or call the LLM.
        const smgr = self.state_mgr orelse
            return ToolResult.fail("wiki_link unavailable: state manager not wired");
        const uid = self.user_id orelse
            return ToolResult.fail("wiki_link unavailable: user_id not wired");
        const prov = self.provider orelse
            return ToolResult.fail("wiki_link unavailable: provider not wired");
        const mdl = self.model_name orelse
            return ToolResult.fail("wiki_link unavailable: model_name not wired");
        const emb = self.embedder orelse
            return ToolResult.fail("wiki_link unavailable: embedder not wired");

        // V1.14.3 (G-03 closure) — Manual tool invocation has no
        // session anchor (the agent calls this from arbitrary text the
        // user supplies). Pass null; the resulting edges have empty
        // `episodes[]` which is correct semantics for unanchored text.
        // Daemon's wiki_link worker (the per-3-turn enqueue path) does
        // pass session_id; that path produces traceable edges.
        const stats = entity_pipeline.runOnTurn(
            allocator,
            prov,
            mdl,
            smgr,
            emb,
            uid,
            text,
            self.timeout_secs,
            null, // V1.14.3: no episode anchor for manual invocation
        );

        // Render stats as a compact summary so the agent can echo it
        // verbatim if the user asked for confirmation.
        const summary = try std.fmt.allocPrint(
            allocator,
            "wiki_link: extracted {d} mentions, resolved {d} (minted {d}), emitted {d} edges, {d} failed (latency {d}ms)",
            .{
                stats.mentions_extracted,
                stats.entities_resolved,
                stats.entities_minted,
                stats.edges_emitted,
                stats.failed_mentions,
                stats.llm_latency_ms,
            },
        );

        log.info(
            "wiki_link.tool user={d} text_bytes={d} mentions={d} resolved={d} minted={d} edges={d} failed={d} latency_ms={d}",
            .{
                uid,
                text.len,
                stats.mentions_extracted,
                stats.entities_resolved,
                stats.entities_minted,
                stats.edges_emitted,
                stats.failed_mentions,
                stats.llm_latency_ms,
            },
        );

        return ToolResult{ .success = true, .output = summary };
    }
};

test "WikiLinkTool: tool_name + description present" {
    try std.testing.expectEqualStrings("wiki_link", WikiLinkTool.tool_name);
    try std.testing.expect(WikiLinkTool.tool_description.len > 100);
}

test "WikiLinkTool: tool_params valid JSON" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, WikiLinkTool.tool_params, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const props = parsed.value.object.get("properties").?;
    try std.testing.expect(props.object.contains("text"));
}

test "WikiLinkTool: execute fails clean without tenant" {
    const allocator = std.testing.allocator;
    var t = WikiLinkTool{};
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("text", .{ .string = "Hello Alfred" });
    const result = try t.execute(allocator, args);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(!result.success);
}

test "WikiLinkTool: execute fails clean on empty text" {
    const allocator = std.testing.allocator;
    var t = WikiLinkTool{};
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("text", .{ .string = "" });
    const result = try t.execute(allocator, args);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(!result.success);
}
