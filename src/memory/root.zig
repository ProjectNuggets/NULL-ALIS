//! Memory module — persistent knowledge storage for nullalis.
//!
//! Mirrors ZeroClaw's memory architecture:
//!   - Memory vtable interface (store, recall, get, list, forget, count)
//!   - MemoryEntry, MemoryCategory
//!   - Multiple backends: SQLite (FTS5), Markdown (file-based), None (no-op)
//!   - ResponseCache for LLM response deduplication
//!   - Document chunking for large markdown files

const std = @import("std");
const build_options = @import("build_options");
const config_types = @import("../config_types.zig");
const provider_api_key = @import("../providers/api_key.zig");
const util = @import("../util.zig");
const log = std.log.scoped(.memory);

// engines/ (Layer A: Primary Store)
pub const sqlite = if (build_options.enable_sqlite) @import("engines/sqlite.zig") else @import("engines/sqlite_disabled.zig");
pub const markdown = @import("engines/markdown.zig");
pub const none = @import("engines/none.zig");
pub const memory_lru = @import("engines/memory_lru.zig");
pub const lucid = if (build_options.enable_memory_lucid) @import("engines/lucid.zig") else struct {
    pub const LucidMemory = struct {};
};
pub const postgres = if (build_options.enable_postgres) @import("engines/postgres.zig") else struct {};
pub const redis = @import("engines/redis.zig");
pub const lancedb = if (build_options.enable_memory_lancedb) @import("engines/lancedb.zig") else struct {
    pub const LanceDbMemory = struct {};
};
pub const api = @import("engines/api.zig");
pub const registry = @import("engines/registry.zig");

// retrieval/ (Layer B: Retrieval Engine)
pub const retrieval = @import("retrieval/engine.zig");
pub const retrieval_qmd = @import("retrieval/qmd.zig");
pub const rrf = @import("retrieval/rrf.zig");
pub const query_expansion = @import("retrieval/query_expansion.zig");
pub const temporal_decay = @import("retrieval/temporal_decay.zig");
pub const mmr = @import("retrieval/mmr.zig");
pub const adaptive = @import("retrieval/adaptive.zig");
pub const llm_reranker = @import("retrieval/llm_reranker.zig");

// vector/ (Layer C: Vector Plane)
pub const vector = @import("vector/math.zig");
pub const vector_store = @import("vector/store.zig");
pub const embeddings = @import("vector/embeddings.zig");
pub const embeddings_gemini = @import("vector/embeddings_gemini.zig");
pub const embeddings_voyage = @import("vector/embeddings_voyage.zig");
pub const embeddings_ollama = @import("vector/embeddings_ollama.zig");
pub const provider_router = @import("vector/provider_router.zig");
pub const store_qdrant = @import("vector/store_qdrant.zig");
pub const store_pgvector = @import("vector/store_pgvector.zig");
pub const circuit_breaker = @import("vector/circuit_breaker.zig");
pub const outbox = @import("vector/outbox.zig");
pub const chunker = @import("vector/chunker.zig");

// lifecycle/ (Layer D: Runtime Orchestrator)
pub const cache = @import("lifecycle/cache.zig");
pub const semantic_cache = @import("lifecycle/semantic_cache.zig");
pub const hygiene = @import("lifecycle/hygiene.zig");
pub const snapshot = @import("lifecycle/snapshot.zig");
pub const rollout = @import("lifecycle/rollout.zig");
pub const migrate = @import("lifecycle/migrate.zig");
pub const diagnostics = @import("lifecycle/diagnostics.zig");
pub const summarizer = @import("lifecycle/summarizer.zig");

pub const SqliteMemory = sqlite.SqliteMemory;
pub const MarkdownMemory = markdown.MarkdownMemory;
pub const NoneMemory = none.NoneMemory;
pub const InMemoryLruMemory = memory_lru.InMemoryLruMemory;
pub const LucidMemory = lucid.LucidMemory;
pub const PostgresMemory = if (build_options.enable_postgres) postgres.PostgresMemory else struct {};
pub const RedisMemory = redis.RedisMemory;
pub const LanceDbMemory = lancedb.LanceDbMemory;
pub const ApiMemory = api.ApiMemory;
pub const ResponseCache = cache.ResponseCache;
pub const Chunk = chunker.Chunk;
pub const chunkMarkdown = chunker.chunkMarkdown;
pub const EmbeddingProvider = embeddings.EmbeddingProvider;
pub const NoopEmbedding = embeddings.NoopEmbedding;
pub const cosineSimilarity = vector.cosineSimilarity;
pub const ScoredResult = vector.ScoredResult;
pub const hybridMerge = vector.hybridMerge;
pub const HygieneReport = hygiene.HygieneReport;
pub const exportSnapshot = snapshot.exportSnapshot;
pub const hydrateFromSnapshot = snapshot.hydrateFromSnapshot;
pub const shouldHydrate = snapshot.shouldHydrate;
pub const BackendDescriptor = registry.BackendDescriptor;
pub const BackendConfig = registry.BackendConfig;
pub const BackendInstance = registry.BackendInstance;
pub const BackendCapabilities = registry.BackendCapabilities;
pub const findBackend = registry.findBackend;
pub const RetrievalCandidate = retrieval.RetrievalCandidate;
pub const RetrievalSourceAdapter = retrieval.RetrievalSourceAdapter;
pub const PrimaryAdapter = retrieval.PrimaryAdapter;
pub const RetrievalEngine = retrieval.RetrievalEngine;
pub const QmdAdapter = retrieval_qmd.QmdAdapter;
pub const rrfMerge = rrf.rrfMerge;
pub const applyTemporalDecay = temporal_decay.applyTemporalDecay;
pub const VectorStore = vector_store.VectorStore;
pub const VectorResult = vector_store.VectorResult;
pub const HealthStatus = vector_store.HealthStatus;
pub const SqliteSharedVectorStore = vector_store.SqliteSharedVectorStore;
pub const SqliteSidecarVectorStore = vector_store.SqliteSidecarVectorStore;
pub const QdrantVectorStore = store_qdrant.QdrantVectorStore;
pub const freeVectorResults = vector_store.freeVectorResults;
pub const VectorOutbox = outbox.VectorOutbox;
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const RolloutMode = rollout.RolloutMode;
pub const RolloutPolicy = rollout.RolloutPolicy;
pub const RolloutDecision = rollout.RolloutDecision;
pub const SqliteSourceEntry = migrate.SqliteSourceEntry;
pub const readBrainDb = migrate.readBrainDb;
pub const freeSqliteEntries = migrate.freeSqliteEntries;
pub const DiagnosticReport = diagnostics.DiagnosticReport;
pub const CacheStats = diagnostics.CacheStats;
pub const diagnoseRuntime = diagnostics.diagnose;
pub const formatDiagnosticReport = diagnostics.formatReport;

pub const InitRuntimeOptions = struct {
    providers: []const config_types.ProviderEntry = &.{},
    search_api_key_override: ?[]const u8 = null,
};

// Extended retrieval stages
pub const expandQuery = query_expansion.expandQuery;
pub const ExpandedQuery = query_expansion.ExpandedQuery;
pub const analyzeQuery = adaptive.analyzeQuery;
pub const AdaptiveConfig = adaptive.AdaptiveConfig;
pub const QueryAnalysis = adaptive.QueryAnalysis;
pub const RetrievalStrategy = adaptive.RetrievalStrategy;
pub const buildRerankPrompt = llm_reranker.buildRerankPrompt;
pub const parseRerankResponse = llm_reranker.parseRerankResponse;
pub const LlmRerankerConfig = llm_reranker.LlmRerankerConfig;

// Lifecycle: summarizer
pub const SummarizerConfig = summarizer.SummarizerConfig;
pub const SummaryResult = summarizer.SummaryResult;
pub const shouldSummarize = summarizer.shouldSummarize;
pub const buildSummarizationPrompt = summarizer.buildSummarizationPrompt;
pub const parseSummaryResponse = summarizer.parseSummaryResponse;
pub const hasUnverifiedExternalClaims = summarizer.hasUnverifiedExternalClaims;
pub const countRedFlagMatches = summarizer.countRedFlagMatches;

// Lifecycle: semantic cache
pub const SemanticCache = semantic_cache.SemanticCache;

// ── Session message types ─────────────────────────────────────────

pub const MessageEntry = struct {
    role: []const u8,
    content: []const u8,
};

pub const CompletionEvent = struct {
    id: []const u8,
    session_id: []const u8,
    channel: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    chat_id: ?[]const u8 = null,
    content: []const u8,

    pub fn deinit(self: *const CompletionEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        if (self.channel) |value| allocator.free(value);
        if (self.account_id) |value| allocator.free(value);
        if (self.chat_id) |value| allocator.free(value);
        allocator.free(self.content);
    }
};

pub fn freeMessages(allocator: std.mem.Allocator, messages: []MessageEntry) void {
    for (messages) |entry| {
        allocator.free(entry.role);
        allocator.free(entry.content);
    }
    allocator.free(messages);
}

pub fn freeCompletionEvents(allocator: std.mem.Allocator, events: []CompletionEvent) void {
    for (events) |event| {
        event.deinit(allocator);
    }
    allocator.free(events);
}

// ── SessionStore vtable interface ─────────────────────────────────

pub const SessionStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        saveMessage: *const fn (ptr: *anyopaque, session_id: []const u8, role: []const u8, content: []const u8) anyerror!void,
        loadMessages: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror![]MessageEntry,
        clearMessages: *const fn (ptr: *anyopaque, session_id: []const u8) anyerror!void,
        clearAutoSaved: *const fn (ptr: *anyopaque, session_id: ?[]const u8) anyerror!void,
        saveCompletionEvent: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8, channel: ?[]const u8, account_id: ?[]const u8, chat_id: ?[]const u8, content: []const u8) anyerror![]u8,
        loadCompletionEvents: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror![]CompletionEvent,
        deleteCompletionEvent: *const fn (ptr: *anyopaque, event_id: []const u8) anyerror!void,
    };

    pub fn saveMessage(self: SessionStore, session_id: []const u8, role: []const u8, content: []const u8) !void {
        return self.vtable.saveMessage(self.ptr, session_id, role, content);
    }

    pub fn loadMessages(self: SessionStore, allocator: std.mem.Allocator, session_id: []const u8) ![]MessageEntry {
        return self.vtable.loadMessages(self.ptr, allocator, session_id);
    }

    pub fn clearMessages(self: SessionStore, session_id: []const u8) !void {
        return self.vtable.clearMessages(self.ptr, session_id);
    }

    pub fn clearAutoSaved(self: SessionStore, session_id: ?[]const u8) !void {
        return self.vtable.clearAutoSaved(self.ptr, session_id);
    }

    pub fn saveCompletionEvent(self: SessionStore, allocator: std.mem.Allocator, session_id: []const u8, channel: ?[]const u8, account_id: ?[]const u8, chat_id: ?[]const u8, content: []const u8) ![]u8 {
        return self.vtable.saveCompletionEvent(self.ptr, allocator, session_id, channel, account_id, chat_id, content);
    }

    pub fn loadCompletionEvents(self: SessionStore, allocator: std.mem.Allocator, session_id: []const u8) ![]CompletionEvent {
        return self.vtable.loadCompletionEvents(self.ptr, allocator, session_id);
    }

    pub fn deleteCompletionEvent(self: SessionStore, event_id: []const u8) !void {
        return self.vtable.deleteCompletionEvent(self.ptr, event_id);
    }
};

// ── Memory categories ──────────────────────────────────────────────

pub const MemoryCategory = union(enum) {
    core,
    daily,
    conversation,
    custom: []const u8,

    pub fn toString(self: MemoryCategory) []const u8 {
        return switch (self) {
            .core => "core",
            .daily => "daily",
            .conversation => "conversation",
            .custom => |name| name,
        };
    }

    pub fn fromString(s: []const u8) MemoryCategory {
        if (std.mem.eql(u8, s, "core")) return .core;
        if (std.mem.eql(u8, s, "daily")) return .daily;
        if (std.mem.eql(u8, s, "conversation")) return .conversation;
        return .{ .custom = s };
    }

    pub fn eql(a: MemoryCategory, b: MemoryCategory) bool {
        const TagType = @typeInfo(MemoryCategory).@"union".tag_type.?;
        const tag_a: TagType = a;
        const tag_b: TagType = b;
        if (tag_a != tag_b) return false;
        if (tag_a == .custom) {
            return std.mem.eql(u8, a.custom, b.custom);
        }
        return true;
    }
};

// ── Link types ─────────────────────────────────────────────────────
//
// V1.7a-5 (spec seam 3) — high-level RELATIONSHIP CATEGORY for a memory's
// edge to its referenced entity/object. Distinct from `predicate` (the
// specific verb like REPLACES/PREFERS/USED_FOR). A small fixed vocabulary
// makes link_type machine-validatable + FE-renderable (color/icon coding,
// filtering, grouping).
//
// Single source of truth — used by:
//   - extraction_persist.linkTypeForPredicate (auto-classifies extracted facts)
//   - tools/compose_memory (optional explicit link_type arg)
//   - zaki_state SQL-side population (`metadata->>'link_type'` → column)
//   - zaki_state cmt16-style backfill for legacy rows
//   - agent prompt (renders the vocabulary block)
//   - gateway brain/memory/{key} surface
//
// Default for unknown predicates is `.attribute` — the broadest category;
// observability via `log.info` lets us grow the mapping when production
// surface forms reveal gaps.

pub const LinkType = enum {
    /// User likes/dislikes/values: PREFERS, LIKES, HATES, AVOIDS, FAVORS
    preference,
    /// Descriptive properties: BIRTHDAY, LIVES_IN, WORKS_AT, IS, HAS, AGE,
    /// CONTACT, ROLE. The default category for any predicate not otherwise mapped.
    attribute,
    /// This fact replaces/supersedes another: REPLACES, USED_TO_BE, FORMERLY,
    /// PREVIOUSLY. Pairs with V1.6 bi-temporal close-out.
    supersession,
    /// Entity↔entity: KNOWS, WORKS_WITH, MARRIED_TO, FRIENDS_WITH, MANAGES,
    /// REPORTS_TO, COLLABORATES_WITH.
    relationship,
    /// Uses/owns/consumes: USED_FOR, OWNS, USES, DEPENDS_ON, BUILDS_WITH.
    usage,
    /// compose_memory output — synthesized memory consolidating multiple sources.
    synthesis,
    /// Event-shaped memories: HAPPENED_ON, ATTENDED, OCCURRED_AT, JOINED.
    episode,

    pub fn toString(self: LinkType) []const u8 {
        return switch (self) {
            .preference => "preference",
            .attribute => "attribute",
            .supersession => "supersession",
            .relationship => "relationship",
            .usage => "usage",
            .synthesis => "synthesis",
            .episode => "episode",
        };
    }

    /// Parse a link_type string (case-insensitive on ASCII). Returns null
    /// for unknown values. Caller decides default-fallback policy.
    pub fn fromString(s: []const u8) ?LinkType {
        if (s.len == 0) return null;
        // Case-insensitive ASCII compare so agent inputs like "Preference"
        // or "PREFERENCE" parse correctly. Bounded buffer (longest enum
        // name is 12 chars: "supersession"/"relationship") so stack-only.
        var buf: [16]u8 = undefined;
        if (s.len > buf.len) return null;
        for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        const norm = buf[0..s.len];
        if (std.mem.eql(u8, norm, "preference")) return .preference;
        if (std.mem.eql(u8, norm, "attribute")) return .attribute;
        if (std.mem.eql(u8, norm, "supersession")) return .supersession;
        if (std.mem.eql(u8, norm, "relationship")) return .relationship;
        if (std.mem.eql(u8, norm, "usage")) return .usage;
        if (std.mem.eql(u8, norm, "synthesis")) return .synthesis;
        if (std.mem.eql(u8, norm, "episode")) return .episode;
        return null;
    }
};

/// Comptime-derivable list of all LinkType values as strings — used by
/// the agent prompt's `<link_types>` block, the compose_memory tool's
/// JSON-schema `enum` constraint, and the tool-description rendering.
pub const ALL_LINK_TYPES = [_][]const u8{
    "preference",
    "attribute",
    "supersession",
    "relationship",
    "usage",
    "synthesis",
    "episode",
};

test "LinkType.toString round-trips through fromString" {
    inline for (ALL_LINK_TYPES) |s| {
        const parsed = LinkType.fromString(s) orelse return error.UnexpectedNull;
        try std.testing.expectEqualStrings(s, parsed.toString());
    }
}

test "LinkType.fromString handles case insensitivity" {
    try std.testing.expectEqual(LinkType.preference, LinkType.fromString("PREFERENCE").?);
    try std.testing.expectEqual(LinkType.preference, LinkType.fromString("Preference").?);
    try std.testing.expectEqual(LinkType.attribute, LinkType.fromString("aTTRibute").?);
}

test "LinkType.fromString returns null for unknowns" {
    try std.testing.expect(LinkType.fromString("") == null);
    try std.testing.expect(LinkType.fromString("unknown") == null);
    try std.testing.expect(LinkType.fromString("preferences") == null); // typo: trailing s
    // Longer than buf size — must reject without panic
    try std.testing.expect(LinkType.fromString("aaaaaaaaaaaaaaaaaaa") == null);
}

// ── Memory entry ───────────────────────────────────────────────────

pub const MemoryEntry = struct {
    id: []const u8,
    key: []const u8,
    content: []const u8,
    category: MemoryCategory,
    timestamp: []const u8,
    session_id: ?[]const u8 = null,
    score: ?f64 = null,
    /// Sprint 8 (S8.1) — origin lane derived from session_id ("main" |
    /// "thread" | "task" | "cron" | "direct" | "group" | "channel" |
    /// "unknown"). Borrowed string-literal pointer from
    /// `laneFromSessionId(...)`; NOT allocated, NOT freed in deinit().
    /// Defaults to "unknown" so callers that don't set it remain valid.
    /// Populated by row readers when session_id is known; downstream
    /// callers can heuristically downweight cross-lane retrieval results.
    lane: []const u8 = "unknown",

    /// V1.5 day-2 (Graphiti bi-temporal pattern) — point in time when
    /// this memory entry stops being valid. `null` means "always valid"
    /// (the V1.5 default — every write leaves this null). V1.6's
    /// correction classifier and the user-facing MemoryViewer correction
    /// surface populate this with `extract(epoch from now())::bigint`
    /// when a fact is invalidated, leaving the row in place as audit
    /// evidence. Retrieval paths filter `valid_to IS NULL OR valid_to >
    /// now()` so superseded memories never reach the agent.
    ///
    /// Three downstream uses unlocked by this column:
    ///   1. **Correction primitive** — V1.6 classifier writes `valid_to`
    ///      when ADD/UPDATE/DELETE decisions land; the row stays as audit.
    ///   2. **Agent timeline narration** — the agent can construct a
    ///      truthful temporal account ("I learned X on Tue, you corrected
    ///      to Y on Fri") by reading both the always-valid current set
    ///      and the historical `valid_to IS NOT NULL` set together.
    ///      The `/brain/timeline` endpoint surfaces this; the agent's
    ///      retrieval path defaults to current-only.
    ///   3. **As-of queries** — "what did the agent believe last March?"
    ///      becomes one timestamp parameter (V2 feature).
    ///
    /// Stored as BIGINT (unix epoch seconds) in postgres + sqlite backends.
    /// Other engines (markdown/redis/lru/lancedb/lucid/none) carry the
    /// field via struct passthrough but **do not yet filter on read** —
    /// V1.6 will land filter-aware reads in those backends when the
    /// classifier starts populating `valid_to`. Today (V1.5 always-null)
    /// this gap is invisible since no backend has anything to filter.
    valid_to: ?i64 = null,

    /// Free all allocated strings owned by this entry.
    pub fn deinit(self: *const MemoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.content);
        allocator.free(self.timestamp);
        if (self.session_id) |sid| allocator.free(sid);
        switch (self.category) {
            .custom => |name| allocator.free(name),
            else => {},
        }
        // self.lane is a borrowed string literal — do not free.
        // self.valid_to is a value-type optional integer — nothing to free.
    }
};

pub const MemoryProvenance = struct {
    session_id: ?[]const u8 = null,
    channel: []const u8 = "unknown",
    lane: []const u8 = "unknown",
};

pub const TimelineIndexLine = struct {
    at: []const u8,
    channel: []const u8,
    lane: []const u8,
    session: []const u8,
    focus: []const u8,
    key: []const u8,
    chat_id: ?[]const u8 = null,

    pub fn deinit(self: *const TimelineIndexLine, allocator: std.mem.Allocator) void {
        allocator.free(self.at);
        allocator.free(self.channel);
        allocator.free(self.lane);
        allocator.free(self.session);
        allocator.free(self.focus);
        allocator.free(self.key);
        if (self.chat_id) |value| allocator.free(value);
    }
};

pub const StoredOriginMetadata = struct {
    origin_channel: ?[]const u8 = null,
    origin_lane: ?[]const u8 = null,
    legacy_channel: ?[]const u8 = null,
    legacy_lane: ?[]const u8 = null,
    chat_id: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
};

const LEGACY_WRAPPED_CHANNELS = [_][]const u8{
    "telegram",
    "slack",
    "discord",
    "whatsapp",
    "signal",
    "line",
    "lark",
    "mattermost",
    "zaki_app",
};

const LEGACY_WRAPPED_LANES = [_][]const u8{
    "main",
    "thread",
    "direct",
    "group",
    "channel",
    "task",
    "cron",
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []MemoryEntry) void {
    for (entries) |*entry| {
        entry.deinit(allocator);
    }
    allocator.free(entries);
}

/// V1.6 commit 7 — typed edge in the materialized graph (`memory_edges`
/// table). Mirrors the (subject, predicate, object) triples extracted by
/// compaction Pass C, but addressable as a real row (vs. JSONB-derived
/// reconstruction). Bi-temporal close-out cascades from
/// `setMemoryInvalidation` via `valid_to` mirroring the source memory.
pub const TypedEdge = struct {
    source_key: []const u8,
    target_key: []const u8,
    predicate: []const u8,
    confidence: f64 = 1.0,
    weight: f64 = 1.0,

    pub fn deinit(self: *const TypedEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.source_key);
        allocator.free(self.target_key);
        allocator.free(self.predicate);
    }
};

pub fn freeTypedEdges(allocator: std.mem.Allocator, edges: []TypedEdge) void {
    for (edges) |*e| e.deinit(allocator);
    allocator.free(edges);
}

/// V1.6 commit 8 — entity row in memory_entities. Returned by
/// findEntityByCosine when a cosine ≥ threshold neighbor exists for a
/// query embedding. The agent uses `id` as the stable target_key for
/// edges pointing at this entity. `similarity` reports the cosine
/// score that matched (1.0 = identical, ≥0.95 = coreferent per Mem0).
pub const EntityRow = struct {
    id: []const u8,
    name: []const u8,
    similarity: f64 = 0.0,

    pub fn deinit(self: *const EntityRow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

/// V1.7a-9a — edge row enriched with the metadata needed by the
/// communities label-propagation algorithm. Returned by
/// `listMemoryEdgesForCommunityCompute`. Mirrors `TypedEdge` plus the
/// `attribution` column (drives the user-vs-auto vote weighting per
/// 2026-05-03 graph-memory research synthesis: user-declared edges
/// vote more than auto-extracted ones).
///
/// `valid_from_unix` is the bigint event-time of edge creation; the
/// algorithm applies a recency decay to vote weight using it.
pub const CommunityEdge = struct {
    source_key: []const u8,
    target_key: []const u8,
    weight: f64,
    attribution: []const u8, // 'extraction_classifier' | 'compose_memory' | 'agent_tool' | ...
    valid_from_unix: i64,

    pub fn deinit(self: *const CommunityEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.source_key);
        allocator.free(self.target_key);
        allocator.free(self.attribution);
    }
};

pub fn freeCommunityEdges(allocator: std.mem.Allocator, edges: []CommunityEdge) void {
    for (edges) |*e| e.deinit(allocator);
    allocator.free(edges);
}

/// V1.7a-9a — one (key → community_id) assignment for batch-write via
/// `setMemoryCommunityIds`. Borrowed key — caller owns; PG uses it as
/// a parameter, no lifetime escapes the call.
pub const CommunityAssignment = struct {
    key: []const u8,
    community_id: i32,
};

/// V1.9-1 — result of a cascade-rename operation on the entity graph.
/// Returned by `state_mgr.cascadeRenameEntity(allocator, user_id,
/// old_name, new_name)`. Caller owns `old_id` + `new_id` via the
/// supplied allocator.
pub const CascadeRenameResult = struct {
    /// True when the old entity existed; false → no-op (rename target
    /// was a fresh write, not a rename of an existing entity).
    found_old: bool,
    /// 32-char hex entity_id (allocator-owned). Empty string when
    /// found_old=false.
    old_id: []u8,
    /// New entity_id after upsert (allocator-owned). When found_old=true
    /// AND case-only rename, equals old_id (cascade was a no-op).
    new_id: []u8,
    /// Number of new memory_edges rows written with substituted endpoint.
    edges_rewritten: usize,
    /// Number of pre-existing edges that got is_latest=false (matches
    /// edges_rewritten in the typical path; differs only when
    /// ON CONFLICT DO NOTHING swallowed a duplicate).
    edges_closed: usize,

    pub fn deinit(self: *const CascadeRenameResult, allocator: std.mem.Allocator) void {
        if (self.old_id.len > 0) allocator.free(self.old_id);
        if (self.new_id.len > 0) allocator.free(self.new_id);
    }
};

/// V1.9-2 — result of an explicit-pick contradiction resolution.
/// Returned by `state_mgr.resolveContradiction(user_id, loser_key,
/// winner_key)`. Pure value; no allocator owned slices.
pub const ResolveContradictionResult = struct {
    /// True when the loser_key existed at call time.
    loser_existed: bool,
    /// True when the winner_key existed at call time. False is not
    /// fatal — caller may have a fresh winner not yet written. The
    /// loser still gets closed regardless.
    winner_existed: bool,
    /// True when the loser was actually closed (false → loser
    /// didn't exist, no-op).
    loser_closed: bool,
};

/// V1.9-4 — result of temporal decay tick.
/// Returned by `state_mgr.temporalDecay(user_id, threshold_days,
/// half_life_days)`. Pure value; no allocator-owned slices.
pub const TemporalDecayResult = struct {
    /// Number of rows whose `confidence_score` was lowered.
    rows_decayed: usize,
    /// Mean amount each decayed row dropped (old - new). Useful for
    /// observability — "this tick decayed 47 rows by an average of
    /// 0.18 confidence each."
    avg_decay_amount: f64,
    /// Floor confidence — rows already at this floor are skipped
    /// (no further decay).
    floor: f64,
};

/// V1.9-7 — result of the proactive contradiction surveyor.
/// Returned by `state_mgr.surveyContradictions(allocator, user_id)`.
/// Caller frees via `deinit`.
pub const SurveyContradictionsResult = struct {
    /// Number of distinct (subject, predicate) tuples with >1
    /// is_latest=true edges pointing at different targets.
    conflicts_found: usize,
    /// Allocator-owned JSON array of conflicts. Each entry has shape
    /// `{"source":"<key>","predicate":"<pred>","targets":["<t1>",...]}`.
    /// Empty `[]` when zero conflicts. This is the payload written
    /// to the `pending_conflicts_v2` memory row for the loader to
    /// surface in warm context.
    conflicts_json: []u8,
    /// True when the survey wrote a fresh `pending_conflicts_v2`
    /// memory row. False → no conflicts → row was cleared (or no
    /// op when the row didn't exist).
    sentinel_written: bool,

    pub fn deinit(self: *const SurveyContradictionsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.conflicts_json);
    }
};

/// V1.9-3 — result of propagate_correction. Bidirectional: the
/// correction's metadata gets `superseded_targets` (list of keys it
/// flagged), each target's metadata gets `superseded_by_correction`
/// (the correction's key). Caller frees `target_keys` slice + each
/// inner []u8.
pub const PropagateCorrectionResult = struct {
    /// True when the correction_key existed.
    correction_existed: bool,
    /// Number of memory rows flagged as superseded.
    targets_flagged: usize,
    /// Keys of every memory row that was flagged. Caller frees
    /// each + the slice. Empty slice (allocated, len=0) when zero
    /// targets matched.
    target_keys: [][]u8,

    pub fn deinit(self: *const PropagateCorrectionResult, allocator: std.mem.Allocator) void {
        for (self.target_keys) |k| allocator.free(k);
        allocator.free(self.target_keys);
    }
};

/// V1.10-B — single prose memory fact for the LLM-judge surveyor.
/// One ProseFact == one durable_fact / timeline_summary / summary_latest
/// row that mentions the entity_pattern the agent is investigating.
///
/// Why a dedicated struct:
///   The judge prompt only needs (key, content, age) per row. The full
///   MemoryEntry decode path is overkill (joins to session, loads vectors,
///   etc.) and the judge prompt is character-bounded. ProseFact is the
///   minimal contract: enough to ask "do these contradict?" and tell us
///   which row to mark superseded.
///
/// Caller frees `key` + `content`; `updated_at_unix` is a value type.
pub const ProseFact = struct {
    /// Memory row key (e.g. `durable_fact/1778049787/0`).
    key: []u8,
    /// The full content the row asserts as truth.
    content: []u8,
    /// Unix timestamp of last update — surfaces "newer wins" hints to
    /// the LLM judge without requiring the judge to parse timestamps.
    updated_at_unix: i64,

    pub fn deinit(self: *const ProseFact, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.content);
    }
};

/// V1.10-B — free a slice of ProseFact + the outer slice in one call.
pub fn freeProseFacts(allocator: std.mem.Allocator, facts: []ProseFact) void {
    for (facts) |f| f.deinit(allocator);
    allocator.free(facts);
}

/// V1.7a-9a — owned community-name lookup row.
pub const CommunityName = struct {
    name: []u8,
    name_source: []u8, // 'llm' | 'fallback'
    member_count: u32,
    member_set_hash: []u8,
    generated_at_unix: i64,

    pub fn deinit(self: *const CommunityName, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.name_source);
        allocator.free(self.member_set_hash);
    }
};

/// V1.7a-9a — one row from listCommunities. Surfaces enough for the FE
/// to render a cluster legend without further round trips.
pub const CommunitySummary = struct {
    community_id: i32,
    name: ?[]u8, // null when not yet named
    name_source: ?[]u8, // 'llm' | 'fallback' | null
    member_count: u32,
    generated_at_unix: i64,

    pub fn deinit(self: *const CommunitySummary, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        if (self.name_source) |s| allocator.free(s);
    }
};

pub fn freeCommunitySummaries(allocator: std.mem.Allocator, summaries: []CommunitySummary) void {
    // V1.7a-9 review WR-07: defensive guard for empty-literal slices
    // (`&.{}`). The /brain/graph handler initializes
    // `community_summaries: []CommunitySummary = &.{}` and only
    // re-assigns on success; the always-fires defer would otherwise
    // call `allocator.free(empty_slice)`. Most allocators tolerate
    // this; some (e.g. fixed-buffer) panic. Cheap to guard here.
    if (summaries.len == 0) return;
    for (summaries) |*s| s.deinit(allocator);
    allocator.free(summaries);
}

/// V1.6 commit 13 — single row in memory_events as returned by
/// listEventsForMemoryKey. Powers the /brain/memory/{key} drilldown's
/// chronological event timeline. `payload_json` is the raw JSONB string
/// (pre-parsed at the FE — keeps the Zig surface allocator-light).
pub const MemoryEventRow = struct {
    id: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    created_at_unix: i64,

    pub fn deinit(self: *const MemoryEventRow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.event_type);
        allocator.free(self.payload_json);
    }
};

pub fn freeMemoryEventRows(allocator: std.mem.Allocator, rows: []MemoryEventRow) void {
    for (rows) |*r| r.deinit(allocator);
    allocator.free(rows);
}

/// V1.6 commit 14 (M4) — source attribution for a memory row. Returned
/// by getMemorySource and surfaced in /brain/memory/{key} drilldown.
/// Both fields are independently optional: a memory may have a session
/// origin without a snippet (e.g. agent_tool writes), or vice versa
/// (legacy data). Powers the FE's "where did this come from?" surface.
pub const MemorySource = struct {
    session_id: ?[]const u8,
    snippet: ?[]const u8,

    pub fn deinit(self: *const MemorySource, allocator: std.mem.Allocator) void {
        if (self.session_id) |s| allocator.free(s);
        if (self.snippet) |s| allocator.free(s);
    }
};

/// V1.6 commit 15 — aggregate "document" view over session summaries.
/// Powers /brain/documents — supermemory-style two-tier surface where
/// each document represents a session that produced memories. The FE
/// browses documents to drill into the memories derived from each.
///
/// `latest_excerpt` is a content excerpt (first ~200 chars) of the most
/// recent summary for this session — gives the FE a preview without a
/// second round trip per row.
pub const BrainDocument = struct {
    session_id: []const u8,
    summary_count: usize,
    latest_at_unix: i64,
    latest_excerpt: []const u8,

    pub fn deinit(self: *const BrainDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.latest_excerpt);
    }
};

pub fn freeBrainDocuments(allocator: std.mem.Allocator, docs: []BrainDocument) void {
    for (docs) |*d| d.deinit(allocator);
    allocator.free(docs);
}

pub const PromptBootstrapKeyPrefix = "__bootstrap.prompt.";
pub const TombstoneKeyPrefix = "__tombstone__/";

pub const PromptBootstrapDoc = struct {
    filename: []const u8,
    memory_key: []const u8,
};

pub const prompt_bootstrap_docs = [_]PromptBootstrapDoc{
    .{ .filename = "AGENTS.md", .memory_key = "__bootstrap.prompt.AGENTS.md" },
    .{ .filename = "SOUL.md", .memory_key = "__bootstrap.prompt.SOUL.md" },
    .{ .filename = "TOOLS.md", .memory_key = "__bootstrap.prompt.TOOLS.md" },
    .{ .filename = "IDENTITY.md", .memory_key = "__bootstrap.prompt.IDENTITY.md" },
    .{ .filename = "USER.md", .memory_key = "__bootstrap.prompt.USER.md" },
    .{ .filename = "HEARTBEAT.md", .memory_key = "__bootstrap.prompt.HEARTBEAT.md" },
    .{ .filename = "BOOTSTRAP.md", .memory_key = "__bootstrap.prompt.BOOTSTRAP.md" },
    .{ .filename = "MEMORY.md", .memory_key = "__bootstrap.prompt.MEMORY.md" },
};

pub fn promptBootstrapMemoryKey(filename: []const u8) ?[]const u8 {
    for (prompt_bootstrap_docs) |doc| {
        if (std.mem.eql(u8, doc.filename, filename)) return doc.memory_key;
    }
    return null;
}

/// Markdown backend keeps bootstrap identity in workspace files;
/// all other backends use backend-native key/value entries.
pub fn usesWorkspaceBootstrapFiles(memory_backend: ?[]const u8) bool {
    const backend = memory_backend orelse return true;
    return std.mem.eql(u8, backend, "markdown");
}

pub fn isInternalMemoryKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "autosave_user_") or
        std.mem.startsWith(u8, key, "autosave_assistant_") or
        std.mem.eql(u8, key, "last_hygiene_at") or
        std.mem.startsWith(u8, key, TombstoneKeyPrefix) or
        std.mem.startsWith(u8, key, PromptBootstrapKeyPrefix);
}

// ── Artifact role taxonomy (W1.3) ───────────────────────────────────────────
//
// The nine system-owned artifact classes collapse into three named roles:
//
//   continuity  — searchable, injectable, carries current product truth:
//                   summary_latest/{session_id}
//                   session_summary/{session_id}/{timestamp}
//                   timeline_summary/{session_id}/{timestamp}
//                   context_anchor_current
//                   durable_fact/{timestamp}/{idx}
//
//   audit       — cold deep-dive records, not injected by default:
//                   autosave_user_{nanoseconds}
//                   autosave_assistant_{nanoseconds}
//                   session_checkpoint_{nanoseconds}
//
//   index       — discovery surface, not normal semantic payload:
//                   timeline_index/current
//
// Anything not matched is user-authored memory (role = .user).
//
// `classifyArtifactKey` is the single source of truth. The predicates
// `isContinuityArtifactKey`, `isAuditArtifactKey`, and `isIndexArtifactKey`
// delegate to it. Orthogonal predicates (isInternalMemoryKey,
// isSystemManagedMemoryKey, isAppendOnlyMemoryKey) remain unchanged; they
// serve hiding, mutation-policy, and write-discipline concerns that cut
// across the role taxonomy.

pub const ArtifactRole = enum {
    continuity,
    audit,
    index,
    user,

    pub fn toSlice(self: ArtifactRole) []const u8 {
        return switch (self) {
            .continuity => "continuity",
            .audit => "audit",
            .index => "index",
            .user => "user",
        };
    }
};

pub fn classifyArtifactKey(key: []const u8) ArtifactRole {
    // Audit: autosave + checkpoint + tool execution audits
    if (std.mem.startsWith(u8, key, "autosave_user_")) return .audit;
    if (std.mem.startsWith(u8, key, "autosave_assistant_")) return .audit;
    if (std.mem.startsWith(u8, key, "session_checkpoint_")) return .audit;
    // V1.5.1: shell-tool execution audits — `audit_shell/{nanoseconds}`
    // written by `tools/shell.zig::recordShellAudit`. Shell exits +
    // commands are bookkeeping, not user-facing brain content.
    if (std.mem.startsWith(u8, key, "audit_shell/")) return .audit;

    // Index: discovery surfaces
    if (std.mem.eql(u8, key, "timeline_index/current")) return .index;

    // Continuity: injectable/searchable continuity artifacts
    if (std.mem.eql(u8, key, "context_anchor_current")) return .continuity;
    if (std.mem.startsWith(u8, key, "summary_latest/")) return .continuity;
    if (std.mem.startsWith(u8, key, "durable_fact/")) return .continuity;
    if (std.mem.startsWith(u8, key, "session_summary/")) return .continuity;
    if (std.mem.startsWith(u8, key, "timeline_summary/")) return .continuity;
    // iter33: iter29 families are continuity by design — they feed the same
    // warm-recall surface as timeline_summary. Without classification,
    // memory_list and diagnostics tag them as .user which is wrong.
    if (std.mem.startsWith(u8, key, "compaction_summary/")) return .continuity;
    if (std.mem.startsWith(u8, key, "summary_fallback/")) return .continuity;
    if (std.mem.startsWith(u8, key, "compaction_dropped/")) return .continuity;

    return .user;
}

pub fn isContinuityArtifactKey(key: []const u8) bool {
    return classifyArtifactKey(key) == .continuity;
}

pub fn isAuditArtifactKey(key: []const u8) bool {
    return classifyArtifactKey(key) == .audit;
}

pub fn isIndexArtifactKey(key: []const u8) bool {
    return classifyArtifactKey(key) == .index;
}

pub fn isDefaultHiddenMemoryKey(key: []const u8) bool {
    return isInternalMemoryKey(key) or
        isAuditArtifactKey(key) or
        isIndexArtifactKey(key);
}

/// Single source of truth for /brain/* hygiene.
///
/// Both `isBrainVisibleKey` (Zig path) and `zaki_state.BRAIN_USER_KEY_FILTER`
/// (SQL path) are derived from these two arrays. Editing one of these
/// arrays automatically updates BOTH the Zig predicate and the SQL
/// constant — drift between the two paths becomes a compile error rather
/// than a silent runtime divergence.
///
/// Add a new hidden family by appending to `BRAIN_HIDDEN_PREFIXES` (for
/// prefix matches) or `BRAIN_HIDDEN_EXACT_KEYS` (for exact matches).
/// No other edits needed.
pub const BRAIN_HIDDEN_PREFIXES = [_][]const u8{
    // audit
    "autosave_",
    "session_checkpoint_",
    "audit_shell/",
    // continuity
    "summary_latest/",
    "session_summary/",
    "timeline_summary/",
    "durable_fact/",
    "compaction_summary/",
    "summary_fallback/",
    "compaction_dropped/",
    // internal
    "__tombstone__/",
    "__bootstrap.prompt.",
};

pub const BRAIN_HIDDEN_EXACT_KEYS = [_][]const u8{
    "context_anchor_current",
    "timeline_index/current",
    "last_hygiene_at",
    // V1.7 conflict-surfacing sentinel — written by writePendingConflictMarker
    // with memory_type='core' so memory_loader picks it up at session start.
    // Without this entry, the row leaks to /brain/graph and /brain/timeline as
    // a user-visible "core memory" carrying machine-state JSON.
    "pending_conflicts",
};

/// True when a memory key represents authentic user-facing brain content.
///
/// The /brain/* surface (graph, timeline, daily-diff) is the user's window
/// into "what does ZAKI remember about ME". It must hide the agent's own
/// bookkeeping — continuity summaries, session checkpoints, autosaves,
/// tombstones, bootstrap prompts — none of which are about the user.
///
/// This is strictly more restrictive than `isDefaultHiddenMemoryKey`:
/// that helper exposes continuity artifacts (summary_latest,
/// timeline_summary) for agent retrieval. /brain/* hides those too,
/// because they're machine-state strings ("type=summary_latest
/// origin_channel=telegram ...") that pollute the user-facing surface.
///
/// SQL mirror at `zaki_state.zig::BRAIN_USER_KEY_FILTER` is comptime-
/// derived from the same `BRAIN_HIDDEN_PREFIXES` + `BRAIN_HIDDEN_EXACT_KEYS`
/// arrays — they cannot drift.
pub fn isBrainVisibleKey(key: []const u8) bool {
    for (BRAIN_HIDDEN_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return false;
    }
    for (BRAIN_HIDDEN_EXACT_KEYS) |exact| {
        if (std.mem.eql(u8, key, exact)) return false;
    }
    return true;
}

pub fn isSemanticBookkeepingKey(key: []const u8) bool {
    return isDefaultHiddenMemoryKey(key) or
        std.mem.eql(u8, key, "context_anchor_current");
}

pub fn shouldEmbedMemoryEntry(key: []const u8, content: []const u8) bool {
    if (isSemanticBookkeepingKey(key)) return false;
    const chunking = config_types.MemoryChunkingConfig{};
    // Use the same chars-per-token estimate as the chunker so entries that pass
    // this gate are guaranteed to fit within a single chunk (no silent truncation
    // by the embedding provider). Previously this used *3 while the chunker used
    // *4, causing valid content to be gated out unnecessarily.
    const max_bytes = @as(usize, chunking.max_tokens) * config_types.MemoryChunkingConfig.CHARS_PER_TOKEN;
    return content.len <= max_bytes;
}

pub fn isTombstoneKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, TombstoneKeyPrefix);
}

pub fn tombstoneTargetKey(key: []const u8) ?[]const u8 {
    if (!isTombstoneKey(key)) return null;
    const target = key[TombstoneKeyPrefix.len..];
    return if (target.len > 0) target else null;
}

pub fn isAppendOnlyMemoryKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "session_summary/") or
        std.mem.startsWith(u8, key, "timeline_summary/") or
        std.mem.startsWith(u8, key, "session_checkpoint_") or
        std.mem.eql(u8, key, "timeline_index/current") or
        std.mem.startsWith(u8, key, "autosave_user_") or
        std.mem.startsWith(u8, key, "autosave_assistant_") or
        // iter31: system-written continuity artifacts from iter29 compaction
        // persistence work. Append-only at construction; editable only via
        // explicit cleanup paths (memory_purge_topic, etc).
        std.mem.startsWith(u8, key, "compaction_summary/") or
        std.mem.startsWith(u8, key, "summary_fallback/") or
        std.mem.startsWith(u8, key, "compaction_dropped/");
}

pub fn isSystemManagedMemoryKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "context_anchor_current") or
        std.mem.startsWith(u8, key, "summary_latest/") or
        // V1.10 Gap B fix — timeline_summary IS continuity per the role
        // taxonomy at line ~864 ("searchable, injectable, carries current
        // product truth"). It was missing from this predicate by oversight,
        // which made some test assertions rely on the category gate in
        // isMutableMemoryEntry to keep timeline_summary protected. With the
        // category gate removed below (so daily-type user-namespace keys
        // become editable), timeline_summary needs to be explicitly listed
        // here to stay protected.
        std.mem.startsWith(u8, key, "timeline_summary/") or
        std.mem.startsWith(u8, key, "durable_fact/") or
        isAppendOnlyMemoryKey(key);
}

pub fn isMutableMemoryEntry(key: []const u8, category: MemoryCategory) bool {
    // Used by markdown engine paths (compaction/collapse) — they need the
    // tighter "core only" semantic to decide what to fold. Keep this
    // unchanged so engines continue to behave correctly.
    if (isTombstoneKey(key) or isMarkdownLineKey(key) or isAppendOnlyMemoryKey(key)) return false;
    return switch (category) {
        .core => true,
        else => false,
    };
}

pub fn isEditableMemoryEntry(key: []const u8, category: MemoryCategory) bool {
    // V1.10 Gap B fix — category-agnostic. Edit/archive/forget should
    // operate on ANY user-namespace key the agent has access to, not just
    // core-tier. Daily-type self-poll under user keys (e.g. the `project_
    // codename` Panther entries from April brainstorm) was previously
    // unkillable from the agent side because isMutableMemoryEntry refused
    // anything non-core. Internal / system-managed / append-only /
    // tombstone / markdown-line keys remain protected through the
    // structural checks below.
    _ = category;
    if (isTombstoneKey(key) or isMarkdownLineKey(key) or isAppendOnlyMemoryKey(key)) return false;
    if (isInternalMemoryKey(key) or isSystemManagedMemoryKey(key)) return false;
    return true;
}

pub const MemoryLifecycleStatus = enum {
    missing,
    editable,
    protected,
};

pub const MemoryLifecycleLookup = struct {
    status: MemoryLifecycleStatus,
    entry: ?MemoryEntry = null,

    pub fn deinit(self: *MemoryLifecycleLookup, allocator: std.mem.Allocator) void {
        if (self.entry) |*entry| entry.deinit(allocator);
    }
};

pub fn lookupMemoryLifecycleEntry(
    allocator: std.mem.Allocator,
    mem: Memory,
    key: []const u8,
) !MemoryLifecycleLookup {
    const existing = (try mem.get(allocator, key)) orelse return .{ .status = .missing };
    return .{
        .status = if (isEditableMemoryEntry(existing.key, existing.category)) .editable else .protected,
        .entry = existing,
    };
}

/// Returns true for markdown fallback line keys like "MEMORY:8".
/// These keys are parser artifacts (filename + line index), not stable user keys.
pub fn isMarkdownLineKey(key: []const u8) bool {
    if (!std.mem.startsWith(u8, key, "MEMORY:")) return false;
    const suffix = key["MEMORY:".len..];
    if (suffix.len == 0) return false;
    for (suffix) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

pub fn extractMarkdownMemoryKey(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (!std.mem.startsWith(u8, trimmed, "**")) return null;
    const rest = trimmed[2..];
    const suffix = std.mem.indexOf(u8, rest, "**:") orelse return null;
    if (suffix == 0) return null;
    return rest[0..suffix];
}

pub fn deriveSessionIdFromMemoryKey(key: []const u8) ?[]const u8 {
    const latest_prefix = "summary_latest/";
    if (std.mem.startsWith(u8, key, latest_prefix)) {
        const session_id = key[latest_prefix.len..];
        return if (session_id.len > 0) session_id else null;
    }

    // iter33: all per-session continuity artifacts follow the shape
    // `<family>/<session_id>/<suffix>` — extract the session_id from between
    // the family prefix and the final '/'. Without this helper recognizing
    // the iter29 families, memory_timeline's session filter silently rejects
    // compaction_summary/*, summary_fallback/*, and compaction_dropped/*.
    const session_scoped_prefixes = [_][]const u8{
        "session_summary/",
        "timeline_summary/",
        "compaction_summary/",
        "summary_fallback/",
        "compaction_dropped/",
    };
    for (session_scoped_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        const rest = key[prefix.len..];
        const slash_idx = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
        const session_id = rest[0..slash_idx];
        return if (session_id.len > 0) session_id else null;
    }
    return null;
}

pub fn isTimelineSummaryKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "timeline_summary/");
}

pub fn isSummaryLatestKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "summary_latest/");
}

pub fn parseTimelineSummaryTimestamp(key: []const u8) ?i64 {
    if (!isTimelineSummaryKey(key)) return null;
    const session_id = deriveSessionIdFromMemoryKey(key) orelse return null;
    const prefix_len = "timeline_summary/".len + session_id.len + 1;
    if (key.len <= prefix_len) return null;
    return std.fmt.parseInt(i64, key[prefix_len..], 10) catch null;
}

pub fn timelineSummaryPrefixForSession(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "timeline_summary/{s}/", .{session_id});
}

pub fn metadataValue(content: []const u8, prefix: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    }
    return null;
}

pub fn extractStoredOriginMetadata(content: []const u8) StoredOriginMetadata {
    return .{
        .origin_channel = metadataValue(content, "origin_channel="),
        .origin_lane = metadataValue(content, "origin_lane="),
        .legacy_channel = metadataValue(content, "channel="),
        .legacy_lane = metadataValue(content, "lane="),
        .chat_id = metadataValue(content, "origin_chat_id="),
        .account_id = metadataValue(content, "origin_account_id="),
    };
}

fn isKnownLegacyWrappedChannel(channel: []const u8) bool {
    for (LEGACY_WRAPPED_CHANNELS) |allowed| {
        if (std.mem.eql(u8, channel, allowed)) return true;
    }
    return false;
}

fn isKnownLegacyWrappedLane(lane: []const u8) bool {
    for (LEGACY_WRAPPED_LANES) |allowed| {
        if (std.mem.eql(u8, lane, allowed)) return true;
    }
    return false;
}

fn shouldUseLegacyWrappedFallback(key: []const u8) bool {
    return std.mem.eql(u8, key, "context_anchor_current") or
        isSummaryLatestKey(key) or
        std.mem.startsWith(u8, key, "session_summary/") or
        isTimelineSummaryKey(key);
}

fn legacyWrappedOriginFromSessionId(session_id: []const u8) ?MemoryProvenance {
    const app_prefix = "agent:zaki-bot:user:";
    if (!std.mem.startsWith(u8, session_id, app_prefix)) return null;

    const rest = session_id[app_prefix.len..];
    const user_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const lane_and_tail = rest[user_sep + 1 ..];
    const lane_sep = std.mem.indexOfScalar(u8, lane_and_tail, ':') orelse return null;
    const outer_lane = lane_and_tail[0..lane_sep];
    if (!std.mem.eql(u8, outer_lane, "thread") and !std.mem.eql(u8, outer_lane, "task") and !std.mem.eql(u8, outer_lane, "cron")) return null;

    const embedded = lane_and_tail[lane_sep + 1 ..];
    const channel_sep = std.mem.indexOfScalar(u8, embedded, ':') orelse return null;
    const embedded_channel = embedded[0..channel_sep];
    if (!isKnownLegacyWrappedChannel(embedded_channel)) return null;

    const embedded_lane = deriveExternalLaneFromSessionId(embedded);
    if (!isKnownLegacyWrappedLane(embedded_lane)) return null;

    return .{
        .session_id = session_id,
        .channel = embedded_channel,
        .lane = embedded_lane,
    };
}

pub fn parseTimelineIndexLine(allocator: std.mem.Allocator, line_raw: []const u8) !?TimelineIndexLine {
    const line = std.mem.trim(u8, line_raw, " \t\r\n");
    if (line.len == 0) return null;
    if (line[0] == '{') return try parseTimelineIndexJsonLine(allocator, line);
    if (!std.mem.startsWith(u8, line, "- ")) return null;
    const body = line[2..];
    const channel_marker = std.mem.indexOf(u8, body, " channel=") orelse return null;
    const lane_marker = std.mem.indexOf(u8, body, " lane=") orelse return null;
    const session_marker = std.mem.indexOf(u8, body, " session=") orelse return null;
    const focus_marker = std.mem.indexOf(u8, body, " focus=") orelse return null;
    const key_marker = std.mem.indexOf(u8, body, " key=") orelse return null;
    const at = body["at=".len..channel_marker];
    const channel = body[channel_marker + " channel=".len .. lane_marker];
    const lane = body[lane_marker + " lane=".len .. session_marker];

    if (key_marker > session_marker and focus_marker > key_marker) {
        const session = body[session_marker + " session=".len .. key_marker];
        const key = body[key_marker + " key=".len .. focus_marker];
        const focus = body[focus_marker + " focus=".len ..];
        if (at.len == 0 or session.len == 0 or key.len == 0) return null;
        return .{
            .at = try allocator.dupe(u8, at),
            .channel = try allocator.dupe(u8, channel),
            .lane = try allocator.dupe(u8, lane),
            .session = try allocator.dupe(u8, session),
            .focus = try allocator.dupe(u8, focus),
            .key = try allocator.dupe(u8, key),
        };
    }

    if (focus_marker > session_marker and key_marker > focus_marker) {
        const session = body[session_marker + " session=".len .. focus_marker];
        const focus = body[focus_marker + " focus=".len .. key_marker];
        const key = body[key_marker + " key=".len ..];
        if (at.len == 0 or session.len == 0 or key.len == 0) return null;
        return .{
            .at = try allocator.dupe(u8, at),
            .channel = try allocator.dupe(u8, channel),
            .lane = try allocator.dupe(u8, lane),
            .session = try allocator.dupe(u8, session),
            .focus = try allocator.dupe(u8, focus),
            .key = try allocator.dupe(u8, key),
        };
    }

    return null;
}

fn parseTimelineIndexJsonLine(allocator: std.mem.Allocator, line: []const u8) !?TimelineIndexLine {
    const at = try extractJsonStringFieldOwned(allocator, line, "at") orelse return null;
    errdefer allocator.free(at);
    const channel = try extractJsonStringFieldOwned(allocator, line, "channel") orelse return null;
    errdefer allocator.free(channel);
    const lane = try extractJsonStringFieldOwned(allocator, line, "lane") orelse return null;
    errdefer allocator.free(lane);
    const session = try extractJsonStringFieldOwned(allocator, line, "session") orelse return null;
    errdefer allocator.free(session);
    const focus = try extractJsonStringFieldOwned(allocator, line, "focus") orelse return null;
    errdefer allocator.free(focus);
    const key = try extractJsonStringFieldOwned(allocator, line, "key") orelse return null;
    errdefer allocator.free(key);
    const chat_id = try extractJsonStringFieldOwned(allocator, line, "chat_id");
    errdefer if (chat_id) |value| allocator.free(value);
    return .{
        .at = at,
        .channel = channel,
        .lane = lane,
        .session = session,
        .focus = focus,
        .key = key,
        .chat_id = chat_id,
    };
}

fn extractJsonStringField(line: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    var idx = start + needle.len;
    while (idx < line.len) : (idx += 1) {
        if (line[idx] == '"' and !isEscapedJsonQuote(line, idx)) {
            return line[start + needle.len .. idx];
        }
    }
    return null;
}

fn extractJsonStringFieldOwned(
    allocator: std.mem.Allocator,
    line: []const u8,
    field: []const u8,
) !?[]u8 {
    const raw = extractJsonStringField(line, field) orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var idx: usize = 0;
    while (idx < raw.len) : (idx += 1) {
        const ch = raw[idx];
        if (ch != '\\') {
            try out.append(allocator, ch);
            continue;
        }
        idx += 1;
        if (idx >= raw.len) return error.InvalidCharacter;
        switch (raw[idx]) {
            '"', '\\', '/' => try out.append(allocator, raw[idx]),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0C),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'u' => return error.NotSupported,
            else => return error.InvalidCharacter,
        }
    }
    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

fn isEscapedJsonQuote(line: []const u8, quote_idx: usize) bool {
    if (quote_idx == 0) return false;
    var idx = quote_idx;
    var backslashes: usize = 0;
    while (idx > 0) {
        idx -= 1;
        if (line[idx] != '\\') break;
        backslashes += 1;
    }
    return (backslashes % 2) == 1;
}

pub fn buildTimelineIndexJsonLine(allocator: std.mem.Allocator, row: TimelineIndexLine) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    try out.appendSlice(allocator, "\"at\":\"");
    try util.appendJsonEscaped(&out, allocator, row.at);
    try out.appendSlice(allocator, "\",\"session\":\"");
    try util.appendJsonEscaped(&out, allocator, row.session);
    try out.appendSlice(allocator, "\",\"key\":\"");
    try util.appendJsonEscaped(&out, allocator, row.key);
    try out.appendSlice(allocator, "\",\"channel\":\"");
    try util.appendJsonEscaped(&out, allocator, row.channel);
    try out.appendSlice(allocator, "\",\"lane\":\"");
    try util.appendJsonEscaped(&out, allocator, row.lane);
    if (row.chat_id) |chat_id| {
        try out.appendSlice(allocator, "\",\"chat_id\":\"");
        try util.appendJsonEscaped(&out, allocator, chat_id);
    }
    try out.appendSlice(allocator, "\",\"focus\":\"");
    try util.appendJsonEscaped(&out, allocator, row.focus);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

pub fn extractSummarySection(summary_text: []const u8, prefix: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, summary_text, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.startsWith(u8, line, prefix)) {
            return std.mem.trim(u8, line[prefix.len..], " \t\r\n");
        }
    }
    return "none";
}

pub fn extractSummaryListSection(
    allocator: std.mem.Allocator,
    summary_text: []const u8,
    header: []const u8,
) ![]u8 {
    const idx = std.mem.indexOf(u8, summary_text, header) orelse return allocator.dupe(u8, "none");
    const body = summary_text[idx + header.len ..];
    var iter = std.mem.splitScalar(u8, body, '\n');
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var count: usize = 0;
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "- ")) break;
        if (count > 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, std.mem.trim(u8, line[2..], " \t\r\n"));
        count += 1;
    }
    if (count == 0) return allocator.dupe(u8, "none");
    return out.toOwnedSlice(allocator);
}

pub fn deriveMemoryProvenance(session_id_opt: ?[]const u8, key: []const u8) MemoryProvenance {
    const session_id = session_id_opt orelse deriveSessionIdFromMemoryKey(key);
    if (session_id) |sid| {
        return .{
            .session_id = sid,
            .channel = deriveChannelFromSessionId(sid),
            .lane = deriveLaneFromSessionId(sid),
        };
    }
    return .{};
}

pub fn resolveStoredMemoryProvenance(content: []const u8, session_id_opt: ?[]const u8, key: []const u8) MemoryProvenance {
    const session_id = session_id_opt orelse deriveSessionIdFromMemoryKey(key);
    const stored = extractStoredOriginMetadata(content);
    const explicit_channel = stored.origin_channel;
    const explicit_lane = stored.origin_lane;
    const legacy_channel = if (shouldUseLegacyWrappedFallback(key)) stored.legacy_channel else null;
    const legacy_lane = if (shouldUseLegacyWrappedFallback(key)) stored.legacy_lane else null;

    if (explicit_channel != null or explicit_lane != null or legacy_channel != null or legacy_lane != null) {
        const derived = deriveMemoryProvenance(session_id, key);
        return .{
            .session_id = derived.session_id,
            .channel = explicit_channel orelse legacy_channel orelse derived.channel,
            .lane = explicit_lane orelse legacy_lane orelse derived.lane,
        };
    }

    if (session_id) |sid| {
        if (shouldUseLegacyWrappedFallback(key)) {
            if (legacyWrappedOriginFromSessionId(sid)) |legacy| return legacy;
        }
    }

    return deriveMemoryProvenance(session_id, key);
}

fn deriveExternalChannelFromSessionId(session_id: []const u8) []const u8 {
    const colon_idx = std.mem.indexOfScalar(u8, session_id, ':') orelse return "unknown";
    if (colon_idx == 0) return "unknown";
    return session_id[0..colon_idx];
}

fn deriveExternalLaneFromSessionId(session_id: []const u8) []const u8 {
    if (std.mem.indexOf(u8, session_id, ":thread:") != null) return "thread";
    if (std.mem.indexOf(u8, session_id, ":direct:") != null) return "direct";
    if (std.mem.indexOf(u8, session_id, ":group:") != null) return "group";
    if (std.mem.indexOf(u8, session_id, ":channel:") != null) return "channel";
    if (std.mem.indexOf(u8, session_id, ":task:") != null) return "task";
    if (std.mem.indexOf(u8, session_id, ":cron:") != null) return "cron";
    return "unknown";
}

fn deriveChannelFromSessionId(session_id: []const u8) []const u8 {
    const app_prefix = "agent:zaki-bot:user:";
    if (std.mem.startsWith(u8, session_id, app_prefix)) return "app";

    return deriveExternalChannelFromSessionId(session_id);
}

/// Sprint 8 (S8.1) — public alias so callers outside this module can
/// hydrate `MemoryEntry.lane` and `RetrievalCandidate.lane` consistently.
/// Returns a string literal: "main" | "thread" | "task" | "cron" |
/// "direct" | "group" | "channel" | "unknown". Never allocates; never
/// fails. Safe to assign directly to a `[]const u8` field with no free.
pub fn laneFromSessionId(session_id: []const u8) []const u8 {
    return deriveLaneFromSessionId(session_id);
}

fn deriveLaneFromSessionId(session_id: []const u8) []const u8 {
    const app_prefix = "agent:zaki-bot:user:";
    if (std.mem.startsWith(u8, session_id, app_prefix)) {
        const rest = session_id[app_prefix.len..];
        const user_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return "unknown";
        const lane = rest[user_sep + 1 ..];
        if (std.mem.eql(u8, lane, "main")) return "main";
        if (std.mem.startsWith(u8, lane, "thread:")) return "thread";
        if (std.mem.startsWith(u8, lane, "task:")) return "task";
        if (std.mem.startsWith(u8, lane, "cron:")) return "cron";
        return "unknown";
    }

    return deriveExternalLaneFromSessionId(session_id);
}

pub fn isInternalMemoryEntryKeyOrContent(key: []const u8, content: []const u8) bool {
    if (isDefaultHiddenMemoryKey(key)) return true;
    if (extractMarkdownMemoryKey(content)) |extracted| {
        if (isDefaultHiddenMemoryKey(extracted)) return true;
    }
    return false;
}

fn trimCandidatesToLimit(allocator: std.mem.Allocator, candidates: []RetrievalCandidate, limit: usize) ![]RetrievalCandidate {
    if (candidates.len <= limit) return candidates;

    // If allocation fails while trimming, free the original result to avoid leaks.
    errdefer retrieval.freeCandidates(allocator, candidates);

    var trimmed = try allocator.alloc(RetrievalCandidate, limit);
    for (candidates[0..limit], 0..) |candidate, i| {
        trimmed[i] = candidate;
    }
    for (candidates[limit..]) |*candidate| {
        candidate.deinit(allocator);
    }
    allocator.free(candidates);

    return trimmed;
}

// ── Memory vtable interface ────────────────────────────────────────

pub const Memory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        store: *const fn (ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void,
        recall: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry,
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry,
        list: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry,
        forget: *const fn (ptr: *anyopaque, key: []const u8) anyerror!bool,
        count: *const fn (ptr: *anyopaque) anyerror!usize,
        healthCheck: *const fn (ptr: *anyopaque) bool,
        deinit: *const fn (ptr: *anyopaque) void,
        /// V1.5 day-3 — optional write path that attaches a JSONB
        /// metadata blob to the row. Used by `compose_memory` to record
        /// `{"synthesized_by":"agent","references":["k1","k2"]}` alongside
        /// the synthesis content. When the backend doesn't support
        /// metadata (sqlite, markdown, lru, etc.), the wrapper falls
        /// back to plain `store` and silently drops the metadata —
        /// graceful degrade. Today only `zaki_postgres` (production
        /// path) implements this slot.
        store_with_metadata: ?*const fn (ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8, metadata_json: []const u8) anyerror!void = null,
    };

    pub fn name(self: Memory) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn store(self: Memory, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) !void {
        return self.vtable.store(self.ptr, key, content, category, session_id);
    }

    /// V1.5 day-3 — store with structured JSONB metadata attached.
    /// When the backend has the `store_with_metadata` vtable slot,
    /// uses it. Otherwise falls back to plain `store` (metadata
    /// silently dropped — graceful degrade). The compose_memory tool
    /// uses this; if the backend is sqlite/markdown/lru/etc., the
    /// content still lands but `references` won't surface in
    /// `/brain/graph` reference-edge generation.
    pub fn storeWithMetadata(
        self: Memory,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
        metadata_json: []const u8,
    ) !void {
        if (self.vtable.store_with_metadata) |fn_ptr| {
            return fn_ptr(self.ptr, key, content, category, session_id, metadata_json);
        }
        return self.vtable.store(self.ptr, key, content, category, session_id);
    }

    pub fn recall(self: Memory, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]MemoryEntry {
        return self.vtable.recall(self.ptr, allocator, query, limit, session_id);
    }

    pub fn get(self: Memory, allocator: std.mem.Allocator, key: []const u8) !?MemoryEntry {
        return self.vtable.get(self.ptr, allocator, key);
    }

    pub fn list(self: Memory, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) ![]MemoryEntry {
        return self.vtable.list(self.ptr, allocator, category, session_id);
    }

    pub fn forget(self: Memory, key: []const u8) !bool {
        return self.vtable.forget(self.ptr, key);
    }

    pub fn count(self: Memory) !usize {
        return self.vtable.count(self.ptr);
    }

    pub fn healthCheck(self: Memory) bool {
        return self.vtable.healthCheck(self.ptr);
    }

    pub fn deinit(self: Memory) void {
        self.vtable.deinit(self.ptr);
    }

    /// Hybrid search: combine keyword recall with optional vector similarity.
    /// This is a convenience method that wraps recall() and merges results.
    /// If an embedding provider is available, it can be used for vector search;
    /// otherwise falls back to keyword-only search via recall().
    pub fn search(self: Memory, allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]MemoryEntry {
        // For now, delegate to recall() which uses FTS5/keyword search.
        // When embeddings are integrated at a higher level, this serves as
        // the standard entry point that can be upgraded to hybrid search.
        return self.recall(allocator, query, limit, null);
    }
};

// ── MemoryRuntime — bundled memory + session store + capabilities ──

/// Resolved configuration snapshot — captures what was actually resolved during init.
/// Stored in MemoryRuntime for diagnostics, `/doctor`, and runtime inspection.
pub const ResolvedConfig = struct {
    primary_backend: []const u8,
    retrieval_mode: []const u8, // "disabled" | "keyword" | "hybrid"
    vector_mode: []const u8, // "none" | "sqlite_shared" | "sqlite_sidecar" | "qdrant" | "pgvector"
    embedding_provider: []const u8, // "none" | "openai" | "openrouter" | "together" | "gemini" | "voyage" | "ollama" | "local" | "auto"
    rollout_mode: []const u8,
    vector_sync_mode: []const u8, // "best_effort" | "durable_outbox"
    hygiene_enabled: bool,
    conversation_retention_days: u32,
    snapshot_enabled: bool,
    cache_enabled: bool,
    semantic_cache_enabled: bool,
    summarizer_enabled: bool,
    source_count: usize,
    fallback_policy: []const u8, // "degrade" | "fail_fast"
};

pub const MemoryRuntime = struct {
    memory: Memory,
    session_store: ?SessionStore,
    response_cache: ?*cache.ResponseCache,
    capabilities: BackendCapabilities,
    resolved: ResolvedConfig,

    // Internal: owned resources for cleanup
    _db_path: ?[*:0]const u8,
    _cache_db_path: ?[*:0]const u8,
    _engine: ?*retrieval.RetrievalEngine,
    _allocator: std.mem.Allocator,
    _search_enabled: bool = true,

    /// **D1.15 finding 3 fix (2026-04-26):** per-session warmup
    /// tracking. Pre-fix this was a single `atomic.Value(bool)`
    /// flag that flipped true on first `warmupSession` success,
    /// then short-circuited forever — but the runtime is shared
    /// across sessions (gateway.zig:1304, gateway.zig:1493), so
    /// later sessions would read "warm=true" without any
    /// session-specific warmup having run. The function takes a
    /// `session_id` parameter; the state must be keyed by it.
    ///
    /// `_warmup_mutex` protects `_warmed_sessions`. Every key in
    /// the map is owned by `_allocator` (duped on insert, freed on
    /// deinit). The map's empty initialization means the cost on
    /// runtimes that never warm is zero memory.
    _warmup_mutex: std.Thread.Mutex = .{},
    _warmed_sessions: std.StringHashMapUnmanaged(void) = .{},

    // P5: rollout policy
    _rollout_policy: rollout.RolloutPolicy = .{ .mode = .on, .canary_percent = 0, .shadow_percent = 0 },

    // Lifecycle: summarizer config
    _summarizer_cfg: summarizer.SummarizerConfig = .{},

    // Lifecycle: semantic cache (optional, extends response cache with cosine similarity)
    _semantic_cache: ?*semantic_cache.SemanticCache = null,
    _semantic_cache_db_path: ?[*:0]const u8 = null,
    _vector_user_id: ?i64 = null,

    // P3: vector plane components (all optional)
    _embedding_provider: ?embeddings.EmbeddingProvider = null,
    _vector_store: ?vector_store.VectorStore = null,
    _circuit_breaker: ?*circuit_breaker.CircuitBreaker = null,
    _outbox: ?*outbox.VectorOutbox = null,
    _sidecar_db_path: ?[*:0]const u8 = null,

    fn effectiveEngineTopK(limit: usize) u32 {
        return @intCast(@min(limit, @as(usize, std.math.maxInt(u32))));
    }

    /// **D1.15** — pre-warm retrieval-engine + embedding caches +
    /// vector store for `session_id`. Targets the 900ms variance flagged
    /// in `project_agent_turn_audit_followups.md` finding #1: first
    /// `memory_enrich` after session restore takes ~1044ms (cold);
    /// subsequent turns hit warm caches and finish in ~111ms.
    ///
    /// The warmup runs a small set of canned queries that exercise the
    /// hot path — semantic recall touches the embedding cache + vector
    /// store + RRF index. After warmup completes for a session,
    /// `_warmed_sessions` records the session_id so subsequent calls
    /// for the same session short-circuit; other sessions still need
    /// their own warmup pass.
    ///
    /// **D1.15 finding 3 fix (2026-04-26):** state is now per-session
    /// (was a single global atomic bool — would short-circuit later
    /// sessions on the shared runtime even though they hadn't warmed).
    ///
    /// Designed to run in a background thread spawned at session boot
    /// (the spawn wiring lands in a follow-up commit). Calling on the
    /// hot path is safe but redundant — the second call for the same
    /// session is a no-op.
    ///
    /// **Cost:** ~1 semantic search worth of work, single-shot per
    /// session. The amortized win is the elimination of the cold-
    /// start penalty on the user's first turn after restore.
    pub fn warmupSession(self: *MemoryRuntime, session_id: ?[]const u8) void {
        const key = session_id orelse "__no_session__";

        // Fast-path: check whether this session is already warm.
        {
            self._warmup_mutex.lock();
            defer self._warmup_mutex.unlock();
            if (self._warmed_sessions.contains(key)) return;
        }

        if (!self._search_enabled or self._engine == null) {
            // No engine to warm — mark this session as "warm enough"
            // so callers don't spin waiting for a no-op.
            self.markSessionWarmed(key);
            return;
        }

        // Canned queries that exercise the hot path. Kept short and
        // generic; the goal is to populate the embedding cache + RRF
        // ranking state, not to retrieve specific facts. Real
        // user-relevant pre-fetch (e.g. "what was this user asking
        // about last session") would need session-context awareness
        // and is a follow-up if the lean version proves insufficient.
        const seeds = [_][]const u8{ "context", "preferences", "recent" };

        var arena = std.heap.ArenaAllocator.init(self._allocator);
        defer arena.deinit();
        const a = arena.allocator();

        for (seeds) |seed| {
            const candidates = self.search(a, seed, 4, session_id) catch continue;
            // Discard results — only the side-effect of populating
            // the engine's caches matters here.
            _ = candidates;
        }

        self.markSessionWarmed(key);
    }

    /// **D1.15** — observability hook for callers that want to know
    /// whether warmup has completed for a specific session. Hot path
    /// can render a "warming up" badge or prefer degraded-fast
    /// results during the gap.
    pub fn warmupComplete(self: *MemoryRuntime, session_id: ?[]const u8) bool {
        const key = session_id orelse "__no_session__";
        self._warmup_mutex.lock();
        defer self._warmup_mutex.unlock();
        return self._warmed_sessions.contains(key);
    }

    /// Internal: record `key` in the warmed-sessions set. Allocator
    /// failures are logged but not propagated — failing to record
    /// "warmed" just means the next warmupSession call repeats the
    /// pre-fetch (idempotent at the cost of redundant work). Worse
    /// than blocking the user's request.
    fn markSessionWarmed(self: *MemoryRuntime, key: []const u8) void {
        self._warmup_mutex.lock();
        defer self._warmup_mutex.unlock();
        // Re-check under lock in case another thread raced us.
        if (self._warmed_sessions.contains(key)) return;
        const owned_key = self._allocator.dupe(u8, key) catch return;
        self._warmed_sessions.put(self._allocator, owned_key, {}) catch {
            self._allocator.free(owned_key);
        };
    }

    /// Internal: free all keys + the map. Called from `MemoryRuntime.deinit`.
    fn deinitWarmupSessions(self: *MemoryRuntime) void {
        self._warmup_mutex.lock();
        defer self._warmup_mutex.unlock();
        var it = self._warmed_sessions.keyIterator();
        while (it.next()) |k_ptr| self._allocator.free(k_ptr.*);
        self._warmed_sessions.deinit(self._allocator);
    }

    /// High-level search: uses rollout policy to decide keyword-only vs hybrid.
    pub fn search(self: *MemoryRuntime, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]RetrievalCandidate {
        if (!self._search_enabled) return allocator.alloc(RetrievalCandidate, 0);

        const decision = self._rollout_policy.decide(session_id);

        switch (decision) {
            .keyword_only => {
                // Bypass engine, use recall() directly
                const entries = try self.memory.recall(allocator, query, limit, session_id);
                defer freeEntries(allocator, entries);
                const candidates = try retrieval.entriesToCandidates(allocator, entries);
                self.hydrateThinCandidatesFromPrimary(allocator, candidates);
                return candidates;
            },
            .hybrid => {
                // Use engine if available, else fall back
                if (self._engine) |engine| {
                    engine.vector_user_id = self._vector_user_id;
                    const original_top_k = engine.top_k;
                    engine.top_k = effectiveEngineTopK(limit);
                    defer engine.top_k = original_top_k;
                    const candidates = try engine.search(allocator, query, session_id);
                    const trimmed = try trimCandidatesToLimit(allocator, candidates, limit);
                    self.hydrateThinCandidatesFromPrimary(allocator, trimmed);
                    return trimmed;
                }
                const entries = try self.memory.recall(allocator, query, limit, session_id);
                defer freeEntries(allocator, entries);
                const candidates = try retrieval.entriesToCandidates(allocator, entries);
                self.hydrateThinCandidatesFromPrimary(allocator, candidates);
                return candidates;
            },
            .shadow_hybrid => {
                // Run both, serve keyword result, log hybrid for comparison
                const keyword_entries = try self.memory.recall(allocator, query, limit, session_id);
                defer freeEntries(allocator, keyword_entries);
                const keyword_results = try retrieval.entriesToCandidates(allocator, keyword_entries);

                if (self._engine) |engine| {
                    engine.vector_user_id = self._vector_user_id;
                    const original_top_k = engine.top_k;
                    engine.top_k = effectiveEngineTopK(limit);
                    defer engine.top_k = original_top_k;
                    const hybrid_results = engine.search(allocator, query, session_id) catch |err| {
                        log.warn("shadow hybrid search failed: {}", .{err});
                        return keyword_results;
                    };
                    defer retrieval.freeCandidates(allocator, hybrid_results);

                    log.info("shadow: keyword={d} hybrid={d} results", .{ keyword_results.len, hybrid_results.len });
                }

                self.hydrateThinCandidatesFromPrimary(allocator, keyword_results);
                return keyword_results;
            },
        }
    }

    fn needsContentHydration(candidate: *const RetrievalCandidate) bool {
        if (candidate.key.len == 0) return false;
        return std.mem.eql(u8, candidate.content, candidate.key) and
            std.mem.eql(u8, candidate.snippet, candidate.key);
    }

    fn hydrateThinCandidateFromPrimary(self: *MemoryRuntime, allocator: std.mem.Allocator, candidate: *RetrievalCandidate) void {
        if (!needsContentHydration(candidate)) return;

        const entry = self.memory.get(allocator, candidate.key) catch return;
        if (entry) |owned_entry| {
            defer owned_entry.deinit(allocator);
            if (owned_entry.content.len == 0) return;

            const hydrated_content = allocator.dupe(u8, owned_entry.content) catch return;
            errdefer allocator.free(hydrated_content);
            const hydrated_snippet = allocator.dupe(u8, owned_entry.content) catch return;

            allocator.free(candidate.content);
            allocator.free(candidate.snippet);
            candidate.content = hydrated_content;
            candidate.snippet = hydrated_snippet;
        }
    }

    /// Replaces vector-style thin candidates (content/snippet equal to key)
    /// with canonical primary-memory content for richer previews and context.
    /// Bounded to the current search result set (already top-K).
    fn hydrateThinCandidatesFromPrimary(self: *MemoryRuntime, allocator: std.mem.Allocator, candidates: []RetrievalCandidate) void {
        for (candidates) |*candidate| {
            self.hydrateThinCandidateFromPrimary(allocator, candidate);
        }
    }

    /// Get current rollout mode.
    pub fn rolloutMode(self: *const MemoryRuntime) rollout.RolloutMode {
        return self._rollout_policy.mode;
    }

    pub fn setVectorUserScope(self: *MemoryRuntime, user_id: ?i64) void {
        self._vector_user_id = user_id;
        if (self._engine) |engine| {
            engine.vector_user_id = user_id;
        }
    }

    /// Best-effort vector sync after a store() call.
    /// Embeds the content and upserts into the vector store.
    /// Errors are caught and logged, never propagated.
    /// Outcome of a vector-sync attempt. Callers that need the result to
    /// reach the agent (tools/memory_store, tools/memory_edit) inspect this
    /// and include it in their ToolResult. Fire-and-forget callers may
    /// discard with `_ = rt.syncVectorAfterStore(...)`.
    pub const VectorSyncResult = enum {
        synced,
        deferred_to_outbox,
        enqueue_failed,
        skipped_not_embeddable,
        skipped_no_provider,
        skipped_no_vector_store,
        skipped_circuit_open,
        skipped_empty_embedding,
        failed_embed,
        failed_upsert,

        /// Returns true when the sync is either complete or reliably queued.
        /// Tools can rely on eventual retrieval when this is true.
        pub fn isSuccessOrDeferred(self: VectorSyncResult) bool {
            return self == .synced or self == .deferred_to_outbox;
        }

        /// Returns true when the sync was legitimately skipped (not a failure).
        /// Skipped means: not embeddable, no provider/store configured, or
        /// the content was empty after embedding. These are expected no-ops,
        /// not drops.
        pub fn isSkipped(self: VectorSyncResult) bool {
            return switch (self) {
                .skipped_not_embeddable,
                .skipped_no_provider,
                .skipped_no_vector_store,
                .skipped_circuit_open,
                .skipped_empty_embedding,
                => true,
                else => false,
            };
        }

        pub fn toSlice(self: VectorSyncResult) []const u8 {
            return switch (self) {
                .synced => "synced",
                .deferred_to_outbox => "deferred_to_outbox",
                .enqueue_failed => "enqueue_failed",
                .skipped_not_embeddable => "skipped_not_embeddable",
                .skipped_no_provider => "skipped_no_provider",
                .skipped_no_vector_store => "skipped_no_vector_store",
                .skipped_circuit_open => "skipped_circuit_open",
                .skipped_empty_embedding => "skipped_empty_embedding",
                .failed_embed => "failed_embed",
                .failed_upsert => "failed_upsert",
            };
        }
    };

    pub fn syncVectorAfterStore(self: *MemoryRuntime, allocator: std.mem.Allocator, key: []const u8, content: []const u8) VectorSyncResult {
        if (!shouldEmbedMemoryEntry(key, content)) return .skipped_not_embeddable;
        // Durable mode: enqueue and return (drain happens at turn boundaries / shutdown).
        if (self._outbox) |ob| {
            ob.enqueue(self._vector_user_id, key, "upsert") catch |err| {
                log.warn("outbox enqueue failed for key '{s}': {}", .{ key, err });
                return .enqueue_failed;
            };
            return .deferred_to_outbox;
        }

        const provider = self._embedding_provider orelse return .skipped_no_provider;
        const vs = self._vector_store orelse return .skipped_no_vector_store;

        // Check circuit breaker
        if (self._circuit_breaker) |cb| {
            if (!cb.allow()) return .skipped_circuit_open;
        }

        const emb = provider.embed(allocator, content) catch |err| {
            log.warn("vector sync embed failed for key '{s}': {}", .{ key, err });
            if (self._circuit_breaker) |cb| cb.recordFailure();
            return .failed_embed;
        };
        defer allocator.free(emb);

        if (self._circuit_breaker) |cb| cb.recordSuccess();
        if (emb.len == 0) return .skipped_empty_embedding;

        vs.upsertScoped(self._vector_user_id, key, emb) catch |err| {
            log.warn("vector sync upsert failed for key '{s}': {}", .{ key, err });
            return .failed_upsert;
        };
        return .synced;
    }

    /// Drain the durable outbox (if configured).
    /// Call periodically (e.g., after each agent turn).
    pub fn drainOutbox(self: *MemoryRuntime, allocator: std.mem.Allocator) u32 {
        const ob = self._outbox orelse return 0;
        const provider = self._embedding_provider orelse return 0;
        const vs = self._vector_store orelse return 0;
        return ob.drain(allocator, provider, vs, self._circuit_breaker) catch 0;
    }

    /// Best-effort delete from vector store after a forget() call.
    /// Errors are caught and logged, never propagated.
    pub fn deleteFromVectorStore(self: *MemoryRuntime, key: []const u8) void {
        if (self._outbox) |ob| {
            ob.enqueue(self._vector_user_id, key, "delete") catch |err| {
                log.warn("outbox enqueue failed for key '{s}': {}", .{ key, err });
            };
            return;
        }

        const vs = self._vector_store orelse return;
        vs.deleteScoped(self._vector_user_id, key) catch |err| {
            log.warn("vector store delete failed for key '{s}': {}", .{ key, err });
        };
    }

    /// Rebuild the entire vector store from primary memory entries.
    /// Used for recovery after vector store corruption, embedding model changes,
    /// or migration to a different vector store backend.
    /// Returns the number of entries reindexed, or 0 if no vector plane is configured.
    pub fn reindex(self: *MemoryRuntime, allocator: std.mem.Allocator) u32 {
        const provider = self._embedding_provider orelse return 0;
        const vs = self._vector_store orelse return 0;

        // List all entries from primary store
        const entries = self.memory.list(allocator, null, null) catch |err| {
            log.warn("reindex: failed to list primary entries: {}", .{err});
            return 0;
        };
        defer freeEntries(allocator, entries);

        var reindexed: u32 = 0;
        for (entries) |entry| {
            if (!shouldEmbedMemoryEntry(entry.key, entry.content)) continue;
            const emb = provider.embed(allocator, entry.content) catch |err| {
                log.warn("reindex: embed failed for key '{s}': {}", .{ entry.key, err });
                continue;
            };
            defer allocator.free(emb);
            if (emb.len == 0) continue;

            vs.upsertScoped(self._vector_user_id, entry.key, emb) catch |err| {
                log.warn("reindex: upsert failed for key '{s}': {}", .{ entry.key, err });
                continue;
            };
            reindexed += 1;
        }

        log.info("reindex complete: {d}/{d} entries reindexed", .{ reindexed, entries.len });
        return reindexed;
    }

    /// Enqueue a key for vector sync via the outbox (if configured).
    pub fn enqueueVectorSync(self: *MemoryRuntime, key: []const u8, operation: []const u8) void {
        const ob = self._outbox orelse return;
        ob.enqueue(self._vector_user_id, key, operation) catch |err| {
            log.warn("outbox enqueue failed for key '{s}': {}", .{ key, err });
        };
    }

    /// Get the summarizer configuration (for the agent/session layer to use).
    pub fn summarizerConfig(self: *const MemoryRuntime) summarizer.SummarizerConfig {
        return self._summarizer_cfg;
    }

    /// Get the semantic cache (for the agent/session layer to use).
    pub fn semanticCache(self: *MemoryRuntime) ?*semantic_cache.SemanticCache {
        return self._semantic_cache;
    }

    /// Run memory doctor diagnostics and return a report.
    pub fn diagnose(self: *MemoryRuntime) diagnostics.DiagnosticReport {
        return diagnostics.diagnose(self);
    }

    pub fn deinit(self: *MemoryRuntime) void {
        // Best-effort: drain any pending vector sync operations before teardown.
        // Must happen while embedding provider, vector store, and circuit breaker
        // are still alive (drainOutbox uses all three).
        _ = self.drainOutbox(self._allocator);

        // **D1.15 finding 3 fix (2026-04-26):** free per-session
        // warmup tracking. Owned keys + the map.
        self.deinitWarmupSessions();

        // Engine first: it holds references to P3 components (vector store,
        // embedding provider, circuit breaker) — must deinit before them.
        if (self._engine) |engine| {
            engine.deinit();
            self._allocator.destroy(engine);
        }

        // P3 cleanup (outbox borrows db from vector store or primary — deinit before them)
        if (self._outbox) |ob| {
            ob.deinit(); // handles owns_self destroy
        }
        if (self._circuit_breaker) |cb| {
            self._allocator.destroy(cb);
        }
        if (self._vector_store) |vs| {
            vs.deinitStore(); // vtable deinit handles owns_self destroy
        }
        if (self._sidecar_db_path) |p| self._allocator.free(std.mem.span(p));
        if (self._embedding_provider) |ep| {
            ep.deinit();
        }
        if (self._semantic_cache) |sc| {
            sc.deinit();
            self._allocator.destroy(sc);
        }
        if (self._semantic_cache_db_path) |p| self._allocator.free(std.mem.span(p));
        if (self.response_cache) |rc| {
            rc.deinit();
            self._allocator.destroy(rc);
        }
        if (self._cache_db_path) |p| self._allocator.free(std.mem.span(p));
        self.memory.deinit();
        if (self._db_path) |p| self._allocator.free(std.mem.span(p));
    }
};

/// Create a MemoryRuntime from a MemoryConfig and workspace directory.
/// Goes through the registry to find the backend, resolve paths, and
/// create the instance. Returns null on any error (unknown backend,
/// path resolution failure, backend init failure).
pub fn initRuntime(
    allocator: std.mem.Allocator,
    config: *const config_types.MemoryConfig,
    workspace_dir: []const u8,
) ?MemoryRuntime {
    return initRuntimeWithOptions(allocator, config, workspace_dir, .{});
}

fn providerNameForEmbeddingApiKey(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "google")) return "gemini";
    if (std.mem.eql(u8, provider_name, "google-gemini")) return "gemini";
    if (std.mem.eql(u8, provider_name, "together-ai")) return "together";
    if (std.mem.startsWith(u8, provider_name, "custom:")) {
        const base_url = provider_name["custom:".len..];
        if (std.mem.indexOf(u8, base_url, "openrouter.ai") != null) return "openrouter";
        if (std.mem.indexOf(u8, base_url, "api.openai.com") != null) return "openai";
        if (std.mem.indexOf(u8, base_url, "generativelanguage.googleapis.com") != null) return "gemini";
        if (std.mem.indexOf(u8, base_url, "api.together.xyz") != null) return "together";
    }
    return provider_name;
}

fn resolveEmbeddingApiKey(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    override_key: ?[]const u8,
    providers: []const config_types.ProviderEntry,
) ?[]u8 {
    const key_lookup = providerNameForEmbeddingApiKey(provider_name);

    if (providers.len > 0) {
        for (providers) |entry| {
            if (entry.api_key) |key| {
                if (std.mem.eql(u8, providerNameForEmbeddingApiKey(entry.name), key_lookup)) {
                    return allocator.dupe(u8, key) catch null;
                }
            }
        }
    }

    const provider_env_key = provider_api_key.resolveApiKey(allocator, key_lookup, null) catch null;
    if (provider_env_key) |key| return key;

    if (override_key) |explicit| {
        const resolved = provider_api_key.resolveApiKey(allocator, key_lookup, explicit) catch null;
        if (resolved) |key| return key;
    }

    return null;
}

pub fn initRuntimeWithOptions(
    allocator: std.mem.Allocator,
    config: *const config_types.MemoryConfig,
    workspace_dir: []const u8,
    opts: InitRuntimeOptions,
) ?MemoryRuntime {
    const desc = registry.findBackend(config.backend) orelse {
        const enabled_backends = registry.formatEnabledBackends(allocator) catch null;
        defer if (enabled_backends) |names| allocator.free(names);

        if (registry.isKnownBackend(config.backend)) {
            const engine_token = registry.engineTokenForBackend(config.backend) orelse config.backend;
            log.warn("memory backend '{s}' is configured but disabled in this build", .{config.backend});
            log.warn("rebuild with -Dengines={s} (or include it in your -Dengines=... list)", .{engine_token});
        } else {
            log.warn("unknown memory backend '{s}' — check config.memory.backend", .{config.backend});
            log.warn("known memory backends: {s}", .{registry.known_backends_csv});
        }
        if (enabled_backends) |names| {
            log.warn("enabled memory backends in this build: {s}", .{names});
        }
        return null;
    };

    const pg_cfg: ?config_types.MemoryPostgresConfig = if (std.mem.eql(u8, config.backend, "postgres")) config.postgres else null;
    const redis_cfg: ?config_types.MemoryRedisConfig = if (std.mem.eql(u8, config.backend, "redis")) config.redis else null;
    const api_cfg: ?config_types.MemoryApiConfig = if (std.mem.eql(u8, config.backend, "api")) config.api else null;
    const cfg = registry.resolvePaths(allocator, desc, workspace_dir, pg_cfg, redis_cfg, api_cfg) catch |err| {
        log.warn("memory path resolution failed for backend '{s}': {}", .{ config.backend, err });
        return null;
    };

    const instance = desc.create(allocator, cfg) catch |err| {
        log.warn("memory backend '{s}' init failed: {}", .{ config.backend, err });
        if (std.mem.eql(u8, config.backend, "sqlite") and err == error.MigrationFailed) {
            const db_path = if (cfg.db_path) |p| std.mem.span(p) else "(unknown path)";
            log.warn("sqlite migration failed for {s}", .{db_path});
            log.warn("common causes: database locked/read-only, corrupt sqlite file, or sqlite build without FTS5", .{});
            log.warn("hint: stop other nullalis processes; if needed, back up/remove the db file and retry", .{});
        }
        if (cfg.postgres_url) |pu| allocator.free(std.mem.span(pu));
        if (cfg.db_path) |p| allocator.free(std.mem.span(p));
        return null;
    };

    // ── Lifecycle: snapshot hydrate (before hygiene) ──
    if (config.lifecycle.auto_hydrate) {
        if (snapshot.shouldHydrate(allocator, instance.memory, workspace_dir)) {
            _ = snapshot.hydrateFromSnapshot(allocator, instance.memory, workspace_dir) catch |e| {
                log.warn("snapshot hydration failed: {}", .{e});
            };
        }
    }

    // ── Lifecycle: hygiene ──
    if (config.lifecycle.hygiene_enabled) {
        const hygiene_cfg = hygiene.HygieneConfig{
            .hygiene_enabled = true,
            .archive_after_days = config.lifecycle.archive_after_days,
            .purge_after_days = config.lifecycle.purge_after_days,
            .conversation_retention_days = config.lifecycle.conversation_retention_days,
            .workspace_dir = workspace_dir,
        };
        const report = hygiene.runIfDue(allocator, hygiene_cfg, instance.memory);

        // Snapshot after hygiene if configured and hygiene did work
        if (config.lifecycle.snapshot_on_hygiene and report.totalActions() > 0) {
            _ = snapshot.exportSnapshot(allocator, instance.memory, workspace_dir) catch |e| {
                log.warn("snapshot export after hygiene failed: {}", .{e});
            };
        }
    }

    // ── Lifecycle: response cache ──
    var resp_cache: ?*cache.ResponseCache = null;
    var cache_db_path: ?[*:0]const u8 = null;
    if (build_options.enable_sqlite and config.response_cache.enabled) blk: {
        const cp_slice = std.fs.path.joinZ(allocator, &.{ workspace_dir, "response_cache.db" }) catch break :blk;
        const cp: [*:0]const u8 = cp_slice.ptr;
        const rc = allocator.create(cache.ResponseCache) catch {
            allocator.free(std.mem.span(cp));
            break :blk;
        };
        rc.* = cache.ResponseCache.init(cp, config.response_cache.ttl_minutes, config.response_cache.max_entries) catch {
            allocator.destroy(rc);
            allocator.free(std.mem.span(cp));
            break :blk;
        };
        resp_cache = rc;
        cache_db_path = cp;
    }

    // ── Retrieval engine ──
    var engine: ?*retrieval.RetrievalEngine = null;
    if (config.search.enabled) build_engine: {
        const eng = allocator.create(retrieval.RetrievalEngine) catch break :build_engine;
        eng.* = retrieval.RetrievalEngine.init(allocator, config.search.query);

        // Add primary adapter unless QMD-only mode is explicitly requested.
        const include_primary = !config.qmd.enabled or config.qmd.include_default_memory;
        if (include_primary) {
            const primary = allocator.create(retrieval.PrimaryAdapter) catch {
                allocator.destroy(eng);
                break :build_engine;
            };
            primary.* = retrieval.PrimaryAdapter.init(instance.memory);
            primary.owns_self = true;
            primary.allocator = allocator;
            eng.addSource(primary.adapter()) catch {
                allocator.destroy(primary);
                eng.deinit();
                allocator.destroy(eng);
                break :build_engine;
            };
        }

        // QMD adapter (optional — alloc failure just skips it, engine remains usable)
        if (config.qmd.enabled) {
            if (allocator.create(retrieval_qmd.QmdAdapter)) |qmd| {
                qmd.* = retrieval_qmd.QmdAdapter.init(allocator, config.qmd, workspace_dir);
                qmd.owns_self = true;
                eng.addSource(qmd.adapter()) catch {
                    allocator.destroy(qmd);
                };
            } else |_| {}
        }

        // Configure extended pipeline stages (query expansion, adaptive, LLM reranker)
        eng.setRetrievalStages(config.retrieval_stages);

        engine = eng;
    }

    // ── P3: Vector plane wiring ──
    var embed_provider: ?embeddings.EmbeddingProvider = null;
    var vs_iface: ?vector_store.VectorStore = null;
    var cb_inst: ?*circuit_breaker.CircuitBreaker = null;
    var outbox_inst: ?*outbox.VectorOutbox = null;
    var sidecar_db_path: ?[*:0]const u8 = null;
    var resolved_vector_mode: []const u8 = "none";
    var resolved_vector_sync_mode: []const u8 = "best_effort";
    if (config.search.enabled and !std.mem.eql(u8, config.search.provider, "none") and config.search.query.hybrid.enabled) vec_plane: {
        const primary_api_key = resolveEmbeddingApiKey(
            allocator,
            config.search.provider,
            opts.search_api_key_override,
            opts.providers,
        );
        defer if (primary_api_key) |k| allocator.free(k);

        // 1. Create EmbeddingProvider (with optional fallback via ProviderRouter)
        const primary_ep = embeddings.createEmbeddingProvider(
            allocator,
            config.search.provider,
            primary_api_key,
            config.search.model,
            config.search.dimensions,
        ) catch break :vec_plane;

        embed_provider = primary_ep;

        // Wrap primary + fallback in a ProviderRouter when fallback is configured
        if (!std.mem.eql(u8, config.search.fallback_provider, "none") and
            config.search.fallback_provider.len > 0)
        wrap_router: {
            const fallback_api_key = resolveEmbeddingApiKey(
                allocator,
                config.search.fallback_provider,
                null,
                opts.providers,
            );
            defer if (fallback_api_key) |k| allocator.free(k);

            const fallback_ep = embeddings.createEmbeddingProvider(
                allocator,
                config.search.fallback_provider,
                fallback_api_key,
                config.search.model,
                config.search.dimensions,
            ) catch {
                log.warn("fallback embedding provider '{s}' init failed, using primary only", .{config.search.fallback_provider});
                break :wrap_router;
            };
            const router = provider_router.ProviderRouter.init(
                allocator,
                primary_ep,
                &.{fallback_ep},
                &.{},
            ) catch {
                fallback_ep.deinit();
                break :wrap_router;
            };
            embed_provider = router.provider();
        }

        // 2. Resolve vector store mode based on config.search.store.kind
        //    "auto"           → sqlite_shared if primary is sqlite-based, else sqlite_sidecar
        //    "qdrant"         → QdrantVectorStore via REST API
        //    "pgvector"       → PgvectorVectorStore via libpq (requires enable_postgres)
        //    "sqlite_shared"  → explicit sqlite shared (requires sqlite-based primary)
        //    "sqlite_sidecar" → explicit sqlite sidecar (separate vectors.db)
        var db_handle_for_outbox: ?*c.sqlite3 = null;
        const store_kind = config.search.store.kind;

        if (std.mem.eql(u8, store_kind, "qdrant")) {
            // Qdrant via REST API
            if (config.search.store.qdrant_url.len == 0) {
                log.warn("vector store kind 'qdrant' requires search.store.qdrant_url to be set", .{});
                break :vec_plane;
            }
            const qdrant = store_qdrant.QdrantVectorStore.init(allocator, .{
                .url = config.search.store.qdrant_url,
                .api_key = if (config.search.store.qdrant_api_key.len > 0) config.search.store.qdrant_api_key else null,
                .collection_name = config.search.store.qdrant_collection,
                .dimensions = config.search.dimensions,
            }) catch |err| {
                log.warn("qdrant vector store init failed: {}", .{err});
                break :vec_plane;
            };
            vs_iface = qdrant.store();
            resolved_vector_mode = "qdrant";
        } else if (std.mem.eql(u8, store_kind, "pgvector")) {
            // pgvector via PostgreSQL
            if (build_options.enable_postgres) {
                const pg_url = if (config.postgres.url.len > 0)
                    config.postgres.url
                else {
                    log.warn("vector store kind 'pgvector' requires postgres.url to be set", .{});
                    break :vec_plane;
                };
                const pgvs = store_pgvector.PgvectorVectorStore.init(allocator, .{
                    .connection_url = pg_url,
                    .schema_name = if (config.search.store.pgvector_schema.len > 0)
                        config.search.store.pgvector_schema
                    else
                        config.postgres.schema,
                    .table_name = config.search.store.pgvector_table,
                    .dimensions = config.search.dimensions,
                    .pool_max = config.postgres.pool_max,
                    .acquire_timeout_ms = config.postgres.acquire_timeout_ms,
                }) catch |err| {
                    log.warn("pgvector vector store init failed: {}", .{err});
                    break :vec_plane;
                };
                vs_iface = pgvs.store();
                resolved_vector_mode = "pgvector";
            } else {
                log.warn("vector store kind 'pgvector' requires build with enable_postgres=true", .{});
                break :vec_plane;
            }
        } else if (!build_options.enable_sqlite) {
            log.warn("vector store kind '{s}' requires build with enable_sqlite=true", .{store_kind});
            break :vec_plane;
        } else {
            // auto / sqlite_shared / sqlite_sidecar
            const use_shared = std.mem.eql(u8, store_kind, "auto") or std.mem.eql(u8, store_kind, "sqlite_shared");
            if (use_shared) {
                if (extractSqliteDb(instance.memory)) |db_handle| {
                    // sqlite_shared: reuse existing sqlite db handle
                    const vs = allocator.create(vector_store.SqliteSharedVectorStore) catch break :vec_plane;
                    vs.* = vector_store.SqliteSharedVectorStore.init(allocator, db_handle);
                    vs.owns_self = true;
                    vs_iface = vs.store();
                    db_handle_for_outbox = db_handle;
                    resolved_vector_mode = "sqlite_shared";
                } else if (std.mem.eql(u8, store_kind, "sqlite_shared")) {
                    log.warn("vector store kind 'sqlite_shared' requires a sqlite-based primary backend", .{});
                    break :vec_plane;
                }
                // else: auto fallthrough to sidecar below
            }

            // sqlite_sidecar: explicit or auto fallback for non-sqlite backends
            if (vs_iface == null) {
                const sidecar_path_slice = blk: {
                    const configured = config.search.store.sidecar_path;
                    if (configured.len == 0) {
                        break :blk std.fs.path.joinZ(allocator, &.{ workspace_dir, "vectors.db" }) catch break :vec_plane;
                    }
                    if (std.fs.path.isAbsolute(configured)) {
                        break :blk allocator.dupeZ(u8, configured) catch break :vec_plane;
                    }
                    break :blk std.fs.path.joinZ(allocator, &.{ workspace_dir, configured }) catch break :vec_plane;
                };
                const sidecar_path: [*:0]const u8 = sidecar_path_slice.ptr;
                const vs = allocator.create(vector_store.SqliteSidecarVectorStore) catch {
                    allocator.free(sidecar_path_slice);
                    break :vec_plane;
                };
                vs.* = vector_store.SqliteSidecarVectorStore.init(allocator, sidecar_path) catch {
                    allocator.destroy(vs);
                    allocator.free(sidecar_path_slice);
                    break :vec_plane;
                };
                vs.owns_self = true;
                vs_iface = vs.store();
                db_handle_for_outbox = vs.db; // sidecar's own db for outbox
                sidecar_db_path = sidecar_path;
                resolved_vector_mode = "sqlite_sidecar";
            }
        }

        // 3. Create CircuitBreaker
        const cb = allocator.create(circuit_breaker.CircuitBreaker) catch break :vec_plane;
        cb.* = circuit_breaker.CircuitBreaker.init(
            config.reliability.circuit_breaker_failures,
            config.reliability.circuit_breaker_cooldown_ms,
        );
        cb_inst = cb;

        // 4. Create VectorOutbox if not best_effort
        if (!std.mem.eql(u8, config.search.sync.mode, "best_effort")) {
            if (db_handle_for_outbox) |db_h| {
                const ob = allocator.create(outbox.VectorOutbox) catch break :vec_plane;
                const outbox_retries = @max(config.search.sync.embed_max_retries, config.search.sync.vector_max_retries);
                ob.* = outbox.VectorOutbox.init(allocator, db_h, outbox_retries);
                ob.owns_self = true;
                ob.migrate() catch {
                    allocator.destroy(ob);
                    break :vec_plane;
                };
                outbox_inst = ob;
                resolved_vector_sync_mode = "durable_outbox";
            }
        }

        // 5. Wire into retrieval engine
        if (engine) |eng| {
            eng.setVectorSearch(embed_provider.?, vs_iface.?, cb, config.search.query.hybrid);
        }
    }

    // Enforce fallback_policy: if fail_fast and vector plane was expected but failed, abort.
    if (std.mem.eql(u8, config.reliability.fallback_policy, "fail_fast")) {
        const vector_expected = config.search.enabled and
            !std.mem.eql(u8, config.search.provider, "none") and
            config.search.query.hybrid.enabled;
        const durable_requested = !std.mem.eql(u8, config.search.sync.mode, "best_effort");
        const vector_plane_failed = vector_expected and vs_iface == null;
        const durable_outbox_unavailable = vector_expected and durable_requested and outbox_inst == null;
        if (vector_plane_failed or durable_outbox_unavailable) {
            if (vector_plane_failed) {
                log.warn("fallback_policy=fail_fast: vector plane init failed, aborting runtime creation", .{});
            } else {
                log.warn("fallback_policy=fail_fast: durable vector sync unavailable, aborting runtime creation", .{});
            }
            // Clean up partially-created P3 resources
            if (outbox_inst) |ob| ob.deinit();
            if (vs_iface) |vs| vs.deinitStore();
            if (embed_provider) |ep| ep.deinit();
            if (cb_inst) |cb| allocator.destroy(cb);
            if (sidecar_db_path) |p| allocator.free(std.mem.span(p));
            // Clean up response cache
            if (resp_cache) |rc| {
                rc.deinit();
                allocator.destroy(rc);
            }
            if (cache_db_path) |p| allocator.free(std.mem.span(p));
            if (engine) |eng| {
                eng.deinit();
                allocator.destroy(eng);
            }
            instance.memory.deinit();
            if (cfg.postgres_url) |pu| allocator.free(std.mem.span(pu));
            if (cfg.db_path) |p| allocator.free(std.mem.span(p));
            return null;
        }
    }

    // Free postgres_url after backend creation (backend dupes what it needs)
    if (cfg.postgres_url) |pu| allocator.free(std.mem.span(pu));

    // ── Lifecycle: semantic cache ──
    var sem_cache: ?*semantic_cache.SemanticCache = null;
    var sem_cache_db_path: ?[*:0]const u8 = null;
    const legacy_semantic_cache_bridge = !config.semantic_cache.enabled and config.response_cache.enabled;
    const semantic_cache_requested = config.semantic_cache.enabled or legacy_semantic_cache_bridge;
    if (legacy_semantic_cache_bridge) {
        log.warn("semantic cache enabled via legacy memory.response_cache.enabled compatibility bridge; migrate to memory.semantic_cache.enabled", .{});
    }
    if (build_options.enable_sqlite and semantic_cache_requested and embed_provider != null) sem_cache_blk: {
        const sc_path = std.fs.path.joinZ(allocator, &.{ workspace_dir, "semantic_cache.db" }) catch break :sem_cache_blk;
        const sc = allocator.create(semantic_cache.SemanticCache) catch {
            allocator.free(std.mem.span(sc_path.ptr));
            break :sem_cache_blk;
        };
        sc.* = semantic_cache.SemanticCache.init(
            sc_path.ptr,
            config.semantic_cache.ttl_minutes,
            config.semantic_cache.max_entries,
            config.semantic_cache.similarity_threshold,
            embed_provider,
        ) catch {
            allocator.destroy(sc);
            allocator.free(std.mem.span(sc_path.ptr));
            break :sem_cache_blk;
        };
        sem_cache = sc;
        sem_cache_db_path = sc_path.ptr;
    }

    // ── Lifecycle: summarizer config ──
    const summarizer_cfg = summarizer.SummarizerConfig{
        .enabled = config.summarizer.enabled,
        .window_size_tokens = @intCast(config.summarizer.window_size_tokens),
        .summary_max_tokens = @intCast(config.summarizer.summary_max_tokens),
        .auto_extract_semantic = config.summarizer.auto_extract_semantic,
    };

    // ── Startup diagnostic ──
    const retrieval_mode: []const u8 = if (!config.search.enabled)
        "disabled"
    else if (config.search.query.hybrid.enabled)
        "hybrid"
    else
        "keyword";
    const source_count: usize = if (engine) |eng| eng.sources.items.len else 0;
    const vector_mode: []const u8 = if (vs_iface == null) "none" else resolved_vector_mode;
    const cache_enabled = resp_cache != null;
    const backend_runtime: []const u8 = instance.memory.name();
    log.info("memory plan resolved: configured_backend={s} runtime_backend={s} retrieval={s} vector={s} rollout={s} hygiene={} snapshot={} cache={} semantic_cache={} summarizer={} sources={d}", .{
        config.backend,
        backend_runtime,
        retrieval_mode,
        vector_mode,
        config.reliability.rollout_mode,
        config.lifecycle.hygiene_enabled,
        config.lifecycle.snapshot_enabled,
        cache_enabled,
        sem_cache != null,
        config.summarizer.enabled,
        source_count,
    });

    const embed_name: []const u8 = if (embed_provider) |ep_| ep_.getName() else "none";

    return .{
        .memory = instance.memory,
        .session_store = instance.session_store,
        .response_cache = resp_cache,
        .capabilities = desc.capabilities,
        .resolved = .{
            .primary_backend = config.backend,
            .retrieval_mode = retrieval_mode,
            .vector_mode = vector_mode,
            .embedding_provider = embed_name,
            .rollout_mode = config.reliability.rollout_mode,
            .vector_sync_mode = resolved_vector_sync_mode,
            .hygiene_enabled = config.lifecycle.hygiene_enabled,
            .conversation_retention_days = config.lifecycle.conversation_retention_days,
            .snapshot_enabled = config.lifecycle.snapshot_enabled,
            .cache_enabled = cache_enabled,
            .semantic_cache_enabled = sem_cache != null,
            .summarizer_enabled = config.summarizer.enabled,
            .source_count = source_count,
            .fallback_policy = config.reliability.fallback_policy,
        },
        ._db_path = cfg.db_path,
        ._cache_db_path = cache_db_path,
        ._engine = engine,
        ._allocator = allocator,
        ._search_enabled = config.search.enabled,
        ._rollout_policy = rollout.RolloutPolicy.init(config.reliability),
        ._summarizer_cfg = summarizer_cfg,
        ._semantic_cache = sem_cache,
        ._semantic_cache_db_path = sem_cache_db_path,
        ._embedding_provider = embed_provider,
        ._vector_store = vs_iface,
        ._circuit_breaker = cb_inst,
        ._outbox = outbox_inst,
        ._sidecar_db_path = sidecar_db_path,
    };
}

// ── Helpers ────────────────────────────────────────────────────────

const c = sqlite.c;

/// Extract the raw sqlite3* handle from a Memory vtable, if the backend is sqlite-based.
fn extractSqliteDb(mem: Memory) ?*c.sqlite3 {
    if (!build_options.enable_sqlite) return null;

    const name_str = mem.name();
    if (std.mem.eql(u8, name_str, "sqlite")) {
        const impl_: *SqliteMemory = @ptrCast(@alignCast(mem.ptr));
        return impl_.db;
    }
    if (build_options.enable_memory_lucid and std.mem.eql(u8, name_str, "lucid")) {
        const impl_: *LucidMemory = @ptrCast(@alignCast(mem.ptr));
        return impl_.local.db;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

const test_resolved_cfg: ResolvedConfig = .{
    .primary_backend = "test",
    .retrieval_mode = "keyword",
    .vector_mode = "none",
    .embedding_provider = "none",
    .rollout_mode = "off",
    .vector_sync_mode = "best_effort",
    .hygiene_enabled = false,
    .conversation_retention_days = 0,
    .snapshot_enabled = false,
    .cache_enabled = false,
    .semantic_cache_enabled = false,
    .summarizer_enabled = false,
    .source_count = 0,
    .fallback_policy = "degrade",
};

fn makeTestRetrievalCandidate(allocator: std.mem.Allocator, key: []const u8, content: []const u8, snippet: []const u8) !RetrievalCandidate {
    return .{
        .id = try allocator.dupe(u8, key),
        .key = try allocator.dupe(u8, key),
        .content = try allocator.dupe(u8, content),
        .snippet = try allocator.dupe(u8, snippet),
        .category = .daily,
        .keyword_rank = null,
        .vector_score = 0.84,
        .final_score = 0.016,
        .source = try allocator.dupe(u8, "vector"),
        .source_path = try allocator.dupe(u8, ""),
        .start_line = 0,
        .end_line = 0,
        .created_at = 0,
    };
}

test "classifyArtifactKey: continuity — summary_latest" {
    try std.testing.expectEqual(ArtifactRole.continuity, classifyArtifactKey("summary_latest/agent:zaki-bot:user:1:main"));
}

test "classifyArtifactKey: continuity — session_summary" {
    try std.testing.expectEqual(ArtifactRole.continuity, classifyArtifactKey("session_summary/agent:zaki-bot:user:1:main/1700000000"));
}

test "classifyArtifactKey: continuity — timeline_summary" {
    try std.testing.expectEqual(ArtifactRole.continuity, classifyArtifactKey("timeline_summary/agent:zaki-bot:user:1:main/1700000000"));
}

test "classifyArtifactKey: continuity — context_anchor_current" {
    try std.testing.expectEqual(ArtifactRole.continuity, classifyArtifactKey("context_anchor_current"));
}

test "classifyArtifactKey: continuity — durable_fact" {
    try std.testing.expectEqual(ArtifactRole.continuity, classifyArtifactKey("durable_fact/1700000000/0"));
}

test "classifyArtifactKey: audit — autosave_user" {
    try std.testing.expectEqual(ArtifactRole.audit, classifyArtifactKey("autosave_user_1700000000000000000"));
}

test "classifyArtifactKey: audit — autosave_assistant" {
    try std.testing.expectEqual(ArtifactRole.audit, classifyArtifactKey("autosave_assistant_1700000000000000000"));
}

test "classifyArtifactKey: audit — session_checkpoint" {
    try std.testing.expectEqual(ArtifactRole.audit, classifyArtifactKey("session_checkpoint_1700000000000000000"));
}

test "classifyArtifactKey: index — timeline_index/current" {
    try std.testing.expectEqual(ArtifactRole.index, classifyArtifactKey("timeline_index/current"));
}

test "classifyArtifactKey: user — arbitrary user memory key" {
    try std.testing.expectEqual(ArtifactRole.user, classifyArtifactKey("daily/2026-04-18/notes"));
    try std.testing.expectEqual(ArtifactRole.user, classifyArtifactKey("core/profile"));
}

test "role predicates agree with classifyArtifactKey" {
    try std.testing.expect(isContinuityArtifactKey("summary_latest/x"));
    try std.testing.expect(!isAuditArtifactKey("summary_latest/x"));
    try std.testing.expect(!isIndexArtifactKey("summary_latest/x"));

    try std.testing.expect(isAuditArtifactKey("autosave_user_1"));
    try std.testing.expect(!isContinuityArtifactKey("autosave_user_1"));
    try std.testing.expect(!isIndexArtifactKey("autosave_user_1"));

    try std.testing.expect(isIndexArtifactKey("timeline_index/current"));
    try std.testing.expect(!isContinuityArtifactKey("timeline_index/current"));
    try std.testing.expect(!isAuditArtifactKey("timeline_index/current"));
}

test "ArtifactRole.toSlice returns canonical names" {
    try std.testing.expectEqualStrings("continuity", ArtifactRole.continuity.toSlice());
    try std.testing.expectEqualStrings("audit", ArtifactRole.audit.toSlice());
    try std.testing.expectEqualStrings("index", ArtifactRole.index.toSlice());
    try std.testing.expectEqualStrings("user", ArtifactRole.user.toSlice());
}

test "MemoryCategory toString roundtrip" {
    const core: MemoryCategory = .core;
    try std.testing.expectEqualStrings("core", core.toString());

    const daily: MemoryCategory = .daily;
    try std.testing.expectEqualStrings("daily", daily.toString());

    const conversation: MemoryCategory = .conversation;
    try std.testing.expectEqualStrings("conversation", conversation.toString());

    const custom: MemoryCategory = .{ .custom = "project" };
    try std.testing.expectEqualStrings("project", custom.toString());
}

test "MemoryCategory fromString" {
    const core = MemoryCategory.fromString("core");
    try std.testing.expect(core.eql(.core));

    const daily = MemoryCategory.fromString("daily");
    try std.testing.expect(daily.eql(.daily));

    const conversation = MemoryCategory.fromString("conversation");
    try std.testing.expect(conversation.eql(.conversation));

    const custom = MemoryCategory.fromString("project");
    try std.testing.expectEqualStrings("project", custom.custom);
}

test "MemoryCategory equality" {
    const core: MemoryCategory = .core;
    try std.testing.expect(core.eql(.core));
    try std.testing.expect(!core.eql(.daily));
    const c1: MemoryCategory = .{ .custom = "a" };
    const c2: MemoryCategory = .{ .custom = "a" };
    const c3: MemoryCategory = .{ .custom = "b" };
    try std.testing.expect(c1.eql(c2));
    try std.testing.expect(!c1.eql(c3));
}

test "MemoryCategory custom toString" {
    const cat: MemoryCategory = .{ .custom = "my_project" };
    try std.testing.expectEqualStrings("my_project", cat.toString());
}

test "MemoryCategory fromString custom" {
    const cat = MemoryCategory.fromString("unknown_category");
    try std.testing.expectEqualStrings("unknown_category", cat.custom);
}

test "MemoryCategory eql different tags" {
    const core: MemoryCategory = .core;
    const daily: MemoryCategory = .daily;
    const conv: MemoryCategory = .conversation;
    try std.testing.expect(!core.eql(daily));
    try std.testing.expect(!core.eql(conv));
    try std.testing.expect(!daily.eql(conv));
}

test "Memory convenience store accepts session_id" {
    var backend = none.NoneMemory.init();
    defer backend.deinit();
    const m = backend.memory();
    try m.store("key", "value", .core, null);
    try m.store("key2", "value2", .daily, "session-abc");
}

test "Memory convenience recall accepts session_id" {
    var backend = none.NoneMemory.init();
    defer backend.deinit();
    const m = backend.memory();
    const results = try m.recall(std.testing.allocator, "query", 5, null);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);

    const results2 = try m.recall(std.testing.allocator, "query", 5, "session-abc");
    defer std.testing.allocator.free(results2);
    try std.testing.expectEqual(@as(usize, 0), results2.len);
}

test "Memory convenience list accepts session_id" {
    var backend = none.NoneMemory.init();
    defer backend.deinit();
    const m = backend.memory();
    const results = try m.list(std.testing.allocator, null, null);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);

    const results2 = try m.list(std.testing.allocator, .core, "session-abc");
    defer std.testing.allocator.free(results2);
    try std.testing.expectEqual(@as(usize, 0), results2.len);
}

test "SessionStore delegates through vtable" {
    const TestSessionStore = struct {
        call_count: usize = 0,

        fn implSaveMessage(ptr: *anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
        }
        fn implLoadMessages(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]MessageEntry {
            return allocator.alloc(MessageEntry, 0);
        }
        fn implClearMessages(ptr: *anyopaque, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
        }
        fn implClearAutoSaved(ptr: *anyopaque, _: ?[]const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
        }
        fn implSaveCompletionEvent(_: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8, _: []const u8) anyerror![]u8 {
            return allocator.dupe(u8, session_id);
        }
        fn implLoadCompletionEvents(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]CompletionEvent {
            return allocator.alloc(CompletionEvent, 0);
        }
        fn implDeleteCompletionEvent(ptr: *anyopaque, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
        }

        const sess_vtable = SessionStore.VTable{
            .saveMessage = &implSaveMessage,
            .loadMessages = &implLoadMessages,
            .clearMessages = &implClearMessages,
            .clearAutoSaved = &implClearAutoSaved,
            .saveCompletionEvent = &implSaveCompletionEvent,
            .loadCompletionEvents = &implLoadCompletionEvents,
            .deleteCompletionEvent = &implDeleteCompletionEvent,
        };
    };

    var mock = TestSessionStore{};
    const store = SessionStore{ .ptr = @ptrCast(&mock), .vtable = &TestSessionStore.sess_vtable };

    try store.saveMessage("s1", "user", "hello");
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    const msgs = try store.loadMessages(std.testing.allocator, "s1");
    defer std.testing.allocator.free(msgs);
    try std.testing.expectEqual(@as(usize, 0), msgs.len);

    try store.clearMessages("s1");
    try std.testing.expectEqual(@as(usize, 2), mock.call_count);

    try store.clearAutoSaved(null);
    try std.testing.expectEqual(@as(usize, 3), mock.call_count);

    const event_id = try store.saveCompletionEvent(std.testing.allocator, "s1", "zaki_app", null, "s1", "done");
    defer std.testing.allocator.free(event_id);
    try std.testing.expectEqualStrings("s1", event_id);

    const events = try store.loadCompletionEvents(std.testing.allocator, "s1");
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 0), events.len);

    try store.deleteCompletionEvent("event-1");
    try std.testing.expectEqual(@as(usize, 4), mock.call_count);
}

test "freeMessages frees all entries" {
    const allocator = std.testing.allocator;
    var messages = try allocator.alloc(MessageEntry, 2);
    messages[0] = .{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, "hello") };
    messages[1] = .{ .role = try allocator.dupe(u8, "assistant"), .content = try allocator.dupe(u8, "hi") };
    freeMessages(allocator, messages);
    // No leak = pass (allocator is testing allocator with leak detection)
}

fn requireBackendEnabledForTests(name: []const u8) !void {
    if (findBackend(name) == null) return error.SkipZigTest;
}

const TestTmpDir = @TypeOf(std.testing.tmpDir(.{}));
const TestWorkspace = struct {
    tmp: TestTmpDir,
    path: []u8,

    fn init(allocator: std.mem.Allocator) !TestWorkspace {
        var tmp = std.testing.tmpDir(.{});
        const path = try tmp.dir.realpathAlloc(allocator, ".");
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TestWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.tmp.cleanup();
    }
};

test "initRuntime none returns valid runtime" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expectEqualStrings("none", rt.memory.name());
    try std.testing.expect(rt.session_store == null);
    try std.testing.expect(!rt.capabilities.supports_session_store);
    try std.testing.expect(!rt.capabilities.supports_keyword_rank);
}

test "initRuntime unknown backend returns null" {
    try std.testing.expect(initRuntime(std.testing.allocator, &.{ .backend = "unknown_backend" }, "/tmp") == null);
}

test "initRuntime none deinit does not leak" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    rt.deinit();
    // testing allocator detects leaks — if we get here, no leak
}

test "initRuntime none has null db_path" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._db_path == null);
    try std.testing.expect(rt.response_cache == null);
}

test "initRuntime sqlite returns full runtime" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "sqlite" }, ws.path) orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expectEqualStrings("sqlite", rt.memory.name());
    try std.testing.expect(rt.session_store != null);
    try std.testing.expect(rt.capabilities.supports_session_store);
    try std.testing.expect(rt.capabilities.supports_keyword_rank);
    try std.testing.expect(rt.capabilities.supports_transactions);
    try std.testing.expect(rt._db_path != null);
    const path_slice = std.mem.span(rt._db_path.?);
    try std.testing.expect(std.mem.endsWith(u8, path_slice, "memory.db"));
}

test "initRuntime with lifecycle defaults does not crash" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp/test_lifecycle");
    if (rt) |*r| r.deinit();
}

test "initRuntime with cache disabled leaves response_cache null" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp/test_nocache") orelse return;
    defer rt.deinit();
    try std.testing.expect(rt.response_cache == null);
    try std.testing.expect(rt._cache_db_path == null);
}

test "initRuntime with cache enabled creates ResponseCache" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    try requireBackendEnabledForTests("none");

    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .response_cache = .{
            .enabled = true,
            .ttl_minutes = 5,
            .max_entries = 100,
        },
    }, ws.path) orelse return;
    defer rt.deinit();
    try std.testing.expect(rt.response_cache != null);
    try std.testing.expect(rt._cache_db_path != null);
}

test "initRuntime legacy response_cache bridge enables semantic cache" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    try requireBackendEnabledForTests("none");

    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .response_cache = .{
            .enabled = true,
        },
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._semantic_cache != null);
    try std.testing.expect(rt.resolved.semantic_cache_enabled);
}

test "initRuntime explicit semantic_cache enables semantic cache" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    try requireBackendEnabledForTests("none");

    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .semantic_cache = .{
            .enabled = true,
        },
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._semantic_cache != null);
    try std.testing.expect(rt.resolved.semantic_cache_enabled);
}

test "initRuntime creates engine with primary source" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();
    try std.testing.expect(rt._engine != null);
}

test "initRuntime engine with qmd disabled has one source" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();
    if (rt._engine) |eng| {
        try std.testing.expectEqual(@as(usize, 1), eng.sources.items.len);
    }
}

test "initRuntime engine with qmd enabled and include_default_memory=true has primary and qmd sources" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .qmd = .{
            .enabled = true,
            .include_default_memory = true,
        },
    }, "/tmp") orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    if (rt._engine) |eng| {
        try std.testing.expectEqual(@as(usize, 2), eng.sources.items.len);
        try std.testing.expectEqualStrings("primary", eng.sources.items[0].getName());
        try std.testing.expectEqualStrings("qmd", eng.sources.items[1].getName());
    } else return error.TestUnexpectedResult;
}

test "initRuntime engine with qmd enabled and include_default_memory=false has qmd-only source" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .qmd = .{
            .enabled = true,
            .include_default_memory = false,
        },
    }, "/tmp") orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    if (rt._engine) |eng| {
        try std.testing.expectEqual(@as(usize, 1), eng.sources.items.len);
        try std.testing.expectEqualStrings("qmd", eng.sources.items[0].getName());
    } else return error.TestUnexpectedResult;
}

test "MemoryRuntime.search without engine falls back to recall" {
    var backend = none.NoneMemory.init();
    defer backend.deinit();
    var rt = MemoryRuntime{
        .memory = backend.memory(),
        .session_store = null,
        .response_cache = null,
        .capabilities = .{ .supports_keyword_rank = false, .supports_session_store = false, .supports_transactions = false, .supports_outbox = false },
        .resolved = test_resolved_cfg,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = std.testing.allocator,
        ._embedding_provider = null,
        ._vector_store = null,
        ._circuit_breaker = null,
        ._outbox = null,
    };
    const results = try rt.search(std.testing.allocator, "query", 5, null);
    defer retrieval.freeCandidates(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "MemoryRuntime.search with engine delegates" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();
    const results = try rt.search(std.testing.allocator, "query", 5, null);
    defer retrieval.freeCandidates(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "MemoryRuntime.search hybrid path respects caller limit" {
    if (findBackend("memory") == null) return error.SkipZigTest;

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "memory" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();

    try rt.memory.store("k1", "alpha one", .core, null);
    try rt.memory.store("k2", "alpha two", .core, null);
    try rt.memory.store("k3", "alpha three", .core, null);

    rt._rollout_policy = .{ .mode = .on, .canary_percent = 0, .shadow_percent = 0 };

    const results = try rt.search(std.testing.allocator, "alpha", 1, null);
    defer retrieval.freeCandidates(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "MemoryRuntime.search shadow hybrid restores engine top_k after caller override" {
    var backend = memory_lru.InMemoryLruMemory.init(std.testing.allocator, 32);
    defer backend.deinit();

    const mem = backend.memory();
    var engine = retrieval.RetrievalEngine.init(std.testing.allocator, .{ .max_results = 2 });
    defer engine.deinit();
    var primary = retrieval.PrimaryAdapter.init(mem);
    try engine.addSource(primary.adapter());

    try mem.store("k1", "alpha one", .core, null);
    try mem.store("k2", "alpha two", .core, null);
    try mem.store("k3", "alpha three", .core, null);

    var rt = MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = .{
            .primary_backend = "memory",
            .retrieval_mode = "hybrid",
            .vector_mode = "none",
            .embedding_provider = "none",
            .rollout_mode = "shadow",
            .vector_sync_mode = "best_effort",
            .hygiene_enabled = false,
            .conversation_retention_days = 0,
            .snapshot_enabled = false,
            .cache_enabled = false,
            .semantic_cache_enabled = false,
            .summarizer_enabled = false,
            .source_count = 1,
            .fallback_policy = "degrade",
        },
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = &engine,
        ._allocator = std.testing.allocator,
        ._rollout_policy = .{ .mode = .shadow, .canary_percent = 0, .shadow_percent = 100 },
    };

    const original_top_k = engine.top_k;
    const results = try rt.search(std.testing.allocator, "alpha", 3, null);
    defer retrieval.freeCandidates(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqual(original_top_k, engine.top_k);
}

test "MemoryRuntime.search hydration enriches thin vector-style candidate content" {
    var backend = memory_lru.InMemoryLruMemory.init(std.testing.allocator, 32);
    defer backend.deinit();

    const mem = backend.memory();
    try mem.store("user_favorite_color", "Boss loves navy blue.", .core, null);

    var rt = MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{ .supports_keyword_rank = false, .supports_session_store = false, .supports_transactions = false, .supports_outbox = false },
        .resolved = test_resolved_cfg,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = std.testing.allocator,
        ._embedding_provider = null,
        ._vector_store = null,
        ._circuit_breaker = null,
        ._outbox = null,
    };

    var candidates = try std.testing.allocator.alloc(RetrievalCandidate, 1);
    errdefer std.testing.allocator.free(candidates);
    candidates[0] = try makeTestRetrievalCandidate(std.testing.allocator, "user_favorite_color", "user_favorite_color", "user_favorite_color");
    defer retrieval.freeCandidates(std.testing.allocator, candidates);

    rt.hydrateThinCandidatesFromPrimary(std.testing.allocator, candidates);
    try std.testing.expectEqualStrings("Boss loves navy blue.", candidates[0].content);
    try std.testing.expectEqualStrings("Boss loves navy blue.", candidates[0].snippet);
}

test "MemoryRuntime.search hydration leaves non-thin candidate unchanged" {
    var backend = memory_lru.InMemoryLruMemory.init(std.testing.allocator, 32);
    defer backend.deinit();

    const mem = backend.memory();
    try mem.store("user_favorite_color", "Boss loves navy blue.", .core, null);

    var rt = MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{ .supports_keyword_rank = false, .supports_session_store = false, .supports_transactions = false, .supports_outbox = false },
        .resolved = test_resolved_cfg,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = std.testing.allocator,
        ._embedding_provider = null,
        ._vector_store = null,
        ._circuit_breaker = null,
        ._outbox = null,
    };

    var candidates = try std.testing.allocator.alloc(RetrievalCandidate, 1);
    errdefer std.testing.allocator.free(candidates);
    candidates[0] = try makeTestRetrievalCandidate(std.testing.allocator, "user_favorite_color", "already rich content", "already rich content");
    defer retrieval.freeCandidates(std.testing.allocator, candidates);

    rt.hydrateThinCandidatesFromPrimary(std.testing.allocator, candidates);
    try std.testing.expectEqualStrings("already rich content", candidates[0].content);
    try std.testing.expectEqualStrings("already rich content", candidates[0].snippet);
}

test "initRuntime with hybrid disabled has no embedding provider" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._embedding_provider == null);
    try std.testing.expect(rt._vector_store == null);
    try std.testing.expect(rt._circuit_breaker == null);
    try std.testing.expect(rt._outbox == null);
}

test "initRuntime with search.provider=none has no vector store" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .search = .{
            .provider = "none",
            .query = .{ .hybrid = .{ .enabled = true } },
        },
    }, "/tmp") orelse
        return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._embedding_provider == null);
    try std.testing.expect(rt._vector_store == null);
}

test "initRuntime resolves sqlite_sidecar mode when explicitly configured" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "sqlite",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .store = .{ .kind = "sqlite_sidecar" },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._vector_store != null);
    try std.testing.expectEqualStrings("sqlite_sidecar", rt.resolved.vector_mode);
}

test "initRuntime uses configured relative sqlite_sidecar path" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "sqlite",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .store = .{
                .kind = "sqlite_sidecar",
                .sidecar_path = "vectors-custom.db",
            },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    const expected_path = try std.fs.path.join(std.testing.allocator, &.{ ws.path, "vectors-custom.db" });
    defer std.testing.allocator.free(expected_path);

    try std.testing.expect(rt._sidecar_db_path != null);
    try std.testing.expectEqualStrings(expected_path, std.mem.span(rt._sidecar_db_path.?));
}

test "initRuntime uses configured absolute sqlite_sidecar path" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);
    const absolute_sidecar_path = try std.fs.path.join(std.testing.allocator, &.{ ws.path, "vectors-absolute.db" });
    defer std.testing.allocator.free(absolute_sidecar_path);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "sqlite",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .store = .{
                .kind = "sqlite_sidecar",
                .sidecar_path = absolute_sidecar_path,
            },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._sidecar_db_path != null);
    try std.testing.expectEqualStrings(absolute_sidecar_path, std.mem.span(rt._sidecar_db_path.?));
}

test "initRuntime respects search.enabled=false" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "sqlite",
        .search = .{
            .enabled = false,
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._engine == null);
    try std.testing.expect(rt._embedding_provider == null);
    try std.testing.expect(rt._vector_store == null);
    try std.testing.expectEqualStrings("disabled", rt.resolved.retrieval_mode);

    const candidates = try rt.search(std.testing.allocator, "query", 5, null);
    defer retrieval.freeCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "initRuntime durable_outbox uses max of embed/vector retry config" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "sqlite",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .sync = .{
                .mode = "durable_outbox",
                .embed_max_retries = 1,
                .vector_max_retries = 5,
            },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    const ob = rt._outbox orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 5), ob.max_retries);
    try std.testing.expectEqualStrings("durable_outbox", rt.resolved.vector_sync_mode);
}

test "initRuntime resolves best_effort vector sync when outbox backend unavailable" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .store = .{
                .kind = "qdrant",
                .qdrant_url = "http://127.0.0.1:6333",
            },
            .sync = .{
                .mode = "durable_outbox",
            },
        },
    }, "/tmp") orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    try std.testing.expect(rt._vector_store != null);
    try std.testing.expect(rt._outbox == null);
    try std.testing.expectEqualStrings("best_effort", rt.resolved.vector_sync_mode);
}

test "initRuntime fail_fast returns null when durable outbox is unavailable" {
    try requireBackendEnabledForTests("none");

    const rt = initRuntime(std.testing.allocator, &.{
        .backend = "none",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .store = .{
                .kind = "qdrant",
                .qdrant_url = "http://127.0.0.1:6333",
            },
            .sync = .{
                .mode = "durable_outbox",
            },
        },
        .reliability = .{
            .fallback_policy = "fail_fast",
        },
    }, "/tmp");
    try std.testing.expect(rt == null);
}

test "syncVectorAfterStore enqueues when durable outbox is active" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "sqlite",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .sync = .{
                .mode = "durable_outbox",
            },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    const ob = rt._outbox orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), try ob.pendingCount());

    const result = rt.syncVectorAfterStore(std.testing.allocator, "k1", "content");
    try std.testing.expectEqual(MemoryRuntime.VectorSyncResult.deferred_to_outbox, result);
    try std.testing.expectEqual(@as(usize, 1), try ob.pendingCount());
}

test "deleteFromVectorStore enqueues delete when durable outbox is active" {
    if (!build_options.enable_memory_sqlite) return;
    var ws = try TestWorkspace.init(std.testing.allocator);
    defer ws.deinit(std.testing.allocator);

    var rt = initRuntime(std.testing.allocator, &.{
        .backend = "sqlite",
        .search = .{
            .provider = "openai",
            .query = .{ .hybrid = .{ .enabled = true } },
            .sync = .{
                .mode = "durable_outbox",
            },
        },
    }, ws.path) orelse return error.TestUnexpectedResult;
    defer rt.deinit();

    const ob = rt._outbox orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), try ob.pendingCount());

    rt.deleteFromVectorStore("k1");
    try std.testing.expectEqual(@as(usize, 1), try ob.pendingCount());
}

test "MemoryRuntime.syncVectorAfterStore with no provider is no-op" {
    var backend = none.NoneMemory.init();
    defer backend.deinit();
    var rt = MemoryRuntime{
        .memory = backend.memory(),
        .session_store = null,
        .response_cache = null,
        .capabilities = .{ .supports_keyword_rank = false, .supports_session_store = false, .supports_transactions = false, .supports_outbox = false },
        .resolved = test_resolved_cfg,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = std.testing.allocator,
        ._embedding_provider = null,
        ._vector_store = null,
        ._circuit_breaker = null,
        ._outbox = null,
    };
    // Should not crash — just a no-op. Returns skipped_no_provider.
    const result = rt.syncVectorAfterStore(std.testing.allocator, "key", "content");
    try std.testing.expectEqual(MemoryRuntime.VectorSyncResult.skipped_no_provider, result);
}

test "shouldEmbedMemoryEntry skips bookkeeping artifacts and oversize content" {
    try std.testing.expect(!shouldEmbedMemoryEntry("timeline_index/current", "index blob"));
    try std.testing.expect(!shouldEmbedMemoryEntry("context_anchor_current", "anchor blob"));
    try std.testing.expect(!shouldEmbedMemoryEntry("session_checkpoint_1", "checkpoint blob"));
    try std.testing.expect(!shouldEmbedMemoryEntry("autosave_user_1", "hello"));
    try std.testing.expect(shouldEmbedMemoryEntry("summary_latest/agent:test:user:1:main", "focus: ship"));

    // max_tokens=512, CHARS_PER_TOKEN=4 → gate is 2048 bytes
    var medium: [1400]u8 = undefined;
    @memset(&medium, 'a');
    try std.testing.expect(shouldEmbedMemoryEntry("timeline_summary/agent:test:user:1:main/1", medium[0..]));

    // 2049 bytes exceeds the 2048-byte gate
    var big: [2049]u8 = undefined;
    @memset(&big, 'a');
    try std.testing.expect(!shouldEmbedMemoryEntry("durable_fact/x", big[0..]));
}

test "MemoryRuntime.drainOutbox with no outbox returns 0" {
    var backend = none.NoneMemory.init();
    defer backend.deinit();
    var rt = MemoryRuntime{
        .memory = backend.memory(),
        .session_store = null,
        .response_cache = null,
        .capabilities = .{ .supports_keyword_rank = false, .supports_session_store = false, .supports_transactions = false, .supports_outbox = false },
        .resolved = test_resolved_cfg,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = std.testing.allocator,
        ._embedding_provider = null,
        ._vector_store = null,
        ._circuit_breaker = null,
        ._outbox = null,
    };
    try std.testing.expectEqual(@as(u32, 0), rt.drainOutbox(std.testing.allocator));
}

test "MemoryRuntime.deinit cleans up P3 resources" {
    try requireBackendEnabledForTests("none");

    var rt = initRuntime(std.testing.allocator, &.{ .backend = "none" }, "/tmp") orelse
        return error.TestUnexpectedResult;
    // P3 fields are null for "none" backend with hybrid disabled, but deinit should handle that.
    rt.deinit();
    // testing allocator detects leaks
}

test "providerNameForEmbeddingApiKey normalizes aliases" {
    try std.testing.expectEqualStrings("gemini", providerNameForEmbeddingApiKey("google"));
    try std.testing.expectEqualStrings("gemini", providerNameForEmbeddingApiKey("google-gemini"));
    try std.testing.expectEqualStrings("together", providerNameForEmbeddingApiKey("together-ai"));
    try std.testing.expectEqualStrings("openrouter", providerNameForEmbeddingApiKey("custom:https://openrouter.ai/api/v1"));
    try std.testing.expectEqualStrings("openai", providerNameForEmbeddingApiKey("custom:https://api.openai.com/v1"));
    try std.testing.expectEqualStrings("gemini", providerNameForEmbeddingApiKey("custom:https://generativelanguage.googleapis.com/v1beta"));
    try std.testing.expectEqualStrings("together", providerNameForEmbeddingApiKey("custom:https://api.together.xyz/v1"));
}

test "resolveEmbeddingApiKey prefers configured provider key" {
    const providers = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "sk-or-test" },
    };
    const resolved = resolveEmbeddingApiKey(std.testing.allocator, "openrouter", null, &providers) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("sk-or-test", resolved);
}

test "resolveEmbeddingApiKey maps custom openrouter to provider key" {
    const providers = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "sk-or-test" },
    };
    const resolved = resolveEmbeddingApiKey(std.testing.allocator, "custom:https://openrouter.ai/api/v1", null, &providers) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("sk-or-test", resolved);
}

test "resolveEmbeddingApiKey prefers provider config over override key" {
    const providers = [_]config_types.ProviderEntry{
        .{ .name = "together", .api_key = "together-correct" },
    };
    const resolved = resolveEmbeddingApiKey(std.testing.allocator, "together", "override-wrong", &providers) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("together-correct", resolved);
}

test "resolveEmbeddingApiKey accepts together-ai provider alias in config" {
    const providers = [_]config_types.ProviderEntry{
        .{ .name = "together-ai", .api_key = "together-alias-key" },
    };
    const resolved = resolveEmbeddingApiKey(std.testing.allocator, "together", null, &providers) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("together-alias-key", resolved);
}

test "deriveSessionIdFromMemoryKey extracts summary session ids" {
    try std.testing.expectEqualStrings(
        "agent:zaki-bot:user:42:thread:conv-2",
        deriveSessionIdFromMemoryKey("timeline_summary/agent:zaki-bot:user:42:thread:conv-2/1774400000").?,
    );
    try std.testing.expectEqualStrings(
        "agent:zaki-bot:user:42:main",
        deriveSessionIdFromMemoryKey("summary_latest/agent:zaki-bot:user:42:main").?,
    );
}

test "timeline summary helpers identify keys and parse timestamps" {
    try std.testing.expect(isTimelineSummaryKey("timeline_summary/agent:zaki-bot:user:1:main/1774400000"));
    try std.testing.expect(isSummaryLatestKey("summary_latest/agent:zaki-bot:user:1:main"));
    try std.testing.expectEqual(@as(?i64, 1774400000), parseTimelineSummaryTimestamp("timeline_summary/agent:zaki-bot:user:1:main/1774400000"));
}

test "parseTimelineIndexLine extracts descriptor fields from canonical format" {
    const parsed = (try parseTimelineIndexLine(std.testing.allocator, "- at=2026-03-29T00:00:00Z channel=telegram lane=thread session=telegram:chat:1 key=timeline_summary/telegram:chat:1/1774400000 focus=shipping key=handoff session=retro")) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("2026-03-29T00:00:00Z", parsed.at);
    try std.testing.expectEqualStrings("telegram", parsed.channel);
    try std.testing.expectEqualStrings("thread", parsed.lane);
    try std.testing.expectEqualStrings("telegram:chat:1", parsed.session);
    try std.testing.expectEqualStrings("shipping key=handoff session=retro", parsed.focus);
    try std.testing.expectEqualStrings("timeline_summary/telegram:chat:1/1774400000", parsed.key);
}

test "parseTimelineIndexLine keeps legacy focus-before-key compatibility" {
    const parsed = (try parseTimelineIndexLine(std.testing.allocator, "- at=2026-03-29T00:00:00Z channel=telegram lane=thread session=telegram:chat:1 focus=shipping plan review key=timeline_summary/telegram:chat:1/1774400000")) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("telegram:chat:1", parsed.session);
    try std.testing.expectEqualStrings("shipping plan review", parsed.focus);
    try std.testing.expectEqualStrings("timeline_summary/telegram:chat:1/1774400000", parsed.key);
}

test "parseTimelineIndexLine extracts descriptor fields from jsonl format" {
    const parsed = (try parseTimelineIndexLine(std.testing.allocator, "{\"at\":\"2026-03-29T00:00:00Z\",\"session\":\"telegram:chat:1\",\"key\":\"timeline_summary/telegram:chat:1/1774400000\",\"channel\":\"telegram\",\"lane\":\"thread\",\"chat_id\":\"1110331014\",\"focus\":\"shipping handoff\"}")) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("2026-03-29T00:00:00Z", parsed.at);
    try std.testing.expectEqualStrings("telegram", parsed.channel);
    try std.testing.expectEqualStrings("thread", parsed.lane);
    try std.testing.expectEqualStrings("telegram:chat:1", parsed.session);
    try std.testing.expectEqualStrings("timeline_summary/telegram:chat:1/1774400000", parsed.key);
    try std.testing.expectEqualStrings("shipping handoff", parsed.focus);
    try std.testing.expectEqualStrings("1110331014", parsed.chat_id.?);
}

test "parseTimelineIndexLine handles escaped quotes in jsonl focus" {
    const parsed = (try parseTimelineIndexLine(std.testing.allocator, "{\"at\":\"2026-03-29T00:00:00Z\",\"session\":\"telegram:chat:1\",\"key\":\"timeline_summary/telegram:chat:1/1774400000\",\"channel\":\"telegram\",\"lane\":\"thread\",\"focus\":\"shipping \\\"priority\\\" review\\\\notes\"}")) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("telegram", parsed.channel);
    try std.testing.expectEqualStrings("timeline_summary/telegram:chat:1/1774400000", parsed.key);
    try std.testing.expectEqualStrings("shipping \"priority\" review\\notes", parsed.focus);
}

test "timeline index jsonl parse and rebuild preserves escaped fields" {
    const original = "{\"at\":\"2026-03-29T00:00:00Z\",\"session\":\"telegram:chat:1\",\"key\":\"timeline_summary/telegram:chat:1/1774400000\",\"channel\":\"telegram\",\"lane\":\"thread\",\"chat_id\":\"1110331014\",\"focus\":\"shipping \\\"priority\\\" review\\\\notes\"}";
    const parsed = (try parseTimelineIndexLine(std.testing.allocator, original)) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(std.testing.allocator);
    const rebuilt = try buildTimelineIndexJsonLine(std.testing.allocator, parsed);
    defer std.testing.allocator.free(rebuilt);
    try std.testing.expectEqualStrings(original, rebuilt);
}

test "buildTimelineIndexJsonLine emits jsonl row" {
    const line = try buildTimelineIndexJsonLine(std.testing.allocator, .{
        .at = "2026-03-29T00:00:00Z",
        .channel = "telegram",
        .lane = "thread",
        .session = "telegram:chat:1",
        .focus = "shipping handoff",
        .key = "timeline_summary/telegram:chat:1/1774400000",
        .chat_id = "1110331014",
    });
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"channel\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"chat_id\":\"1110331014\"") != null);
}

test "summary extraction helpers return scalar and list sections" {
    const summary =
        "focus: shipping\n" ++
        "decisions:\n- keep it tight\n- ship Friday\n" ++
        "open_loops:\n- verify deploy\n" ++
        "next:\n- send update\n";
    try std.testing.expectEqualStrings("shipping", extractSummarySection(summary, "focus:"));
    const decisions = try extractSummaryListSection(std.testing.allocator, summary, "decisions:\n");
    defer std.testing.allocator.free(decisions);
    try std.testing.expectEqualStrings("keep it tight | ship Friday", decisions);
}

test "deriveMemoryProvenance derives app lane" {
    const provenance = deriveMemoryProvenance("agent:zaki-bot:user:42:thread:conv-2", "ignored");
    try std.testing.expectEqualStrings("app", provenance.channel);
    try std.testing.expectEqualStrings("thread", provenance.lane);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:thread:conv-2", provenance.session_id.?);
}

test "S8.1 laneFromSessionId — public alias returns canonical labels" {
    // User-cell lanes
    try std.testing.expectEqualStrings("main", laneFromSessionId("agent:zaki-bot:user:42:main"));
    try std.testing.expectEqualStrings("thread", laneFromSessionId("agent:zaki-bot:user:42:thread:c1"));
    try std.testing.expectEqualStrings("task", laneFromSessionId("agent:zaki-bot:user:7:task:t-99"));
    try std.testing.expectEqualStrings("cron", laneFromSessionId("agent:zaki-bot:user:7:cron:job-3"));
    // Channel-routed lanes
    try std.testing.expectEqualStrings("direct", laneFromSessionId("agent:bot1:telegram:direct:user42"));
    try std.testing.expectEqualStrings("group", laneFromSessionId("agent:bot1:telegram:group:1110331014"));
    // Unknown shapes
    try std.testing.expectEqualStrings("unknown", laneFromSessionId("not-a-session-key"));
}

test "S8.1 MemoryEntry.lane defaults to unknown without explicit set" {
    const e = MemoryEntry{
        .id = "x",
        .key = "k",
        .content = "c",
        .category = .core,
        .timestamp = "0",
    };
    try std.testing.expectEqualStrings("unknown", e.lane);
}

test "S8.1 MemoryEntry.lane carries explicit value through deinit-safe path" {
    // Static-string lane; deinit() must not free it (regression guard for
    // a future refactor that mistakenly tries to allocator.free(self.lane)).
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "id-1");
    const key = try allocator.dupe(u8, "k1");
    const content = try allocator.dupe(u8, "hello");
    const ts = try allocator.dupe(u8, "1");
    const e = MemoryEntry{
        .id = id,
        .key = key,
        .content = content,
        .category = .core,
        .timestamp = ts,
        .lane = laneFromSessionId("agent:zaki-bot:user:5:task:t-7"),
    };
    try std.testing.expectEqualStrings("task", e.lane);
    e.deinit(allocator);
}

test "deriveMemoryProvenance keeps colonful app thread ids as app" {
    const provenance = deriveMemoryProvenance("agent:zaki-bot:user:42:thread:project:neptune", "ignored");
    try std.testing.expectEqualStrings("app", provenance.channel);
    try std.testing.expectEqualStrings("thread", provenance.lane);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:thread:project:neptune", provenance.session_id.?);
}

test "resolveStoredMemoryProvenance preserves wrapped telegram origin for summaries" {
    const provenance = resolveStoredMemoryProvenance("focus: legacy\n", null, "timeline_summary/agent:zaki-bot:user:42:thread:telegram:thread:1110331014/1774400000");
    try std.testing.expectEqualStrings("telegram", provenance.channel);
    try std.testing.expectEqualStrings("thread", provenance.lane);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:thread:telegram:thread:1110331014", provenance.session_id.?);
}

test "resolveStoredMemoryProvenance prefers explicit origin metadata" {
    const provenance = resolveStoredMemoryProvenance(
        "origin_channel=telegram\norigin_lane=thread\norigin_chat_id=1110331014\n\nfocus: shipping\n",
        null,
        "timeline_summary/agent:zaki-bot:user:42:main/1774400000",
    );
    try std.testing.expectEqualStrings("telegram", provenance.channel);
    try std.testing.expectEqualStrings("thread", provenance.lane);
}

test "resolveStoredMemoryProvenance ignores legacy channel metadata on non-summary entries" {
    const provenance = resolveStoredMemoryProvenance(
        "channel=telegram\nlane=thread\nnote: plain content\n",
        "agent:zaki-bot:user:42:main",
        "user_name",
    );
    try std.testing.expectEqualStrings("app", provenance.channel);
    try std.testing.expectEqualStrings("main", provenance.lane);
}

test "deriveMemoryProvenance derives connector lane" {
    const provenance = deriveMemoryProvenance("slack:sl-main:channel:C12345", "ignored");
    try std.testing.expectEqualStrings("slack", provenance.channel);
    try std.testing.expectEqualStrings("channel", provenance.lane);
}

test "editable memory classification keeps user state editable" {
    try std.testing.expect(isEditableMemoryEntry("user_name", .core));
    try std.testing.expect(!isEditableMemoryEntry("summary_latest/agent:zaki-bot:user:1:main", .core));
    try std.testing.expect(!isEditableMemoryEntry("timeline_summary/agent:zaki-bot:user:1:main/1", .daily));
    try std.testing.expect(!isEditableMemoryEntry("durable_fact/1/0", .core));
}

test "V1.10 Gap B — daily-type user-namespace keys are editable" {
    // Regression test: pre-V1.10-Gap-B, isEditableMemoryEntry refused
    // any non-core entry, leaving daily-type self-poll under user keys
    // (e.g. project_codename = "Panther" from an April brainstorm)
    // unkillable from the agent side. memory_archive returned
    // "protected"; memory_forget refused; only direct SQL could remove.
    // The fix: edit/archive/forget operate on user-namespace keys
    // regardless of category. Internal/system-managed keys stay
    // protected through their own structural checks.
    try std.testing.expect(isEditableMemoryEntry("project_codename", .daily));
    try std.testing.expect(isEditableMemoryEntry("project_codename_panther", .daily));
    try std.testing.expect(isEditableMemoryEntry("user_project_codename", .conversation));
    try std.testing.expect(isEditableMemoryEntry("any_user_key", .core));
    try std.testing.expect(isEditableMemoryEntry("any_user_key", .daily));
    // Internal / system-managed keys still refused regardless of category.
    try std.testing.expect(!isEditableMemoryEntry("autosave_user_123", .conversation));
    try std.testing.expect(!isEditableMemoryEntry("durable_fact/1/0", .daily));
    try std.testing.expect(!isEditableMemoryEntry("summary_latest/x", .core));
    try std.testing.expect(!isEditableMemoryEntry("timeline_summary/x/1", .core));
    try std.testing.expect(!isEditableMemoryEntry("context_anchor_current", .core));
}

test "tombstone target key extracts target" {
    try std.testing.expectEqualStrings("user_name", tombstoneTargetKey("__tombstone__/user_name").?);
}

test "lookupMemoryLifecycleEntry reports missing key" {
    var mem_impl = InMemoryLruMemory.init(std.testing.allocator, 16);
    defer mem_impl.deinit();

    var lookup = try lookupMemoryLifecycleEntry(std.testing.allocator, mem_impl.memory(), "missing");
    defer lookup.deinit(std.testing.allocator);

    try std.testing.expectEqual(MemoryLifecycleStatus.missing, lookup.status);
    try std.testing.expect(lookup.entry == null);
}

test "lookupMemoryLifecycleEntry reports editable key" {
    var mem_impl = InMemoryLruMemory.init(std.testing.allocator, 16);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();
    try mem.store("user_name", "Nova", .core, null);

    var lookup = try lookupMemoryLifecycleEntry(std.testing.allocator, mem, "user_name");
    defer lookup.deinit(std.testing.allocator);

    try std.testing.expectEqual(MemoryLifecycleStatus.editable, lookup.status);
    try std.testing.expect(lookup.entry != null);
}

test "lookupMemoryLifecycleEntry reports protected system-managed key" {
    var mem_impl = InMemoryLruMemory.init(std.testing.allocator, 16);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();
    try mem.store("summary_latest/agent:zaki-bot:user:1:main", "focus: ship", .core, null);

    var lookup = try lookupMemoryLifecycleEntry(std.testing.allocator, mem, "summary_latest/agent:zaki-bot:user:1:main");
    defer lookup.deinit(std.testing.allocator);

    try std.testing.expectEqual(MemoryLifecycleStatus.protected, lookup.status);
    try std.testing.expect(lookup.entry != null);
}

test "lookupMemoryLifecycleEntry reports protected append-only key" {
    var mem_impl = InMemoryLruMemory.init(std.testing.allocator, 16);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();
    try mem.store("timeline_summary/agent:zaki-bot:user:1:main/1", "focus: ship", .daily, null);

    var lookup = try lookupMemoryLifecycleEntry(std.testing.allocator, mem, "timeline_summary/agent:zaki-bot:user:1:main/1");
    defer lookup.deinit(std.testing.allocator);

    try std.testing.expectEqual(MemoryLifecycleStatus.protected, lookup.status);
    try std.testing.expect(lookup.entry != null);
}

test {
    // engines/ (Layer A)
    _ = sqlite;
    _ = markdown;
    _ = none;
    _ = memory_lru;
    _ = lucid;
    _ = postgres;
    _ = redis;
    _ = lancedb;
    _ = registry;
    _ = @import("engines/contract_test.zig");

    // retrieval/ (Layer B)
    _ = retrieval;
    _ = retrieval_qmd;
    _ = rrf;
    _ = query_expansion;
    _ = temporal_decay;
    _ = mmr;
    _ = adaptive;
    _ = llm_reranker;

    // vector/ (Layer C)
    _ = vector;
    _ = vector_store;
    _ = embeddings;
    _ = embeddings_gemini;
    _ = embeddings_voyage;
    _ = embeddings_ollama;
    _ = provider_router;
    _ = store_qdrant;
    _ = store_pgvector;
    _ = circuit_breaker;
    _ = outbox;
    _ = chunker;

    // lifecycle/ (Layer D)
    _ = cache;
    _ = semantic_cache;
    _ = hygiene;
    _ = snapshot;
    _ = rollout;
    _ = migrate;
    _ = diagnostics;
    _ = summarizer;
}
