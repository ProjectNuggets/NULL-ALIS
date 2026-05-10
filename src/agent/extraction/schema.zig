//! V1.14.8 — Unified extraction schema.
//!
//! Shared by all boundary triggers (Pass C summary + session-end TTL).
//! Mirrors the Graphiti/Zep `CombinedExtraction` Pydantic shape — entities
//! and edges in one structured output. Working-memory slot promotion is
//! folded in via the optional `slot_intent` field on Edge (when set, the
//! persistence layer fires `working_memory.promoteFromExtraction`
//! synchronously).
//!
//! Why this shape vs alternatives:
//!   - mem0 emits `{"facts": ["text", ...]}` — flat strings, no graph layer
//!     possible. We're richer.
//!   - graphiti emits entities + edges in separate calls — we collapse to
//!     ONE call (same prompt, same parser).
//!   - Claude Code emits XML hydration summary only — different output
//!     shape (handled by HydrationSummary below).
//!
//! Load-bearing constraint: every field on Entity/Edge that requires a
//! string MUST be allocated by the parser and freed via deinit. The
//! BoundaryResult owns its components; consumers MUST call deinit before
//! dropping the result on the floor.

const std = @import("std");

/// Entity extracted from a conversation slice. Mirrors graphiti.CombinedEntity.
///
/// `entity_type` is a small enum to keep downstream classification
/// deterministic — graphiti's open-domain mode produces entity-type bloat
/// when the prompt allows freeform types. Falls back to `.concept` when
/// the LLM emits an unknown type string.
pub const Entity = struct {
    /// ≤5 words; specific form ("James's notebook" not "notebook").
    name: []const u8,
    entity_type: EntityType,

    pub const EntityType = enum {
        person,
        place,
        project,
        concept,
        object,
        event,
        organization,

        pub fn fromString(s: []const u8) EntityType {
            if (std.ascii.eqlIgnoreCase(s, "person")) return .person;
            if (std.ascii.eqlIgnoreCase(s, "place")) return .place;
            if (std.ascii.eqlIgnoreCase(s, "project")) return .project;
            if (std.ascii.eqlIgnoreCase(s, "object")) return .object;
            if (std.ascii.eqlIgnoreCase(s, "event")) return .event;
            if (std.ascii.eqlIgnoreCase(s, "organization")) return .organization;
            return .concept; // safe default for unknown / freeform types
        }

        pub fn toString(self: EntityType) []const u8 {
            return switch (self) {
                .person => "person",
                .place => "place",
                .project => "project",
                .concept => "concept",
                .object => "object",
                .event => "event",
                .organization => "organization",
            };
        }
    };

    pub fn deinit(self: *const Entity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Edge connecting two entities OR self-referencing.
///
/// Self-references are intentional and valid for routines/preferences/
/// states/plans — graphiti's spec § FACT RULES #2:
///   "Sam HAS_INJURY knee" (self-ref OK)
///   "Nate FAVORITE_GAME Xenoblade" (cross-entity)
///
/// `slot_intent`: when set, the persistence layer promotes a working_memory
/// slot of that type SYNCHRONOUSLY (V1.14.8 C4 wiring; without that wiring,
/// the field is parsed but ignored — additive contract).
pub const Edge = struct {
    /// Must match an Entity.name in the same ExtractionResult.
    source_name: []const u8,
    /// Must match an Entity.name (may equal source_name for self-refs).
    target_name: []const u8,
    /// SCREAMING_SNAKE_CASE relation type. Banned: SAID, MENTIONED, ASKED,
    /// GREETED, ACKNOWLEDGED, REPLIED — those are conversational meta, not
    /// facts. The prompt enforces this; the parser is permissive (no
    /// rejection of banned predicates here, since the LLM may legitimately
    /// produce SCREAMING_SNAKE relations we haven't seen).
    relation_type: []const u8,
    /// Self-contained natural language description of the fact, paraphrased
    /// from the source text. Readable without the original conversation.
    fact: []const u8,
    /// Optional working-memory slot intent. Null means "extract as fact only,
    /// no slot promotion." When set, persistExtracted will fire
    /// working_memory.promoteFromExtraction with this slot type.
    slot_intent: ?SlotIntent = null,
    /// LLM-reported confidence (0.0-1.0). Defaults to 0.85 at persist time
    /// when null.
    confidence: ?f64 = null,
    /// Optional bi-temporal anchor (unix seconds). When set, persists as
    /// `valid_from` on the memory row; without it, write-time fallback applies.
    valid_at: ?i64 = null,

    pub const SlotIntent = enum {
        open_loop, // TODO/PROMISED/REMINDS_ME_TO/WILL_DO predicates
        active_goal, // WORKING_ON/BUILDING/GOAL/FOCUSING_ON
        decision, // DECIDED/CHOSE
        preference, // LIKES/HATES/PREFERS/AVOIDS
        identity, // IS/AM/HAS (durable self-attribution)
        temporal, // BIRTHDAY/SCHEDULED_FOR/HAPPENS_ON

        pub fn fromString(s: []const u8) ?SlotIntent {
            if (std.ascii.eqlIgnoreCase(s, "open_loop")) return .open_loop;
            if (std.ascii.eqlIgnoreCase(s, "active_goal")) return .active_goal;
            if (std.ascii.eqlIgnoreCase(s, "decision")) return .decision;
            if (std.ascii.eqlIgnoreCase(s, "preference")) return .preference;
            if (std.ascii.eqlIgnoreCase(s, "identity")) return .identity;
            if (std.ascii.eqlIgnoreCase(s, "temporal")) return .temporal;
            return null; // unknown / "null" string / missing
        }

        pub fn toString(self: SlotIntent) []const u8 {
            return switch (self) {
                .open_loop => "open_loop",
                .active_goal => "active_goal",
                .decision => "decision",
                .preference => "preference",
                .identity => "identity",
                .temporal => "temporal",
            };
        }
    };

    pub fn deinit(self: *const Edge, allocator: std.mem.Allocator) void {
        allocator.free(self.source_name);
        allocator.free(self.target_name);
        allocator.free(self.relation_type);
        allocator.free(self.fact);
    }
};

/// Result of one extraction LLM call. Empty arrays are valid output
/// (mem0 pattern — when nothing extractable, emit `{"entities":[],"edges":[]}`).
pub const ExtractionResult = struct {
    entities: []Entity,
    edges: []Edge,

    pub fn empty(allocator: std.mem.Allocator) !ExtractionResult {
        return .{
            .entities = try allocator.alloc(Entity, 0),
            .edges = try allocator.alloc(Edge, 0),
        };
    }

    pub fn deinit(self: *const ExtractionResult, allocator: std.mem.Allocator) void {
        for (self.entities) |*e| e.deinit(allocator);
        allocator.free(self.entities);
        for (self.edges) |*e| e.deinit(allocator);
        allocator.free(self.edges);
    }
};

/// Result of the hydration LLM call (Claude Code XML shape — five fields
/// mirroring `<focus>/<decisions>/<open_loops>/<next>/<facts>`).
pub const HydrationSummary = struct {
    focus: []const u8,
    decisions: []const u8, // markdown bullet list rendered as one string
    open_loops: []const u8,
    next: []const u8,
    facts: []const u8, // long-lived facts worth remembering

    pub fn deinit(self: *const HydrationSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.focus);
        allocator.free(self.decisions);
        allocator.free(self.open_loops);
        allocator.free(self.next);
        allocator.free(self.facts);
    }

    /// Render as a single text payload mirroring the legacy summary_latest
    /// format. Caller owns the returned slice.
    pub fn renderText(self: *const HydrationSummary, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "focus: {s}\ndecisions:\n{s}\nopen_loops:\n{s}\nnext:\n{s}\nfacts:\n{s}",
            .{ self.focus, self.decisions, self.open_loops, self.next, self.facts },
        );
    }
};

/// Combined output of one boundary fire. Either field may be null on LLM
/// failure — the boundary's primary write (drop / summarize / TTL archive)
/// proceeds regardless. Failure-soft contract.
pub const BoundaryResult = struct {
    extraction: ?ExtractionResult,
    hydration: ?HydrationSummary,

    pub fn deinit(self: *const BoundaryResult, allocator: std.mem.Allocator) void {
        if (self.extraction) |e| e.deinit(allocator);
        if (self.hydration) |h| h.deinit(allocator);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "EntityType.fromString handles known + unknown" {
    try std.testing.expectEqual(Entity.EntityType.person, Entity.EntityType.fromString("person"));
    try std.testing.expectEqual(Entity.EntityType.place, Entity.EntityType.fromString("PLACE"));
    try std.testing.expectEqual(Entity.EntityType.concept, Entity.EntityType.fromString("nonexistent_type"));
    try std.testing.expectEqual(Entity.EntityType.concept, Entity.EntityType.fromString(""));
}

test "SlotIntent.fromString handles known + unknown" {
    try std.testing.expectEqual(@as(?Edge.SlotIntent, .open_loop), Edge.SlotIntent.fromString("open_loop"));
    try std.testing.expectEqual(@as(?Edge.SlotIntent, .active_goal), Edge.SlotIntent.fromString("ACTIVE_GOAL"));
    try std.testing.expectEqual(@as(?Edge.SlotIntent, null), Edge.SlotIntent.fromString("unknown"));
    try std.testing.expectEqual(@as(?Edge.SlotIntent, null), Edge.SlotIntent.fromString("null"));
}

test "ExtractionResult.empty returns zero-length slices" {
    const allocator = std.testing.allocator;
    const result = try ExtractionResult.empty(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.entities.len);
    try std.testing.expectEqual(@as(usize, 0), result.edges.len);
}

test "HydrationSummary.renderText composes fields with section headers" {
    const allocator = std.testing.allocator;
    const h = HydrationSummary{
        .focus = try allocator.dupe(u8, "shipping V1.14.8"),
        .decisions = try allocator.dupe(u8, "- split hydration from extraction"),
        .open_loops = try allocator.dupe(u8, "- finalize parser tests"),
        .next = try allocator.dupe(u8, "- run integration test"),
        .facts = try allocator.dupe(u8, "- new module at src/agent/extraction/"),
    };
    defer h.deinit(allocator);

    const rendered = try h.renderText(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "focus: shipping V1.14.8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "decisions:\n- split hydration") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "facts:\n- new module") != null);
}
