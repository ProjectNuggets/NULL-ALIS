//! v1.14.18-B G16 (WM-CROSS-SESSION) — first cross-layer memory promotion rule.
//!
//! Layer 0 (working_memory) slots are per-session. Identity slots persist
//! across sessions via `pinIdentityFromUserState`, but the high-importance
//! transient slots — `active_goal`, `decision`, `open_loop`, `temporal` —
//! evaporate at session-end. Multi-session goal tracking is broken because
//! the next session starts with a blank Layer 0 modulo the pinned identity.
//!
//! ## What this module does
//!
//! At session-end (called from `commands.zig` session-end checkpoint path),
//! `promoteWMToDurableAtSessionEnd` walks the session's WM slots, filters
//! down to (slot_type ∈ {active_goal, decision, open_loop}) AND
//! (composite_priority ≥ PROMOTION_THRESHOLD), and writes each to
//! `durable_fact/<slot_type>/<session_id>/<slot_id>` via `mem.store`.
//!
//! ## Why the `durable_fact/<slot_type>/` key shape (P8)
//!
//! - `durable_fact/` prefix → `memory_loader.isDurableFactKey` already
//!   classifies this row as semantic-continuity. At session-start, the
//!   existing memory_loader path pulls it into the volatile prompt slot
//!   naturally; no new continuity-classifier code needed.
//! - `<slot_type>/` segment → P8 discriminator. Each promotable type
//!   (`active_goal` / `decision` / `open_loop`) gets its OWN namespace so
//!   the durable rows stay queryable by kind, and so they're still
//!   distinguishable from extraction-classifier `durable_fact/<ts>/<idx>`
//!   rows. (Pre-P8 this segment was the constant `transient_goal`, which
//!   discarded the type discriminator.)
//! - `<session_id>/<slot_id>` segments → idempotent. Re-running promotion
//!   for the same session+slot upserts (no duplicate rows).
//!
//! ## Why slot_type ∈ {active_goal, decision, open_loop}
//!
//! Per the dispatch: these are the slots whose loss most-clearly breaks
//! multi-session continuity. P8 (memory-phase-0.5) ADDS `open_loop` to the
//! promotion vocabulary: an open loop ("call Alfred about the MNDA") is a
//! trackable item that should survive a session boundary so the agent can
//! follow up next session instead of forgetting the user ever owed an
//! action. The original v1.14.18-B exclusion rationale ("loops often
//! resolve naturally between sessions") proved wrong in practice — losing
//! the loop entirely is strictly worse than carrying a stale one the agent
//! can ask about and close.
//!
//! ## Why the key is branched by slot_type (P8)
//!
//! The pre-P8 key folded `active_goal` AND `decision` into one namespace
//! (`durable_fact/transient_goal/{sid}/{slot}`), discarding the slot_type
//! discriminator — every promoted slot looked like a "transient_goal"
//! regardless of whether it was a goal, a decision, or (now) an open loop.
//! That made the durable rows un-queryable by kind. P8 branches the key on
//! slot_type — `durable_fact/{slot_type}/{sid}/{slot}` — so each type lands
//! in a distinct, queryable namespace (`durable_fact/decision/...`,
//! `durable_fact/open_loop/...`, `durable_fact/active_goal/...`). The
//! `durable_fact/` prefix is preserved so `memory_loader.isDurableFactKey`
//! still classifies these as semantic-continuity rows (no loader change).
//!
//! ## Why composite_priority ≥ 0.5
//!
//! The post-v1.14.14.1 composite is `recency × slot_type_weight`. With
//! `active_goal` weight 0.95 and `decision` weight 0.85, a fresh (≤1 hour)
//! slot scores 0.95 / 0.85; a 1-hour-stale slot drops to ~0.475 / ~0.425.
//! Threshold 0.5 lets fresh slots through and filters slots that haven't
//! been touched in ≥1 hour (low-confidence promotion candidates).
//!
//! ## Failure mode
//!
//! Every operation is failure-soft. Missing state_mgr or memory backend →
//! return 0. Postgres unavailable for slot listing → log warn, return 0.
//! Individual mem.store failures are logged but don't abort the loop —
//! one bad row doesn't lose the others.

const std = @import("std");
const log = std.log.scoped(.promotion);

const memory_root = @import("../memory/root.zig");
const Memory = memory_root.Memory;
const zaki_state = @import("../zaki_state.zig");
const working_memory = @import("working_memory.zig");

/// Composite-priority floor for promotion. See module doc comment.
pub const PROMOTION_THRESHOLD: f64 = 0.5;

/// Information about a slot that crossed the promotion gate. Returned
/// to callers (mostly for tests + observability); production callers
/// only use the count.
pub const PromotedSlot = struct {
    original_slot_id: i32,
    durable_key: []const u8,
    promoted_at_unix: i64,

    pub fn deinit(self: *const PromotedSlot, allocator: std.mem.Allocator) void {
        allocator.free(self.durable_key);
    }
};

/// Result aggregate. Caller frees via `deinit`.
pub const PromotionResult = struct {
    promoted: []PromotedSlot,

    pub fn deinit(self: *PromotionResult, allocator: std.mem.Allocator) void {
        for (self.promoted) |*p| p.deinit(allocator);
        allocator.free(self.promoted);
    }

    pub fn count(self: PromotionResult) u32 {
        return @intCast(self.promoted.len);
    }
};

/// True iff the slot_type is in the promotion vocabulary.
///
/// P8 (memory-phase-0.5): `open_loop` joined `active_goal` + `decision`.
/// Open loops are trackable items the agent should follow up on across
/// session boundaries — losing them entirely is worse than carrying a
/// stale one the agent can ask about and close.
pub fn isPromotableSlotType(slot_type: []const u8) bool {
    return std.mem.eql(u8, slot_type, working_memory.SlotType.active_goal) or
        std.mem.eql(u8, slot_type, working_memory.SlotType.decision) or
        std.mem.eql(u8, slot_type, working_memory.SlotType.open_loop);
}

/// Build the durable promotion key for a slot. P8: branched by `slot_type`
/// so each promotable kind lands in a distinct, queryable namespace —
/// `durable_fact/<slot_type>/<session_id>/<slot_id>`. The `durable_fact/`
/// prefix is preserved so `memory_loader.isDurableFactKey` still classifies
/// the row as semantic-continuity (no loader change). Caller owns the
/// returned slice.
///
/// `slot_type` is expected to be one of the promotable `SlotType.*` static
/// strings; the function does not validate (callers gate on
/// `isPromotableSlotType` first), it just folds whatever it's given into
/// the key so the namespace always carries the discriminator verbatim.
pub fn promotionKey(
    allocator: std.mem.Allocator,
    slot_type: []const u8,
    session_id: []const u8,
    slot_id: i32,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "durable_fact/{s}/{s}/{d}",
        .{ slot_type, session_id, slot_id },
    );
}

/// Promote high-importance non-identity slots to durable_facts at
/// session-end. Returns the count of promoted slots (typically 0-2 per
/// session; capped by working_memory.RENDER_TOP_N which is 10).
///
/// **Ordering invariant (cross-agent):** in `commands.zig` session-end
/// path, this MUST run BEFORE `reflection.serialize(...)`-style writes
/// (Agent E G5) so the durable rows exist by the time the reflection
/// trail references them. See dispatch §"Hot-file boundary" and the
/// inline comment at the wire site in commands.zig.
///
/// Failure-soft: returns an empty PromotionResult on any setup error
/// (missing memory backend, postgres unavailable, etc.). Per-slot
/// errors are logged + skipped without aborting the loop.
pub fn promoteWMToDurableAtSessionEnd(
    allocator: std.mem.Allocator,
    state_mgr: ?*zaki_state.Manager,
    mem: ?Memory,
    user_id: i64,
    session_id: []const u8,
) PromotionResult {
    // **Failure-soft policy:** this function returns `PromotionResult`, not
    // `!PromotionResult`. No `errdefer` can fire because no error escapes.
    // All cleanup MUST be explicit at each `catch ... continue` site below
    // — keep that pattern when adding new failure paths.

    const smgr = state_mgr orelse {
        log.info("promotion.skipped reason=no_state_mgr session={s}", .{session_id});
        return emptyResult(allocator);
    };
    const m = mem orelse {
        log.info("promotion.skipped reason=no_memory_backend session={s}", .{session_id});
        return emptyResult(allocator);
    };

    const slots = smgr.listWorkingMemorySlots(allocator, user_id, session_id) catch |err| {
        log.warn("promotion.list_failed err={s} session={s}", .{ @errorName(err), session_id });
        return emptyResult(allocator);
    };
    defer memory_root.freeWorkingMemorySlots(allocator, slots);

    if (slots.len == 0) {
        log.info("promotion.no_slots session={s}", .{session_id});
        return emptyResult(allocator);
    }

    const now = std.time.timestamp();
    var collected: std.ArrayListUnmanaged(PromotedSlot) = .{};

    for (slots) |*s| {
        if (!isPromotableSlotType(s.slot_type)) continue;
        // Identity slots are pinned + already handled by
        // pinIdentityFromUserState at session-start; double-promoting
        // would duplicate the same content under a different key.
        // (Belt-and-suspenders — isPromotableSlotType already excludes identity.)
        if (std.mem.eql(u8, s.slot_type, working_memory.SlotType.identity)) continue;

        const composite = working_memory.compositePriority(s, now);
        if (composite < PROMOTION_THRESHOLD) {
            log.info(
                "promotion.below_threshold slot_id={d} type={s} composite={d:.3} threshold={d:.2} session={s}",
                .{ s.slot_id, s.slot_type, composite, PROMOTION_THRESHOLD, session_id },
            );
            continue;
        }

        // Build the durable key. See module doc for the key-shape rationale.
        // P8: branched by slot_type via `promotionKey` so each promotable
        // kind (active_goal / decision / open_loop) is distinct + queryable.
        const key = promotionKey(allocator, s.slot_type, session_id, s.slot_id) catch |err| {
            log.warn("promotion.key_alloc_failed err={s} slot_id={d}", .{ @errorName(err), s.slot_id });
            continue;
        };
        // Don't `defer free(key)` here — ownership transfers into the
        // collected PromotedSlot on success. Each `catch` branch below
        // frees explicitly before `continue`.

        m.store(key, s.content, .core, session_id) catch |err| {
            log.warn(
                "promotion.store_failed err={s} key={s} slot_id={d} session={s}",
                .{ @errorName(err), key, s.slot_id, session_id },
            );
            allocator.free(key);
            continue;
        };

        collected.append(allocator, .{
            .original_slot_id = s.slot_id,
            .durable_key = key,
            .promoted_at_unix = now,
        }) catch |err| {
            log.warn(
                "promotion.collect_failed err={s} key={s} (memory persisted but result not tracked)",
                .{ @errorName(err), key },
            );
            allocator.free(key);
            continue;
        };
        // Ownership of `key` transferred into `collected` on append success.

        log.info(
            "promotion.promoted slot_id={d} type={s} composite={d:.3} key={s} session={s}",
            .{ s.slot_id, s.slot_type, composite, key, session_id },
        );
    }

    const final = collected.toOwnedSlice(allocator) catch {
        // OOM on the final slice — at this point the durable_facts
        // ARE written; we just can't report the list back. Log and
        // return empty rather than leak.
        log.warn("promotion.final_alloc_failed session={s}", .{session_id});
        for (collected.items) |*p| p.deinit(allocator);
        collected.deinit(allocator);
        return emptyResult(allocator);
    };
    log.info("promotion.session_complete count={d} session={s}", .{ final.len, session_id });
    return .{ .promoted = final };
}

/// Lazy zero-length PromotionResult — only invoked at each early-return
/// site, so the success path never pays for an unused zero-sized alloc.
/// Strict leak-checking allocators that bookkeep zero-sized allocs would
/// have flagged the prior `const empty = ...` at function entry.
inline fn emptyResult(allocator: std.mem.Allocator) PromotionResult {
    return .{ .promoted = allocator.alloc(PromotedSlot, 0) catch &.{} };
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test "isPromotableSlotType matches active_goal, decision, and open_loop (P8)" {
    try std.testing.expect(isPromotableSlotType(working_memory.SlotType.active_goal));
    try std.testing.expect(isPromotableSlotType(working_memory.SlotType.decision));
    // P8: open_loop is now promotable — open loops survive across sessions
    // as trackable items.
    try std.testing.expect(isPromotableSlotType(working_memory.SlotType.open_loop));
    try std.testing.expect(!isPromotableSlotType(working_memory.SlotType.identity));
    try std.testing.expect(!isPromotableSlotType(working_memory.SlotType.emotional));
    try std.testing.expect(!isPromotableSlotType(working_memory.SlotType.relationship));
    try std.testing.expect(!isPromotableSlotType(working_memory.SlotType.recent_entity));
    try std.testing.expect(!isPromotableSlotType(working_memory.SlotType.skill_state));
    try std.testing.expect(!isPromotableSlotType(working_memory.SlotType.temporal));
    try std.testing.expect(!isPromotableSlotType(working_memory.SlotType.open_question));
    try std.testing.expect(!isPromotableSlotType("unknown_type"));
}

test "promotionKey is branched by slot_type — distinct, queryable namespaces (P8)" {
    const allocator = std.testing.allocator;

    const goal_key = try promotionKey(allocator, working_memory.SlotType.active_goal, "sess_abc", 3);
    defer allocator.free(goal_key);
    const decision_key = try promotionKey(allocator, working_memory.SlotType.decision, "sess_abc", 3);
    defer allocator.free(decision_key);
    const loop_key = try promotionKey(allocator, working_memory.SlotType.open_loop, "sess_abc", 3);
    defer allocator.free(loop_key);

    // Each carries the durable_fact/ prefix (classification stays consistent
    // with the rest of Phase 0.5 — memory_loader.isDurableFactKey).
    try std.testing.expect(std.mem.startsWith(u8, goal_key, "durable_fact/"));
    try std.testing.expect(std.mem.startsWith(u8, decision_key, "durable_fact/"));
    try std.testing.expect(std.mem.startsWith(u8, loop_key, "durable_fact/"));

    // Each carries its OWN slot_type discriminator as the second segment.
    try std.testing.expectEqualStrings("durable_fact/active_goal/sess_abc/3", goal_key);
    try std.testing.expectEqualStrings("durable_fact/decision/sess_abc/3", decision_key);
    try std.testing.expectEqualStrings("durable_fact/open_loop/sess_abc/3", loop_key);

    // The whole point of P8: decision and open_loop keys for the SAME
    // (session, slot) are DISTINCT — the slot_type is no longer folded away.
    try std.testing.expect(!std.mem.eql(u8, decision_key, loop_key));
    try std.testing.expect(!std.mem.eql(u8, decision_key, goal_key));
    try std.testing.expect(!std.mem.eql(u8, goal_key, loop_key));

    // And each key actually contains its slot_type token (queryable by kind).
    try std.testing.expect(std.mem.indexOf(u8, decision_key, "/decision/") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_key, "/open_loop/") != null);
    try std.testing.expect(std.mem.indexOf(u8, goal_key, "/active_goal/") != null);
}

test "PROMOTION_THRESHOLD is 0.5" {
    try std.testing.expectEqual(@as(f64, 0.5), PROMOTION_THRESHOLD);
}

test "promoteWMToDurableAtSessionEnd with null state_mgr returns empty" {
    const allocator = std.testing.allocator;
    var result = promoteWMToDurableAtSessionEnd(allocator, null, null, 1, "test_session");
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.count());
}

test "PromotedSlot zero-init lifecycle" {
    const allocator = std.testing.allocator;
    const key = try allocator.dupe(u8, "durable_fact/decision/s1/2");
    var slot = PromotedSlot{
        .original_slot_id = 2,
        .durable_key = key,
        .promoted_at_unix = 1_700_000_000,
    };
    defer slot.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 2), slot.original_slot_id);
    try std.testing.expectEqualStrings("durable_fact/decision/s1/2", slot.durable_key);
}

test "compositePriority gate (sanity-check of the threshold against working_memory formula)" {
    // active_goal weight is 0.95, decision weight is 0.85 (per working_memory.zig).
    // Fresh slot (now): recency=1.0, so active_goal composite = 0.95, decision = 0.85.
    // Both above PROMOTION_THRESHOLD (0.5). Two-hour-stale (≈0.25 recency):
    //   active_goal composite ≈ 0.95 × 0.25 = 0.2375 < 0.5  → filtered.
    //   decision composite ≈ 0.85 × 0.25 = 0.2125 < 0.5     → filtered.
    // The gate behavior the production wire-up relies on. If the formula
    // changes in v1.14.19+, this test must update in lockstep with
    // commands.zig session-end behavior.
    const now: i64 = 1_700_000_000;
    var fresh_goal = memory_root.WorkingMemorySlot{
        .user_id = 1,
        .session_id = "test",
        .slot_id = 2,
        .slot_type = working_memory.SlotType.active_goal,
        .content = "ship v1.14.18-B",
        .source_key = null,
        .importance = 0.9,
        .pinned = false,
        .created_at_unix = now,
        .last_touched_at_unix = now,
    };
    const fresh_composite = working_memory.compositePriority(&fresh_goal, now);
    try std.testing.expect(fresh_composite >= PROMOTION_THRESHOLD);

    var stale_goal = fresh_goal;
    stale_goal.last_touched_at_unix = now - 7200; // 2 hours stale
    const stale_composite = working_memory.compositePriority(&stale_goal, now);
    try std.testing.expect(stale_composite < PROMOTION_THRESHOLD);
}
