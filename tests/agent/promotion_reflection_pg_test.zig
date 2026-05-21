//! v1.14.18-B Fix C — promotion → reflection-store postgres integration.
//!
//! The per-module unit tests for G16 (`promotion.zig`) and G5
//! (`reflection.zig` / `procedural_memory.zig`) run in-process with null
//! backends. This test pins the *one* thing they cannot: the full
//! session-end memory-lifecycle round-trip against a real postgres.
//!
//!   1. G16 (WM-CROSS-SESSION) — a high-importance `active_goal` working-
//!      memory slot is promoted to a `durable_fact/transient_goal/...` row
//!      by `promotion.promoteWMToDurableAtSessionEnd`, and that row is
//!      verified to actually exist in postgres by reading it back.
//!
//!   2. G5 (REFLECTION-STORE) — a `reflection.ReflectionTrail` carrying
//!      model-authored free text (with a quote, a backslash and a newline)
//!      is serialized and captured by `procedural_memory.captureSession`
//!      into `skill_executions.assumptions_made` (a postgres `jsonb`
//!      column), then read back and re-parsed. The `$6::jsonb` cast
//!      rejects malformed JSON at insert time, so a green run confirms the
//!      G5 JSON-escape fix round-trips end to end: serialize → jsonb
//!      insert → read-back as valid JSON.
//!
//! The `Memory` backend under test is `ZakiPostgresMemory` — the actual
//! production postgres path (`gateway.zig` wires it for postgres
//! deployments), a thin adapter over the same `zaki_state.Manager`. So the
//! durable_fact, the working-memory slot and the skill_executions row all
//! land in one schema, exactly as in production.
//!
//! Postgres-gated: skips cleanly unless built with `-Dengines=...,postgres`
//! AND `NULLALIS_POSTGRES_TEST_URL` is set — the same idiom as the pg tests
//! in `store_pgvector.zig` / `zaki_state.zig`. Each run uses a unique
//! schema so concurrent / repeated runs never collide.

const std = @import("std");
const build_options = @import("build_options");
const nullalis = @import("nullalis");

const zaki_state = nullalis.zaki_state;
const memory = nullalis.memory;
const env_rebrand = nullalis.env_rebrand;
const promotion = nullalis.agent.promotion;
const reflection = nullalis.agent.reflection;
const procedural_memory = nullalis.agent.procedural_memory;

test "v1.14.18-B G5+G16: WM-slot promotion + reflection capture round-trip to postgres" {
    // Compile-time gate. When built without postgres the remainder of this
    // body is comptime-unreachable and never analyzed, so the postgres-only
    // symbols need not resolve — the file still compiles under the default
    // `base,sqlite` profile.
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // Runtime gate: no test DB configured → skip (not fail).
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(
        allocator,
        "NULLALIS_POSTGRES_TEST_URL",
        "NULLCLAW_POSTGRES_TEST_URL",
    ) catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    // Unique-per-run schema — no collision across concurrent/repeat runs.
    const stamp = std.time.microTimestamp();
    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "nullalis_promo_refl_test_{d}", .{stamp});

    // ── State manager (postgres). Manager.init() runs migrate(), creating
    //    the fresh schema plus the users / working_memory / skill_executions
    //    / memories tables. A connection failure here means the configured
    //    URL is unreachable → skip rather than hard-fail (matches the
    //    zaki_state pg tests).
    var mgr = zaki_state.Manager.init(allocator, .{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    }) catch return error.SkipZigTest;
    defer mgr.deinit();

    const user_id: i64 = 1;
    const session_id = "promo-refl-test-session";

    // working_memory, skill_executions and memories all FK user_id →
    // users(user_id), so the user row must exist before any insert.
    try mgr.provisionUser(user_id, "/tmp/nullalis-promo-refl-test/workspace");

    // ── Memory backend: the production `zaki_postgres` adapter over the
    //    state manager. init/deinit are allocation-free; storage delegates
    //    to mgr.upsertMemory → the schema's `memories` table.
    var zpm = memory.ZakiPostgresMemory.init(allocator, &mgr, user_id);
    defer zpm.deinit();
    const mem = zpm.memory();

    // ═══ G16 — seed a promotable WM slot, run session-end promotion ═══
    //
    // slot_type "active_goal" == working_memory.SlotType.active_goal. A
    // freshly-upserted slot has last_touched_at = NOW(), so its composite
    // priority = recency(~1.0) × active_goal weight(0.95) ≈ 0.95, well
    // above promotion.PROMOTION_THRESHOLD (0.5) → it must be promoted.
    const slot_id: i32 = 2; // non-reserved (0 = identity, 1 = persona)
    const goal_content = "ship v1.14.18-B integration coverage";
    _ = try mgr.upsertWorkingMemorySlot(
        user_id,
        session_id,
        slot_id,
        "active_goal",
        goal_content,
        null, // source_key
        0.9, // importance
        false, // pinned
    );

    var prom_result = promotion.promoteWMToDurableAtSessionEnd(
        allocator,
        &mgr,
        mem,
        user_id,
        session_id,
    );
    defer prom_result.deinit(allocator);

    // Exactly one promotable slot was seeded → exactly one promotion.
    try std.testing.expectEqual(@as(u32, 1), prom_result.count());

    const expected_key = try std.fmt.allocPrint(
        allocator,
        "durable_fact/transient_goal/{s}/{d}",
        .{ session_id, slot_id },
    );
    defer allocator.free(expected_key);
    try std.testing.expectEqualStrings(expected_key, prom_result.promoted[0].durable_key);

    // The durable_fact row must actually be in postgres — read it back via
    // getMemory (a SELECT path distinct from the upsertMemory write path).
    const durable = (try mgr.getMemory(allocator, user_id, expected_key)) orelse {
        std.debug.print("durable_fact row missing in postgres for key '{s}'\n", .{expected_key});
        return error.DurableFactNotPersisted;
    };
    defer durable.deinit(allocator);
    try std.testing.expectEqualStrings(goal_content, durable.content);

    // ═══ G5 — build a reflection trail, capture it into skill_executions ═══
    var trail = reflection.ReflectionTrail{ .goal_text = goal_content };
    defer trail.deinit(allocator);
    try trail.append(allocator, 0, "memory_recall", "in_progress", "scanned prior sessions");
    // `learning` is model-authored free text. The embedded quote, backslash
    // and newline below must survive serialize → jsonb insert → read-back
    // as VALID json — this is the end-to-end check of the G5 escape fix.
    try trail.append(allocator, 1, "shell", "met", "user said \"ship it\" — path C:\\tmp\\out\nclosed the loop");

    const reflection_json = try trail.serialize(allocator);
    defer allocator.free(reflection_json);

    const tool_names = [_][]const u8{ "memory_recall", "shell", "web_search", "memory_recall", "shell", "edit" };
    const total_tool_calls: u32 = tool_names.len; // 6 ≥ CAPTURE_TOOL_THRESHOLD (5)

    const captured_id = procedural_memory.captureSession(
        allocator,
        &mgr,
        user_id,
        session_id,
        goal_content, // task_summary
        &tool_names,
        total_tool_calls,
        null, // goal_status — exercises the heuristic outcome_quality path
        reflection_json,
    ) orelse {
        // A null return means insertSkillExecution failed. The most likely
        // cause is a malformed assumptions_made payload rejected by the
        // `$6::jsonb` cast — i.e. a regression of the G5 JSON-escape fix.
        return error.SkillExecutionNotCaptured;
    };
    try std.testing.expect(captured_id > 0);

    // The skill_executions row must be in postgres — read it back.
    const traces = try mgr.listRecentSkillExecutions(
        allocator,
        user_id,
        procedural_memory.GENERIC_SKILL_NAME,
        5,
    );
    defer memory.freeSkillExecutions(allocator, traces);
    try std.testing.expect(traces.len >= 1);

    // Fresh schema + a single capture → the most-recent row (DESC order) is
    // the one we just inserted.
    const row = traces[0];
    try std.testing.expectEqual(captured_id, row.id);

    // assumptions_made_json carries the serialized reflection trail. The
    // `jsonb` column already rejected malformed input at insert time;
    // re-parsing on read-back is the belt-and-suspenders proof that the
    // adversarial quote / backslash / newline round-tripped as valid JSON.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        row.assumptions_made_json,
        .{},
    ) catch |err| {
        std.debug.print(
            "assumptions_made_json failed to parse ({s}): {s}\n",
            .{ @errorName(err), row.assumptions_made_json },
        );
        return error.AssumptionsJsonInvalid;
    };
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    // Two reflection entries were appended → two JSON array elements.
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}
