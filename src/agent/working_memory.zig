//! V1.13 Day 1 — Working Memory orchestrator.
//!
//! Layer 0 of the brain: 15 hot slots that persist across turns within
//! a session. Renders into the volatile system prompt block at top of
//! every prompt — agent always has open loops, active goals, recent
//! emotional context, and identity in mind without rebuilding from
//! prose recall every turn.
//!
//! ## Why this exists
//!
//! Pre-V1.13 the agent had no working memory. Every turn it rebuilt
//! context from scratch via memory_recall (prose blobs). Open loops
//! lived inside summary text, not as structured slots. Result: ZAKI
//! felt like a "very good amnesiac." V1.13 fixes that.
//!
//! ## Architectural contract
//!
//! - Storage: `zaki_bot.working_memory` table (CRUD in zaki_state.zig).
//! - Slot count: max 15 per (user_id, session_id).
//! - Slot identity: stable position 0..14. Eviction reuses slot_ids
//!   based on composite priority (importance × recency_decay).
//! - Pinned slots: never evicted. Slot 0 reserved for `identity` type.
//! - Render: top 10 slots by priority, formatted as a `<working_memory>`
//!   block in the volatile system prompt.
//! - Promotion: extraction_persist auto-promotes open_loop / active_goal
//!   / decision predicates. Other slot_types are written by explicit
//!   API (e.g. compaction synthesizing emotional state).
//!
//! ## Failure mode
//!
//! Every operation is failure-soft. If postgres is unavailable, the
//! WM layer degrades gracefully — empty slots, empty render block,
//! no spam logs. The agent loses Layer 0 but still functions on
//! recall + history alone.

const std = @import("std");
const log = std.log.scoped(.working_memory);

const memory_root = @import("../memory/root.zig");
const WorkingMemorySlot = memory_root.WorkingMemorySlot;
const zaki_state = @import("../zaki_state.zig");
const text_norm = @import("../memory/text_norm.zig");

/// Max slots rendered into the prompt block. Less than the storage
/// cap (15) so we leave room for slots that exist but aren't worth
/// surfacing this turn (low importance, far-stale).
pub const RENDER_TOP_N: usize = 10;

/// Reserved slot_ids for pinned identity facts. Eviction skips these.
pub const RESERVED_SLOT_IDENTITY: i32 = 0;
pub const RESERVED_SLOT_PERSONA: i32 = 1;

/// Slot type vocabulary. Stored as TEXT in the schema (no enum
/// constraint) so future extensions don't require a migration.
pub const SlotType = struct {
    pub const open_loop = "open_loop";
    pub const active_goal = "active_goal";
    pub const emotional = "emotional";
    pub const identity = "identity";
    pub const relationship = "relationship";
    pub const decision = "decision";
    pub const recent_entity = "recent_entity";
    pub const skill_state = "skill_state";
    pub const temporal = "temporal";
    pub const open_question = "open_question";
};

/// Slot type priority weights — used by the composite-priority eviction
/// logic. Higher weight = harder to evict. Identity (1.0) is also pinned
/// at the row level; this weight only matters for non-pinned slot_types.
pub fn slotTypeWeight(t: []const u8) f64 {
    if (std.mem.eql(u8, t, SlotType.identity)) return 1.0;
    if (std.mem.eql(u8, t, SlotType.active_goal)) return 0.95;
    if (std.mem.eql(u8, t, SlotType.open_loop)) return 0.9;
    if (std.mem.eql(u8, t, SlotType.decision)) return 0.85;
    if (std.mem.eql(u8, t, SlotType.relationship)) return 0.8;
    if (std.mem.eql(u8, t, SlotType.skill_state)) return 0.75;
    if (std.mem.eql(u8, t, SlotType.temporal)) return 0.7;
    if (std.mem.eql(u8, t, SlotType.open_question)) return 0.65;
    if (std.mem.eql(u8, t, SlotType.emotional)) return 0.6;
    if (std.mem.eql(u8, t, SlotType.recent_entity)) return 0.4;
    return 0.5; // unknown / future types
}

/// Composite priority for eviction: recency_decay × slot_type_weight.
/// Recency uses 1-hour half-life — slots untouched for an hour decay to ~0.5.
/// Result clamped to [0, 1].
///
/// v1.14.14.1 Finding 1 (WM-IMPORTANCE-CALIBRATION): the formula was
/// originally `importance × recency × slot_type_weight`. Production postmortem
/// (350 slots / 95 sessions, 2026-05) showed `importance` saturated at avg 0.99
/// across every slot_type — the LLM extractor (extraction_persist.zig:1064
/// `@max(m.confidence, 0.5)`) consistently emits ≥ 0.99 because (a) the
/// extraction prompt asks for `<number 0.0-1.0>` with NO anchoring examples,
/// (b) LLMs are systematically overconfident on self-rating, and (c) the
/// persist-time default (extraction_persist.zig:282-286) maps null/non-numeric
/// to 1.0. With importance saturated, the factor contributed zero discrimination —
/// composite reduced to `~0.99 × recency × type_w`, which IS recency × type_w
/// times a constant.
///
/// Option (b) per .planning/agent-G-v11414-1-phase0.md: drop importance from
/// the formula. Importance column STAYS in the schema and is still written
/// at every promotion site (zero migration). v1.14.18-B will reintroduce the
/// multiplier with per-source calibration once a signal-strength column lands
/// on ExtractedMemory (the SOTA option-(a) path). Until then, eviction is
/// deterministic by recency × type_w with pinned-first row ordering.
///
/// Three other options surveyed and rejected: (a) per-source calibration
/// blocked by missing signal column; (c) time-based decay duplicates this
/// formula's recency factor; (d) prompt-anchoring fix blocked by §14.7
/// "no prompt directive ships without bench evidence" and the zero-bench
/// scope of this slice. Full survey at the Finding 1 phase-0 plan.
pub fn compositePriority(slot: *const WorkingMemorySlot, now_unix: i64) f64 {
    const age_seconds: f64 = @floatFromInt(@max(0, now_unix - slot.last_touched_at_unix));
    // 1-hour half life: half_life_secs = 3600
    const recency = std.math.exp(-age_seconds * std.math.ln2 / 3600.0);
    const type_w = slotTypeWeight(slot.slot_type);
    const composite = recency * type_w;
    return std.math.clamp(composite, 0.0, 1.0);
}

/// Result of `loadForRender` — top-N slots ordered for prompt-block
/// rendering. Caller must `freeWorkingMemorySlots` on `slots`.
pub const RenderSet = struct {
    slots: []WorkingMemorySlot,

    pub fn deinit(self: *const RenderSet, allocator: std.mem.Allocator) void {
        memory_root.freeWorkingMemorySlots(allocator, self.slots);
    }
};

/// Load top-N slots for prompt rendering. Returns the slots already
/// ordered by composite priority (pinned first, then by priority desc).
/// On any error returns empty set — failure-soft per architectural
/// contract.
pub fn loadForRender(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: []const u8,
) RenderSet {
    const all = state_mgr.listWorkingMemorySlots(allocator, user_id, session_id) catch |err| {
        log.warn("working_memory.load_failed err={s} user={d} session={s}", .{
            @errorName(err), user_id, session_id,
        });
        return .{ .slots = allocator.alloc(WorkingMemorySlot, 0) catch &.{} };
    };

    if (all.len <= RENDER_TOP_N) return .{ .slots = all };

    // CR-02 fix (REVIEW V1.13 Day 1): the prior implementation deinit'd
    // the tail's inner strings then returned a length-N slice over an
    // alloc-of-original-length-M memory region (when realloc failed).
    // freeWorkingMemorySlots on that slice panics under GPA / leaks
    // under c_allocator because the slice length doesn't match the
    // allocation length, AND the deinit'd-but-exposed tail had
    // dangling pointers. Fix: copy the top-N entries into a fresh
    // allocation, deinit + free the original full slice, return the
    // top-N. No realloc-with-shrink — never partial cleanup.
    const top = allocator.alloc(WorkingMemorySlot, RENDER_TOP_N) catch {
        // OOM on the truncated alloc — return the full slice as-is.
        // The caller's deinit will free correctly because slice length
        // matches the underlying allocation.
        return .{ .slots = all };
    };
    @memcpy(top, all[0..RENDER_TOP_N]);
    // Deinit the tail (inner strings); free the original slab — its
    // strings have been transferred to `top` via memcpy of the structs.
    for (all[RENDER_TOP_N..]) |s| s.deinit(allocator);
    allocator.free(all);
    return .{ .slots = top };
}

/// Render slots into the volatile system prompt block.
/// Format:
///   <working_memory>
///     active_goal: ship V1.13 brain elevation
///     open_loop: call Alfred about MNDA (since 2 turns ago)
///     identity: user is Nova; ZAKI is built by NovaNuggets
///     recent_entity: Mika (husky) — mentioned 3x this session
///   </working_memory>
///
/// Caller frees returned string. Returns empty string when no slots.
pub fn renderBlock(
    allocator: std.mem.Allocator,
    slots: []const WorkingMemorySlot,
) ![]u8 {
    if (slots.len == 0) return allocator.alloc(u8, 0);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("<working_memory>\n");
    for (slots) |s| {
        // Bound per-slot content at 200 chars to keep the block compact.
        // Full content is still in the DB; this is just the prompt
        // surface. 10 slots × ~250 bytes max ≈ 2.5KB block — fits
        // comfortably in the 64KB volatile budget.
        //
        // HI-02 fix (REVIEW V1.13 Day 1): use text_norm.truncateUtf8 to
        // avoid splitting multi-byte UTF-8 codepoints (Arabic, Hebrew,
        // CJK) — the prior raw [0..200] slice would emit malformed
        // UTF-8 mid-codepoint and break prompt rendering.
        const max_content: usize = 200;
        const truncated_content = text_norm.truncateUtf8(s.content, max_content);
        try w.print("  {s}: {s}\n", .{ s.slot_type, truncated_content });
    }
    try w.writeAll("</working_memory>\n");

    return buf.toOwnedSlice(allocator);
}

/// Find the slot_id to use for a new write — either an empty slot
/// (returns first unused slot_id 0..14) or the lowest-priority
/// non-pinned, non-reserved slot for eviction.
///
/// Returns null when all slots are pinned and full (caller should
/// log + skip the write — promotion is best-effort).
pub fn pickSlotForWrite(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: []const u8,
    new_slot_type: []const u8,
) !?i32 {
    _ = new_slot_type; // future: weight new write against existing slots of same type

    const slots = state_mgr.listWorkingMemorySlots(allocator, user_id, session_id) catch |err| {
        log.warn("working_memory.pick_slot_load_failed err={s}", .{@errorName(err)});
        return null;
    };
    defer memory_root.freeWorkingMemorySlots(allocator, slots);

    const SLOT_CAP: i32 = 15;

    if (slots.len < @as(usize, @intCast(SLOT_CAP))) {
        // Find first unused slot_id (skipping reserved 0/1 unless free).
        var used_mask: u16 = 0;
        for (slots) |s| {
            if (s.slot_id >= 0 and s.slot_id < SLOT_CAP) {
                used_mask |= (@as(u16, 1) << @intCast(s.slot_id));
            }
        }
        // Try non-reserved range first (2..14).
        var i: i32 = 2;
        while (i < SLOT_CAP) : (i += 1) {
            if ((used_mask & (@as(u16, 1) << @intCast(i))) == 0) return i;
        }
        // Fall back to reserved range if free.
        i = 0;
        while (i < 2) : (i += 1) {
            if ((used_mask & (@as(u16, 1) << @intCast(i))) == 0) return i;
        }
    }

    // All 15 slots used — evict lowest non-pinned composite priority.
    const now = std.time.timestamp();
    var lowest_idx: ?usize = null;
    var lowest_score: f64 = std.math.inf(f64);
    for (slots, 0..) |*s, idx| {
        if (s.pinned) continue;
        if (s.slot_id == RESERVED_SLOT_IDENTITY or s.slot_id == RESERVED_SLOT_PERSONA) continue;
        const score = compositePriority(s, now);
        if (score < lowest_score) {
            lowest_score = score;
            lowest_idx = idx;
        }
    }
    if (lowest_idx) |idx| return slots[idx].slot_id;
    return null; // all pinned/reserved; can't evict
}

/// Promote a fact into working memory at an auto-picked slot. Returns
/// the slot_id used, or null if all slots are pinned/reserved.
///
/// This is the canonical entry for callers (extraction_persist,
/// session_end, manual user invocation). Internally:
///   1. Pick slot via pickSlotForWrite (eviction logic)
///   2. upsertWorkingMemorySlot at that slot_id
///   3. Log structured event for observability
pub fn promoteSlot(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: []const u8,
    slot_type: []const u8,
    content: []const u8,
    source_key: ?[]const u8,
    importance: f64,
    pinned: bool,
) !?i32 {
    const slot_id = (try pickSlotForWrite(allocator, state_mgr, user_id, session_id, slot_type)) orelse {
        log.info(
            "working_memory.promote.skipped reason=all_pinned user={d} session={s} type={s}",
            .{ user_id, session_id, slot_type },
        );
        return null;
    };
    _ = state_mgr.upsertWorkingMemorySlot(
        user_id,
        session_id,
        slot_id,
        slot_type,
        content,
        source_key,
        importance,
        pinned,
    ) catch |err| {
        log.warn(
            "working_memory.promote.upsert_failed err={s} user={d} session={s} slot_id={d}",
            .{ @errorName(err), user_id, session_id, slot_id },
        );
        return null;
    };
    log.info(
        "working_memory.promoted user={d} session={s} slot_id={d} type={s} importance={d:.2} pinned={any}",
        .{ user_id, session_id, slot_id, slot_type, importance, pinned },
    );
    return slot_id;
}

/// Bump `last_touched_at` on a slot — called when the slot's content
/// or source_key is recalled / re-mentioned in a turn. Drives the
/// recency component of compositePriority. Failure-soft.
pub fn touchSlot(
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: []const u8,
    slot_id: i32,
) void {
    state_mgr.touchWorkingMemorySlot(user_id, session_id, slot_id) catch |err| {
        log.warn("working_memory.touch_failed err={s} slot_id={d}", .{ @errorName(err), slot_id });
    };
}

/// Pin an identity fact at the reserved slot_id (0=identity, 1=persona).
/// Identity facts are never evicted; they sit at the top of every
/// rendered block. Called once at session start with the canonical
/// identity facts (user name, agent identity, persona summary).
pub fn pinIdentitySlot(
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: []const u8,
    content: []const u8,
    source_key: ?[]const u8,
) !void {
    _ = try state_mgr.upsertWorkingMemorySlot(
        user_id,
        session_id,
        RESERVED_SLOT_IDENTITY,
        SlotType.identity,
        content,
        source_key,
        1.0, // importance always 1.0 for identity
        true, // pinned
    );
}

pub fn pinPersonaSlot(
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: []const u8,
    content: []const u8,
    source_key: ?[]const u8,
) !void {
    _ = try state_mgr.upsertWorkingMemorySlot(
        user_id,
        session_id,
        RESERVED_SLOT_PERSONA,
        SlotType.identity, // persona is conceptually identity-class
        content,
        source_key,
        1.0,
        true,
    );
}

/// V1.13 Day 5.2 — bundle the user's identity facts (from
/// listIdentityFacts) into a single rendered string and pin it to
/// slot 0. Called once at session creation. Returns the count of
/// facts bundled (0 means no identity present yet).
///
/// Bundles top N facts joined by newlines (max 1KB total) into a
/// single slot. Future refinement: split into slot 0 (identity) +
/// slot 1 (persona) when persona facts are distinguishable from
/// identity facts.
pub fn pinIdentityFromUserState(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: []const u8,
) !usize {
    const FETCH_LIMIT: u32 = 8;
    const MAX_BUNDLE_BYTES: usize = 1024;

    const facts = state_mgr.listIdentityFacts(allocator, user_id, FETCH_LIMIT) catch |err| {
        log.warn("pinIdentityFromUserState.list_failed err={s}", .{@errorName(err)});
        return 0;
    };
    defer memory_root.freeEntries(allocator, facts);
    if (facts.len == 0) return 0;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    var emitted: usize = 0;
    for (facts) |entry| {
        if (buf.items.len >= MAX_BUNDLE_BYTES) break;
        const trimmed = std.mem.trim(u8, entry.content, " \t\r\n");
        if (trimmed.len == 0) continue;
        const remaining = MAX_BUNDLE_BYTES - buf.items.len;
        if (remaining < 4) break;
        const slice = if (trimmed.len > remaining - 2) trimmed[0 .. remaining - 2] else trimmed;
        try w.print("- {s}\n", .{slice});
        emitted += 1;
    }
    if (emitted == 0) return 0;

    pinIdentitySlot(state_mgr, user_id, session_id, buf.items, null) catch |err| {
        log.warn("pinIdentityFromUserState.pin_failed err={s}", .{@errorName(err)});
        return 0;
    };
    log.info("working_memory.pinned_identity user={d} session={s} facts={d} bytes={d}", .{
        user_id, session_id, emitted, buf.items.len,
    });
    return emitted;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test "slotTypeWeight covers known types" {
    try std.testing.expectEqual(@as(f64, 1.0), slotTypeWeight(SlotType.identity));
    try std.testing.expectEqual(@as(f64, 0.95), slotTypeWeight(SlotType.active_goal));
    try std.testing.expectEqual(@as(f64, 0.9), slotTypeWeight(SlotType.open_loop));
    try std.testing.expectEqual(@as(f64, 0.5), slotTypeWeight("unknown_type"));
}

test "compositePriority decays with age" {
    const now: i64 = 1_700_000_000;
    var fresh = WorkingMemorySlot{
        .user_id = 1,
        .session_id = "test",
        .slot_id = 0,
        .slot_type = SlotType.open_loop,
        .content = "test",
        .source_key = null,
        .importance = 0.8,
        .pinned = false,
        .created_at_unix = now,
        .last_touched_at_unix = now,
    };
    var stale = fresh;
    stale.last_touched_at_unix = now - 7200; // 2 hours ago, 2 half-lives = 0.25

    // v1.14.14.1 Finding 1: formula is now `recency × type_w` (importance
    // dropped from composite — see compositePriority doc). Expected values:
    //   fresh: 1.0 × 0.9 = 0.90 (open_loop type_w = 0.9, recency ≈ 1.0)
    //   stale: 0.25 × 0.9 = 0.225 (2-half-life recency = 0.25)
    // The fresh > stale invariant the test exists to verify is preserved.
    const fresh_p = compositePriority(&fresh, now);
    const stale_p = compositePriority(&stale, now);
    try std.testing.expect(fresh_p > stale_p);
    try std.testing.expect(fresh_p > 0.5); // 1.0 * 0.9 = 0.90
    try std.testing.expect(stale_p < 0.3); // 0.25 * 0.9 = 0.225
}

test "compositePriority is independent of importance after v1.14.14.1 Finding 1" {
    const now: i64 = 1_700_000_000;
    var low_imp = WorkingMemorySlot{
        .user_id = 1,
        .session_id = "test",
        .slot_id = 0,
        .slot_type = SlotType.open_loop,
        .content = "test",
        .source_key = null,
        .importance = 0.5,
        .pinned = false,
        .created_at_unix = now,
        .last_touched_at_unix = now,
    };
    var high_imp = low_imp;
    high_imp.importance = 1.0;

    // After Finding 1: importance no longer enters the formula. Two slots
    // with identical recency + type but very different importance should
    // produce identical composite scores. This guards the recovery path
    // for v1.14.18-B — when per-source calibration lands and importance is
    // re-enabled, this test should be DELETED (importance discrimination
    // returns) rather than updated.
    const low_p = compositePriority(&low_imp, now);
    const high_p = compositePriority(&high_imp, now);
    try std.testing.expectEqual(low_p, high_p);
}

test "renderBlock formats slots correctly" {
    const allocator = std.testing.allocator;
    const slots = [_]WorkingMemorySlot{
        .{
            .user_id = 1,
            .session_id = "s1",
            .slot_id = 0,
            .slot_type = SlotType.identity,
            .content = "user is Nova",
            .source_key = null,
            .importance = 1.0,
            .pinned = true,
            .created_at_unix = 0,
            .last_touched_at_unix = 0,
        },
        .{
            .user_id = 1,
            .session_id = "s1",
            .slot_id = 2,
            .slot_type = SlotType.open_loop,
            .content = "call Alfred about MNDA",
            .source_key = null,
            .importance = 0.9,
            .pinned = false,
            .created_at_unix = 0,
            .last_touched_at_unix = 0,
        },
    };
    const rendered = try renderBlock(allocator, &slots);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<working_memory>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "identity: user is Nova") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "open_loop: call Alfred about MNDA") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "</working_memory>") != null);
}

test "renderBlock empty slots returns empty string" {
    const allocator = std.testing.allocator;
    const empty = [_]WorkingMemorySlot{};
    const rendered = try renderBlock(allocator, &empty);
    defer allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 0), rendered.len);
}

test "renderBlock truncates long content" {
    const allocator = std.testing.allocator;
    const long_content = "x" ** 500;
    const slot = WorkingMemorySlot{
        .user_id = 1,
        .session_id = "s1",
        .slot_id = 2,
        .slot_type = SlotType.open_loop,
        .content = long_content,
        .source_key = null,
        .importance = 0.9,
        .pinned = false,
        .created_at_unix = 0,
        .last_touched_at_unix = 0,
    };
    const slots = [_]WorkingMemorySlot{slot};
    const rendered = try renderBlock(allocator, &slots);
    defer allocator.free(rendered);
    // Block should contain at most 200 chars of content + framing.
    // Full 500 chars would mean truncation failed.
    const x_count = std.mem.count(u8, rendered, "x");
    try std.testing.expect(x_count <= 200);
}

test "RESERVED_SLOT_IDENTITY and RESERVED_SLOT_PERSONA are 0 and 1" {
    try std.testing.expectEqual(@as(i32, 0), RESERVED_SLOT_IDENTITY);
    try std.testing.expectEqual(@as(i32, 1), RESERVED_SLOT_PERSONA);
}

test "RENDER_TOP_N is 10" {
    try std.testing.expectEqual(@as(usize, 10), RENDER_TOP_N);
}
