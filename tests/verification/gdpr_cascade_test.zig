//! S6.11 — GDPR D25 cascade pin.
//!
//! Two complementary checks:
//!   * STATIC: every `user_id BIGINT ... REFERENCES ... users(user_id)`
//!     line across every migration declares `ON DELETE CASCADE`. No
//!     count threshold — every line that PATTERN-MATCHES the user_id
//!     column-declaration shape must individually carry CASCADE.
//!   * LIVE: provision a user, seed user-scoped rows across EVERY
//!     cascade table reachable via the Manager's public CRUD surface,
//!     DELETE the user, and assert every seeded row is gone. Closes
//!     the prior coverage gap where only `memories` + `working_memory`
//!     were verified.

const std = @import("std");
const nullalis = @import("nullalis");
const migrations = nullalis.migrations;
const memory_root = nullalis.memory;
const harness = @import("harness.zig");

/// True iff `line` declares a `user_id` column with an FK to
/// `{schema}.users(user_id)`. Anchors to a COLUMN declaration so unrelated
/// names like `creating_user_id` or `deleted_user_id` paired with an
/// FK on the same line are NOT false-positives.
fn lineIsUserIdFk(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const trimmed = line[i..];
    if (!std.mem.startsWith(u8, trimmed, "user_id BIGINT") and
        !std.mem.startsWith(u8, trimmed, "user_id  BIGINT"))
    {
        return false;
    }
    return std.mem.indexOf(u8, trimmed, "REFERENCES") != null and
        std.mem.indexOf(u8, trimmed, "users(user_id)") != null;
}

test "S6.11 D25 unit: lineIsUserIdFk does not false-positive on prefixed column names" {
    try std.testing.expect(!lineIsUserIdFk("    creating_user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE SET NULL,"));
    try std.testing.expect(!lineIsUserIdFk("    deleted_user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE CASCADE,"));
    try std.testing.expect(!lineIsUserIdFk("    -- references {schema}.users(user_id) explanatory comment"));
}

test "S6.11 D25 unit: lineIsUserIdFk recognizes the canonical column declaration shapes" {
    try std.testing.expect(lineIsUserIdFk("    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,"));
    try std.testing.expect(lineIsUserIdFk("    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,"));
    try std.testing.expect(lineIsUserIdFk("    user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE SET NULL,"));
}

test "S6.11 D25 static: every user_id FK line declares ON DELETE CASCADE" {
    var total_user_fk_lines: usize = 0;
    for (migrations.MIGRATIONS) |m| {
        var lines = std.mem.splitScalar(u8, m.sql, '\n');
        var lineno: usize = 0;
        while (lines.next()) |line| : (lineno += 1) {
            if (!lineIsUserIdFk(line)) continue;
            total_user_fk_lines += 1;
            if (std.mem.indexOf(u8, line, "ON DELETE CASCADE") == null) {
                std.debug.print(
                    "S6.11 D25: user_id FK without ON DELETE CASCADE — migration={s} line={d}: {s}\n",
                    .{ m.name, lineno + 1, line },
                );
                return error.UserIdFkMissingCascade;
            }
        }
    }
    if (total_user_fk_lines == 0) {
        std.debug.print("S6.11 D25: no user_id FK lines found across any migration\n", .{});
        return error.NoUserIdFksFound;
    }
}

// ── Live PG D25 cascade — expanded coverage ──────────────────────────
//
// `provisionUser` seeds the user plus default rows in:
//   user_config, heartbeat, channel_state, onboarding, sessions.
// We then seed the user-scoped tables that the Manager exposes through
// public CRUD/readback helpers:
//   memories         (upsertMemory)
//   working_memory   (upsertWorkingMemorySlot)
//   user_secrets     (putSecret)
//   secret_mutations (recordSecretMutation)
//   jobs             (replaceJobsJson)
//   artifacts        (createArtifact)
//   trace_shares     (setTraceShare)
//
// The post-delete assertions verify every table that has a public
// readback path in this harness: sessions, memories, working_memory,
// user_secrets, secret_mutations, jobs, artifacts (plus
// artifact_versions transitively), and trace_shares. Tables without a
// public seed/readback helper stay pinned by the static line-scan above.

test "S6.11 D25 live: DELETE FROM users cascades EVERY publicly-seedable table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);
    var prov = try harness.provisionTestUser(allocator, test_url, "d25_cascade", "/tmp/nullalis-s6-d25");
    defer harness.dropAndDeinit(&prov.mgr, "d25_cascade");
    const uid = prov.uid;
    const mgr = &prov.mgr;

    // ── Seed every cascade table the public Manager surface reaches ──

    try mgr.upsertMemory(uid, "d25-memory-key", "tagged for cascade", .core, null);

    _ = try mgr.upsertWorkingMemorySlot(
        uid,
        "d25-session",
        2,
        "active_goal",
        "cascade me",
        null,
        0.9,
        false,
    );

    try mgr.putSecret(uid, "d25-secret-key", "cascade-secret-value");
    try mgr.recordSecretMutation(uid, "d25-secret-key", "put", null, "ok", null);
    // Argument order: (uid, session_id, json_array). session_id "main"
    // is normalized to the user's main session key (created by
    // provisionUser); the json MUST be an array (it is fed through
    // `jsonb_array_elements`).
    try mgr.replaceJobsJson(uid, "main", "[{\"id\":\"d25-job\",\"job_type\":\"shell\",\"expression\":\"@once:0\"}]");

    const artifact = try mgr.createArtifact(
        allocator,
        uid,
        "d25-artifact-session",
        "D25 cascade artifact",
        "markdown",
        "# cascade",
        "sha256:d25",
        1_716_000_000,
    );
    defer {
        allocator.free(artifact.id);
        allocator.free(artifact.title);
        allocator.free(artifact.kind);
        if (artifact.session_id) |s| allocator.free(s);
        if (artifact.share_code) |s| allocator.free(s);
        allocator.free(artifact.metadata_jsonb);
    }

    try mgr.setTraceShare(uid, "d25-run", "shr-d25-cascade-XYZ", "[]", 1_716_000_000, 1_716_999_999);

    // ── Pre-condition: every seeded table has rows for `uid` ─────────

    const mem_before = try mgr.getMemory(allocator, uid, "d25-memory-key");
    if (mem_before) |m| m.deinit(allocator);
    try std.testing.expect(mem_before != null);

    const wm_before = try mgr.listWorkingMemorySlots(allocator, uid, "d25-session");
    defer {
        for (wm_before) |*slot| slot.deinit(allocator);
        allocator.free(wm_before);
    }
    try std.testing.expect(wm_before.len >= 1);

    const secrets_before = try mgr.listSecretKeys(allocator, uid);
    defer {
        for (secrets_before) |k| allocator.free(k);
        allocator.free(secrets_before);
    }
    try std.testing.expect(secrets_before.len >= 1);

    const mutations_before = try mgr.listSecretMutations(allocator, uid, 10);
    defer {
        for (mutations_before) |*r| r.deinit(allocator);
        allocator.free(mutations_before);
    }
    try std.testing.expect(mutations_before.len >= 1);

    const jobs_before = try mgr.getJobsJson(allocator, uid);
    defer allocator.free(jobs_before);
    try std.testing.expect(std.mem.indexOf(u8, jobs_before, "d25-job") != null);

    const artifacts_before = try mgr.listArtifactsForUser(allocator, uid, null, 100);
    defer nullalis.zaki_state.freeArtifactRows(allocator, artifacts_before);
    try std.testing.expect(artifacts_before.len >= 1);

    const sessions_before = try mgr.listUserSessions(allocator, uid);
    defer {
        for (sessions_before) |*s| s.deinit(allocator);
        allocator.free(sessions_before);
    }
    try std.testing.expect(sessions_before.len >= 1);

    const share_before = try mgr.getTraceByShareCode(allocator, "shr-d25-cascade-XYZ", 1_716_000_001);
    if (share_before) |s| {
        allocator.free(s.share_code);
        allocator.free(s.run_id);
        allocator.free(s.events_json);
    } else {
        return error.TraceShareNotSeededBeforeDelete;
    }

    // ── Cascade trigger: DELETE FROM users ───────────────────────────
    try mgr.deleteUser(uid);

    // ── Post-condition: every seeded table now has 0 rows for `uid` ──

    const mem_after = try mgr.getMemory(allocator, uid, "d25-memory-key");
    if (mem_after) |m| m.deinit(allocator);
    if (mem_after != null) return error.MemoryRowSurvivedUserDelete;

    const wm_after = try mgr.listWorkingMemorySlots(allocator, uid, "d25-session");
    defer {
        for (wm_after) |*slot| slot.deinit(allocator);
        allocator.free(wm_after);
    }
    if (wm_after.len != 0) {
        std.debug.print("S6.11 D25 live: working_memory has {d} surviving slot(s) — cascade broken\n", .{wm_after.len});
        return error.WorkingMemorySlotSurvivedUserDelete;
    }

    const secrets_after = try mgr.listSecretKeys(allocator, uid);
    defer {
        for (secrets_after) |k| allocator.free(k);
        allocator.free(secrets_after);
    }
    if (secrets_after.len != 0) {
        std.debug.print("S6.11 D25 live: user_secrets has {d} surviving key(s) — cascade broken\n", .{secrets_after.len});
        return error.UserSecretsSurvivedUserDelete;
    }

    const mutations_after = try mgr.listSecretMutations(allocator, uid, 10);
    defer {
        for (mutations_after) |*r| r.deinit(allocator);
        allocator.free(mutations_after);
    }
    if (mutations_after.len != 0) {
        std.debug.print("S6.11 D25 live: secret_mutations has {d} surviving rows — cascade broken\n", .{mutations_after.len});
        return error.SecretMutationsSurvivedUserDelete;
    }

    const jobs_after = try mgr.getJobsJson(allocator, uid);
    defer allocator.free(jobs_after);
    if (std.mem.indexOf(u8, jobs_after, "d25-job") != null) {
        std.debug.print("S6.11 D25 live: jobs payload survived for deleted user: {s}\n", .{jobs_after});
        return error.JobsSurvivedUserDelete;
    }

    const artifacts_after = try mgr.listArtifactsForUser(allocator, uid, null, 100);
    defer nullalis.zaki_state.freeArtifactRows(allocator, artifacts_after);
    if (artifacts_after.len != 0) {
        std.debug.print("S6.11 D25 live: artifacts has {d} surviving row(s) — cascade broken\n", .{artifacts_after.len});
        return error.ArtifactsSurvivedUserDelete;
    }

    const sessions_after = try mgr.listUserSessions(allocator, uid);
    defer {
        for (sessions_after) |*s| s.deinit(allocator);
        allocator.free(sessions_after);
    }
    if (sessions_after.len != 0) {
        std.debug.print("S6.11 D25 live: sessions has {d} surviving row(s) — cascade broken\n", .{sessions_after.len});
        return error.SessionsSurvivedUserDelete;
    }

    const share_after = try mgr.getTraceByShareCode(allocator, "shr-d25-cascade-XYZ", 1_716_000_001);
    if (share_after) |s| {
        allocator.free(s.share_code);
        allocator.free(s.run_id);
        allocator.free(s.events_json);
        std.debug.print("S6.11 D25 live: trace_shares survived user delete — cascade broken\n", .{});
        return error.TraceShareSurvivedUserDelete;
    }
}
