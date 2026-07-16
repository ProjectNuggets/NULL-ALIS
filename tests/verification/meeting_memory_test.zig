//! WP-15 Minutes meeting-memory provenance and exact-erasure gate.
//!
//! The durable writer is intentionally narrower than generic extraction:
//! one approved candidate becomes one source-scoped Brain row and one exact
//! provenance link. It creates no graph, entity, working-memory, event, or
//! vector carrier. Meeting erasure is idempotent, leaves a content-free
//! tombstone, and cannot touch another meeting, tenant, or byte-identical
//! generic memory.

const std = @import("std");
const nullalis = @import("nullalis");
const harness = @import("harness.zig");
const c = @cImport({
    @cInclude("libpq-fe.h");
});

const meeting_memory = nullalis.meeting_memory;

const test_pseudonym_key = [_]u8{0xa5} ** 32;
const test_receipt_signing_seed = [_]u8{0x31} ** 32;
const test_pseudonymizer = blk: {
    @setEvalBranchQuota(100_000);
    break :blk meeting_memory.Pseudonymizer.init(test_pseudonym_key);
};

fn installMeetingMemoryCrypto(mgr: anytype) !void {
    try mgr.installMeetingMemoryCryptoForTests(
        test_pseudonym_key,
        test_receipt_signing_seed,
        null,
    );
}

fn execPostgresSql(
    allocator: std.mem.Allocator,
    test_url: []const u8,
    sql: []const u8,
    expect_success: bool,
) !void {
    const url_z = try allocator.dupeZ(u8, test_url);
    defer allocator.free(url_z);
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    const conn = c.PQconnectdb(url_z.ptr) orelse return error.TestPostgresConnectFailed;
    defer c.PQfinish(conn);
    if (c.PQstatus(conn) != c.CONNECTION_OK) return error.TestPostgresConnectFailed;
    const result = c.PQexec(conn, sql_z.ptr) orelse return error.TestPostgresSqlFailed;
    defer c.PQclear(result);
    const status = c.PQresultStatus(result);
    const succeeded = status == c.PGRES_COMMAND_OK or status == c.PGRES_TUPLES_OK;
    if (succeeded != expect_success) {
        std.debug.print("WP-15 raw SQL unexpected status: {s}\n", .{std.mem.span(c.PQresultErrorMessage(result))});
        return error.TestPostgresSqlUnexpectedStatus;
    }
}

fn queryPostgresText(
    allocator: std.mem.Allocator,
    test_url: []const u8,
    sql: []const u8,
) ![]u8 {
    const url_z = try allocator.dupeZ(u8, test_url);
    defer allocator.free(url_z);
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    const conn = c.PQconnectdb(url_z.ptr) orelse return error.TestPostgresConnectFailed;
    defer c.PQfinish(conn);
    if (c.PQstatus(conn) != c.CONNECTION_OK) return error.TestPostgresConnectFailed;
    const result = c.PQexec(conn, sql_z.ptr) orelse return error.TestPostgresSqlFailed;
    defer c.PQclear(result);
    if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
        std.debug.print("WP-15 raw SQL query failed: {s}\n", .{std.mem.span(c.PQresultErrorMessage(result))});
        return error.TestPostgresSqlUnexpectedStatus;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var row: c_int = 0;
    while (row < c.PQntuples(result)) : (row += 1) {
        if (row != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, std.mem.span(c.PQgetvalue(result, row, 0)));
    }
    return out.toOwnedSlice(allocator);
}

fn freeEvents(allocator: std.mem.Allocator, events: []nullalis.memory.MemoryEventRow) void {
    for (events) |*event| event.deinit(allocator);
    allocator.free(events);
}

test "WP-15 schema: provenance links are one-to-one and receipts cannot retain content" {
    const migration_sql = try harness.loadProjectFile("src/migrations/0011_meeting_memory_provenance.sql");
    const index_migration_sql = try harness.loadProjectFile("src/migrations/0012_meeting_memory_erasure_indexes.sql");
    const state_source = try harness.loadProjectFile("src/zaki_state.zig");
    const required = [_][]const u8{
        "CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_crypto_state",
        "CREATE TABLE IF NOT EXISTS {schema}.memory_source_links",
        "CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_receipts",
        "CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_tombstones",
        "CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_account_erasure_tombstones",
        "CREATE TRIGGER meeting_memory_crypto_state_no_update_delete",
        "CREATE TRIGGER meeting_memory_crypto_state_no_truncate",
        "CREATE TRIGGER meeting_memory_erasure_tombstones_no_update_delete",
        "CREATE TRIGGER meeting_memory_erasure_tombstones_no_truncate",
        "CREATE TRIGGER meeting_memory_account_tombstones_no_update_delete",
        "CREATE TRIGGER meeting_memory_account_tombstones_no_truncate",
        "CREATE TRIGGER meeting_memory_erasure_receipts_no_update",
        "CREATE TRIGGER meeting_memory_erasure_receipts_no_truncate",
        "FOREIGN KEY (user_id, memory_key)",
        "UNIQUE INDEX IF NOT EXISTS idx_memory_source_links_memory",
        "(user_id, memory_key)",
        "pseudonym_key_id",
        "user_scope_digest",
        "meeting_scope_digest",
        "source_digest",
        "candidate_digest",
        "consent_grant_digest",
        "consent_policy_version",
        "consented_at",
        "receipt_key_id",
        "receipt_signature",
        "idx_meeting_memory_erasure_receipts_key_id",
        "memory_source_links_deleted",
        "memories_deleted",
        "memory_events_deleted",
        "memory_embeddings_deleted",
        "memory_vectors_deleted",
        "memory_entities_deleted",
        "memory_edges_deleted",
        "working_memory_deleted",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, migration_sql, needle) == null) {
            std.debug.print("WP-15 migration missing invariant: {s}\n", .{needle});
            return error.MissingMeetingMemorySchemaInvariant;
        }
    }

    const recoverable_concurrent_indexes = [_]struct {
        drop: []const u8,
        create: []const u8,
    }{
        .{
            .drop = "DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_events_user_memory_all",
            .create = "CREATE INDEX CONCURRENTLY idx_memory_events_user_memory_all",
        },
        .{
            .drop = "DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_edges_source_all",
            .create = "CREATE INDEX CONCURRENTLY idx_memory_edges_source_all",
        },
        .{
            .drop = "DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_edges_target_all",
            .create = "CREATE INDEX CONCURRENTLY idx_memory_edges_target_all",
        },
        .{
            .drop = "DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_edges_episodes_all",
            .create = "CREATE INDEX CONCURRENTLY idx_memory_edges_episodes_all",
        },
    };
    for (recoverable_concurrent_indexes) |pair| {
        const drop_at = std.mem.indexOf(u8, index_migration_sql, pair.drop) orelse {
            std.debug.print("WP-15 erasure index migration missing retry drop: {s}\n", .{pair.drop});
            return error.MissingMeetingMemoryErasureIndex;
        };
        const create_at = std.mem.indexOf(u8, index_migration_sql, pair.create) orelse {
            std.debug.print("WP-15 erasure index migration missing rebuild: {s}\n", .{pair.create});
            return error.MissingMeetingMemoryErasureIndex;
        };
        if (drop_at >= create_at) {
            return error.UnsafeMeetingMemoryErasureIndexRetryOrder;
        }
    }
    try std.testing.expect(std.mem.indexOf(
        u8,
        index_migration_sql,
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        index_migration_sql,
        "ON {schema}.memory_edges USING GIN (episodes)",
    ) != null);

    const source_links_end = std.mem.indexOf(
        u8,
        migration_sql,
        "CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_tombstones",
    ) orelse return error.MissingMeetingMemoryTombstone;
    const source_links_sql = migration_sql[0..source_links_end];
    const forbidden_source_link_columns = [_][]const u8{
        "source_item_id TEXT",
        "meeting_id TEXT",
    };
    for (forbidden_source_link_columns) |needle| {
        if (std.mem.indexOf(u8, source_links_sql, needle) != null) {
            std.debug.print("WP-15 provenance retains raw identifier column: {s}\n", .{needle});
            return error.ContentBearingMeetingProvenance;
        }
    }

    const store_start = std.mem.lastIndexOf(
        u8,
        state_source,
        "pub fn storeMeetingMemory(",
    ) orelse return error.MissingMeetingMemoryStore;
    const erase_start = std.mem.indexOfPos(
        u8,
        state_source,
        store_start,
        "pub fn eraseMeetingMemories(",
    ) orelse return error.MissingMeetingMemoryErase;
    const store_source = state_source[store_start..erase_start];
    const forbidden_store_fields = [_][]const u8{
        "source_item_id",
        "meeting_id",
    };
    for (forbidden_store_fields) |needle| {
        if (std.mem.indexOf(u8, store_source, needle) != null) {
            std.debug.print("WP-15 store persists or replays raw identifier: {s}\n", .{needle});
            return error.ContentBearingMeetingStore;
        }
    }

    const receipt_start = std.mem.indexOf(u8, migration_sql, "CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_receipts") orelse
        return error.MissingMeetingMemoryReceipt;
    const receipt_sql = migration_sql[receipt_start..];
    const forbidden_receipt_columns = [_][]const u8{
        "content TEXT",
        "candidate TEXT",
        "transcript TEXT",
        "summary TEXT",
        "payload JSON",
        "metadata JSON",
        "grant_id TEXT",
        "meeting_id TEXT",
        "request_id TEXT",
        "idempotency_key TEXT",
        "user_id BIGINT",
        "receipt_digest TEXT",
    };
    for (forbidden_receipt_columns) |needle| {
        if (std.mem.indexOf(u8, receipt_sql, needle) != null) {
            std.debug.print("WP-15 receipt contains forbidden content field: {s}\n", .{needle});
            return error.ContentBearingMeetingErasureReceipt;
        }
    }

    const bigint_count_fragments = [_][]const u8{
        "$6::bigint, $7::bigint, $8::bigint, $9::bigint, $10::bigint",
        "$11::bigint, $12::bigint, $13::bigint",
    };
    for (bigint_count_fragments) |fragment| {
        if (std.mem.indexOf(u8, state_source, fragment) == null) {
            return error.MeetingErasureReceiptCountNarrowing;
        }
    }
    if (std.mem.indexOf(u8, state_source, "$6::integer, $7::integer") != null) {
        return error.MeetingErasureReceiptCountNarrowing;
    }
}

fn source(user_id: i64, item_id: []const u8, meeting_id: []const u8) !meeting_memory.SourceTuple {
    return meeting_memory.SourceTuple.init(.{
        .user_id = user_id,
        .source_item_id = item_id,
        .meeting_id = meeting_id,
    });
}

fn prepared(
    source_tuple: meeting_memory.SourceTuple,
    kind: meeting_memory.CandidateKind,
    text: []const u8,
    grant_id: []const u8,
) !meeting_memory.PreparedMemory {
    return preparedWith(&test_pseudonymizer, source_tuple, kind, text, grant_id);
}

fn preparedWith(
    pseudonymizer: *const meeting_memory.Pseudonymizer,
    source_tuple: meeting_memory.SourceTuple,
    kind: meeting_memory.CandidateKind,
    text: []const u8,
    grant_id: []const u8,
) !meeting_memory.PreparedMemory {
    const candidate = try meeting_memory.Candidate.init(kind, text, .approved);
    const grant = try meeting_memory.ConfirmedConsentGrant.init(pseudonymizer, source_tuple, candidate, .{
        .grant_id = grant_id,
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    return meeting_memory.PreparedMemory.init(pseudonymizer, source_tuple, candidate, grant);
}

test "WP-15 live: default-off boot becomes fail-closed after crypto binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);

    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "meeting_crypto_boot");
    const drop_sql = try std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema},
    );
    defer execPostgresSql(allocator, test_url, drop_sql, true) catch |err| {
        std.debug.print("WP-15 crypto boot cleanup failed: {s}\n", .{@errorName(err)});
    };

    const cfg = nullalis.config.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
        .meeting_memory_crypto = .{
            .pseudonym_key_env = "NULLALIS_WP15_TEST_ABSENT_PSEUDONYM_KEY",
            .receipt_signing_seed_env = "NULLALIS_WP15_TEST_ABSENT_RECEIPT_SEED",
        },
    };

    // A genuinely unused Minutes schema remains default-off and boots with no
    // operator secrets. First source-scoped use binds the pseudonym key.
    {
        var mgr = try nullalis.zaki_state.Manager.init(allocator, cfg);
        defer mgr.deinit();
        mgr.skipExternalIdentityForTests();
        try installMeetingMemoryCrypto(&mgr);
        const user_id = harness.testUid();
        try mgr.provisionUser(user_id, "/tmp/nullalis-minutes-crypto-boot");
        const source_tuple = try source(user_id, "transcript-a", "meeting-a");
        _ = try mgr.storeMeetingMemory(try prepared(
            source_tuple,
            .decision,
            "Keep the erasure capability ready",
            "grant-a",
        ));
    }

    // Losing both operator secrets after activation is a readiness failure,
    // not a latent surprise on the first store/delete/erasure request.
    try std.testing.expectError(
        error.MeetingMemoryCryptoUnavailable,
        nullalis.zaki_state.Manager.init(allocator, cfg),
    );
}

test "WP-15 live: two-phase receipt rotation is bidirectionally compatible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);

    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "meeting_crypto_rotation");
    const drop_sql = try std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema},
    );
    defer execPostgresSql(allocator, test_url, drop_sql, true) catch |err| {
        std.debug.print("WP-15 rotation cleanup failed: {s}\n", .{@errorName(err)});
    };
    const cfg = nullalis.config.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
        .meeting_memory_crypto = .{
            .pseudonym_key_env = "NULLALIS_WP15_ROTATION_ABSENT_PSEUDONYM_KEY",
            .receipt_signing_seed_env = "NULLALIS_WP15_ROTATION_ABSENT_RECEIPT_SEED",
        },
    };

    // Both pods boot while the schema is still default-off. Phase one gives
    // K1 pods K2's public key; phase two gives K2 pods K1's public key.
    var k1_pod = try nullalis.zaki_state.Manager.init(allocator, cfg);
    defer k1_pod.deinit();
    var k2_pod = try nullalis.zaki_state.Manager.init(allocator, cfg);
    defer k2_pod.deinit();
    k1_pod.skipExternalIdentityForTests();
    k2_pod.skipExternalIdentityForTests();
    const k1_seed = [_]u8{0x41} ** 32;
    const k2_seed = [_]u8{0x42} ** 32;
    const k1_signer = try meeting_memory.ErasureReceiptSigner.init(k1_seed);
    const k2_signer = try meeting_memory.ErasureReceiptSigner.init(k2_seed);
    try k1_pod.installMeetingMemoryCryptoForTests(
        test_pseudonym_key,
        k1_seed,
        k2_signer.publicKeyBytes(),
    );
    try k2_pod.installMeetingMemoryCryptoForTests(
        test_pseudonym_key,
        k2_seed,
        k1_signer.publicKeyBytes(),
    );

    const user_id = harness.testUid();
    try k1_pod.provisionUser(user_id, "/tmp/nullalis-minutes-rotation");
    _ = try k1_pod.storeMeetingMemory(try prepared(
        try source(user_id, "transcript-k1", "meeting-k1"),
        .decision,
        "K1 signs before the rollout flips",
        "grant-k1",
    ));
    _ = try k1_pod.storeMeetingMemory(try prepared(
        try source(user_id, "transcript-k2", "meeting-k2"),
        .decision,
        "K2 signs after the rollout flips",
        "grant-k2",
    ));

    const request_k1 = try meeting_memory.ErasureRequest.init(
        &test_pseudonymizer,
        user_id,
        "meeting-k1",
        "request-k1",
    );
    const k1_receipt = try k1_pod.eraseMeetingMemories(request_k1);
    try std.testing.expectEqualStrings(k1_signer.keyId(), k1_receipt.receiptKeyId());
    const k1_seen_by_k2 = try k2_pod.eraseMeetingMemories(request_k1);
    try std.testing.expectEqualStrings(k1_receipt.receiptSignature(), k1_seen_by_k2.receiptSignature());

    const request_k2 = try meeting_memory.ErasureRequest.init(
        &test_pseudonymizer,
        user_id,
        "meeting-k2",
        "request-k2",
    );
    const k2_receipt = try k2_pod.eraseMeetingMemories(request_k2);
    try std.testing.expectEqualStrings(k2_signer.keyId(), k2_receipt.receiptKeyId());
    const k2_seen_by_k1 = try k1_pod.eraseMeetingMemories(request_k2);
    try std.testing.expectEqualStrings(k2_receipt.receiptSignature(), k2_seen_by_k1.receiptSignature());
}

test "WP-15 live: source-scoped store and meeting erase isolate tenants and byte-identical rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);

    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "meeting_memory");
    var mgr = try harness.newManager(allocator, test_url, schema);
    defer harness.dropAndDeinit(&mgr, "meeting_memory");
    mgr.skipExternalIdentityForTests();
    try installMeetingMemoryCrypto(&mgr);

    const user_a = harness.testUid();
    const user_b = user_a + 1;
    try mgr.provisionUser(user_a, "/tmp/nullalis-minutes-a");
    try mgr.provisionUser(user_b, "/tmp/nullalis-minutes-b");

    const meeting_a = try source(user_a, "transcript-a", "meeting-a");
    const meeting_b = try source(user_a, "transcript-b", "meeting-b");
    const other_tenant = try source(user_b, "transcript-a", "meeting-a");
    const identical_text = "Launch the pilot on Tuesday";

    const memory_a = try prepared(meeting_a, .decision, identical_text, "grant-a");
    const memory_b = try prepared(meeting_b, .decision, identical_text, "grant-b");
    const memory_other_tenant = try prepared(other_tenant, .decision, identical_text, "grant-c");

    // A copied authority must not be able to pair tenant B with tenant A's
    // meeting digest. Reject it before locks/tombstones so tenant A's later
    // legitimate erasure cannot be poisoned by the global digest uniqueness.
    var cross_tenant_poison = try meeting_memory.ErasureRequest.init(
        &test_pseudonymizer,
        user_a,
        "meeting-a",
        "request-cross-tenant-poison",
    );
    cross_tenant_poison.user_id = user_b;
    try std.testing.expectError(
        error.ErasureRequestIntegrityMismatch,
        mgr.eraseMeetingMemories(cross_tenant_poison),
    );

    // The persistence boundary revalidates borrowed bytes rather than trusting
    // a constructor that may have run before the caller reused its buffer.
    var mutable_text = [_]u8{ 'S', 'h', 'i', 'p', ' ', 'o', 'n', ' ', 'F', 'r', 'i', 'd', 'a', 'y' };
    const mutable_candidate = try meeting_memory.Candidate.init(.decision, &mutable_text, .approved);
    const mutable_grant = try meeting_memory.ConfirmedConsentGrant.init(&test_pseudonymizer, meeting_a, mutable_candidate, .{
        .grant_id = "grant-mutable",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const mutable_prepared = try meeting_memory.PreparedMemory.init(&test_pseudonymizer, meeting_a, mutable_candidate, mutable_grant);
    mutable_text[0] = 'X';
    try std.testing.expectError(
        error.PreparedMemoryIntegrityMismatch,
        mgr.storeMeetingMemory(mutable_prepared),
    );

    const first = try mgr.storeMeetingMemory(memory_a);
    try std.testing.expect(first.inserted);
    const replay = try mgr.storeMeetingMemory(memory_a);
    try std.testing.expect(!replay.inserted);
    try std.testing.expectEqualStrings(first.memoryKey(), replay.memoryKey());

    // Persisted pseudonyms are bound to one deployment key. A differently
    // keyed runtime must fail closed instead of creating a second digest
    // universe that could bypass the existing tombstones.
    const alternate_pseudonym_key = [_]u8{0xb6} ** 32;
    try std.testing.expectError(
        error.MeetingMemoryPseudonymKeyMismatch,
        mgr.installMeetingMemoryCryptoForTests(
            alternate_pseudonym_key,
            [_]u8{0x32} ** 32,
            null,
        ),
    );

    // Callers still provide validated opaque source IDs, but durable
    // provenance and replay identity retain only tenant-bound digests.
    const meeting_a_scope = meeting_memory.formatSha256(memory_a.provenance.identity.meeting_digest);
    const meeting_a_source = meeting_memory.formatSha256(memory_a.provenance.identity.source_digest);
    const meeting_a_candidate = meeting_memory.formatSha256(memory_a.provenance.identity.candidate_digest);
    const verify_digest_only_provenance_sql = try std.fmt.allocPrint(
        allocator,
        "DO $wp15$ BEGIN " ++
            "IF EXISTS (SELECT 1 FROM information_schema.columns " ++
            "WHERE table_schema = '{s}' AND table_name = 'memory_source_links' " ++
            "AND column_name IN ('source_item_id', 'meeting_id')) " ++
            "THEN RAISE EXCEPTION 'raw meeting identifier column survived'; END IF; " ++
            "IF (SELECT count(*) FROM {s}.memory_source_links " ++
            "WHERE user_id = {d} AND memory_key = '{s}' " ++
            "AND meeting_scope_digest = '{s}' AND source_digest = '{s}' " ++
            "AND candidate_digest = '{s}') <> 1 " ++
            "THEN RAISE EXCEPTION 'digest-only exact provenance missing'; END IF; " ++
            "END $wp15$",
        .{
            schema,
            schema,
            user_a,
            first.memoryKey(),
            meeting_a_scope,
            meeting_a_source,
            meeting_a_candidate,
        },
    );
    try execPostgresSql(allocator, test_url, verify_digest_only_provenance_sql, true);

    const second_meeting = try mgr.storeMeetingMemory(memory_b);
    const second_tenant = try mgr.storeMeetingMemory(memory_other_tenant);
    try std.testing.expect(!std.mem.eql(u8, first.memoryKey(), second_meeting.memoryKey()));
    try std.testing.expect(!std.mem.eql(u8, first.memoryKey(), second_tenant.memoryKey()));

    // Every generic persistence mutation rejects the reserved namespace even
    // when a caller bypasses agent-tool predicates (for example governance
    // HTTP routes or a direct backend handle).
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.upsertMemory(user_a, first.memoryKey(), "overwrite", .core, null),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.upsertMemoryWithMetadata(user_a, first.memoryKey(), "overwrite", .core, null, "{}"),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.forgetMemory(user_a, first.memoryKey()),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.setMemoryInvalidation(user_a, first.memoryKey(), 1_784_200_050, 1_784_200_050),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.editMemorySupersede(allocator, user_a, first.memoryKey(), "edited", 1_784_200_050),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.archiveInformationScoped(allocator, user_a, first.memoryKey(), 1_784_200_050),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.demoteMemoryFromCore(user_a, first.memoryKey(), "daily"),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.setMemorySource(user_a, first.memoryKey(), "session-a", "snippet"),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.upsertMemoryEdge(user_a, first.memoryKey(), "generic-identical", "MENTIONS", null, 1.0),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.upsertMemoryEdgeRich(
            user_a,
            "generic-unrelated",
            "generic-identical",
            "EPISODE_LEAK",
            null,
            1.0,
            "Sensitive meeting fact",
            null,
            first.memoryKey(),
            null,
            null,
        ),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.upsertWorkingMemorySlot(user_a, "session-a", 1, "decision", identical_text, first.memoryKey(), 1.0, false),
    );
    const governed_assignment = [_]nullalis.memory.CommunityAssignment{.{
        .key = first.memoryKey(),
        .community_id = 7,
    }};
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.setMemoryCommunityIds(user_a, &governed_assignment),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.markMemorySupersededByKey(user_a, first.memoryKey(), "generic-unrelated"),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.markMemorySupersededByKey(user_a, "generic-unrelated", first.memoryKey()),
    );
    try std.testing.expectError(
        error.MeetingMemoryRequiresDedicatedMutation,
        mgr.propagateCorrection(allocator, user_a, first.memoryKey(), "pilot"),
    );

    // Generic information-scoped forget uses content_hash sweeps. Meeting
    // rows deliberately carry content_hash=NULL, so forgetting a
    // byte-identical generic fact cannot sweep either meeting source.
    try mgr.upsertMemory(user_a, "generic-identical-forget", identical_text, .core, null);
    var generic_sweep = try mgr.forgetInformationScoped(
        allocator,
        user_a,
        "generic-identical-forget",
        1_784_200_100,
    );
    defer generic_sweep.deinit(allocator);
    try std.testing.expect(generic_sweep.primary_closed);
    const meeting_a_after_sweep = try mgr.getMemory(allocator, user_a, first.memoryKey());
    if (meeting_a_after_sweep) |entry| entry.deinit(allocator);
    try std.testing.expect(meeting_a_after_sweep != null);
    const meeting_b_after_sweep = try mgr.getMemory(allocator, user_a, second_meeting.memoryKey());
    if (meeting_b_after_sweep) |entry| entry.deinit(allocator);
    try std.testing.expect(meeting_b_after_sweep != null);

    // A second generic row proves meeting erasure does not over-delete by
    // candidate bytes either.
    try mgr.upsertMemory(user_a, "generic-identical", identical_text, .core, null);
    try mgr.upsertMemory(user_a, "generic-unrelated", "Unrelated graph fact", .core, null);

    // Reads remain available, but the generic access-counter side effect must
    // not mutate a source-governed Minutes row. Ordinary memories still bump.
    const reset_access_sql = try std.fmt.allocPrint(
        allocator,
        "UPDATE {s}.memories SET access_count = 0, last_accessed_at = NULL " ++
            "WHERE user_id = {d} AND key IN ('{s}', 'generic-identical')",
        .{ schema, user_a, first.memoryKey() },
    );
    try execPostgresSql(allocator, test_url, reset_access_sql, true);
    const governed_read = (try mgr.getMemory(allocator, user_a, first.memoryKey())).?;
    governed_read.deinit(allocator);
    const generic_read = (try mgr.getMemory(allocator, user_a, "generic-identical")).?;
    generic_read.deinit(allocator);
    const verify_access_sql = try std.fmt.allocPrint(
        allocator,
        "DO $wp15$ BEGIN " ++
            "IF EXISTS (SELECT 1 FROM {s}.memories WHERE user_id = {d} AND key = '{s}' " ++
            "AND (access_count <> 0 OR last_accessed_at IS NOT NULL)) " ++
            "THEN RAISE EXCEPTION 'meeting memory access metadata mutated'; END IF; " ++
            "IF NOT EXISTS (SELECT 1 FROM {s}.memories WHERE user_id = {d} AND key = 'generic-identical' " ++
            "AND access_count = 1 AND last_accessed_at IS NOT NULL) " ++
            "THEN RAISE EXCEPTION 'generic access metadata did not bump'; END IF; " ++
            "END $wp15$",
        .{ schema, user_a, first.memoryKey(), schema, user_a },
    );
    try execPostgresSql(allocator, test_url, verify_access_sql, true);

    // Prose-survey input is itself a mutation boundary: the judge must never
    // receive a meeting-derived key that markMemorySupersededByKey would later
    // be asked to mutate. A byte-identical generic row remains eligible.
    const prose_facts = try mgr.fetchProseFactsByPattern(allocator, user_a, "Launch the pilot", 100);
    defer nullalis.memory.freeProseFacts(allocator, prose_facts);
    var saw_generic_prose = false;
    for (prose_facts) |fact| {
        try std.testing.expect(!std.mem.startsWith(u8, fact.key, meeting_memory.memory_key_prefix));
        if (std.mem.eql(u8, fact.key, "generic-identical")) saw_generic_prose = true;
    }
    try std.testing.expect(saw_generic_prose);

    // Temporal decay is a tenant-wide batch operation. It must continue to
    // decay ordinary open loops while filtering the governed Minutes row.
    const temporal_source = try source(user_a, "transcript-temporal", "meeting-temporal");
    const temporal_memory = try prepared(
        temporal_source,
        .action_item,
        "Follow up with the pilot cohort",
        "grant-temporal",
    );
    const temporal_store = try mgr.storeMeetingMemory(temporal_memory);
    try mgr.upsertMemoryWithMetadata(
        user_a,
        "generic-decay-control",
        "Follow up with the generic cohort",
        .{ .custom = "open_loop" },
        null,
        "{}",
    );
    const age_decay_rows_sql = try std.fmt.allocPrint(
        allocator,
        "UPDATE {s}.memories SET created_at = NOW() - INTERVAL '90 days', " ++
            "last_accessed_at = NULL, confidence_score = 0.8 " ++
            "WHERE user_id = {d} AND key IN ('{s}', 'generic-decay-control')",
        .{ schema, user_a, temporal_store.memoryKey() },
    );
    try execPostgresSql(allocator, test_url, age_decay_rows_sql, true);
    const decay = try mgr.temporalDecay(user_a, 1, 30);
    try std.testing.expect(decay.rows_decayed >= 1);
    const verify_decay_sql = try std.fmt.allocPrint(
        allocator,
        "DO $wp15$ BEGIN " ++
            "IF (SELECT confidence_score FROM {s}.memories WHERE user_id = {d} AND key = '{s}') IS DISTINCT FROM 0.8 " ++
            "THEN RAISE EXCEPTION 'meeting memory confidence mutated'; END IF; " ++
            "IF (SELECT confidence_score FROM {s}.memories WHERE user_id = {d} AND key = 'generic-decay-control') >= 0.8 " ++
            "THEN RAISE EXCEPTION 'generic confidence did not decay'; END IF; " ++
            "END $wp15$",
        .{ schema, user_a, temporal_store.memoryKey(), schema, user_a },
    );
    try execPostgresSql(allocator, test_url, verify_decay_sql, true);

    // Exercise erasure with enough target rows and unrelated nested payloads
    // to catch an event×target recursive JSON rescan. Each extra target has
    // one nested carrier that must be deleted; 128 other-meeting payloads must
    // each be walked once and survive exact-scope matching.
    const cardinality_targets: u64 = 24;
    const unrelated_cardinality_events: u64 = 128;
    for (0..cardinality_targets) |index| {
        const item_id = try std.fmt.allocPrint(allocator, "transcript-cardinality-{d}", .{index});
        const candidate_text = try std.fmt.allocPrint(
            allocator,
            "Meeting decision {d} keeps exact erasure bounded",
            .{index},
        );
        const grant_id = try std.fmt.allocPrint(allocator, "grant-cardinality-{d}", .{index});
        const extra_source = try source(user_a, item_id, "meeting-a");
        const extra = try mgr.storeMeetingMemory(try prepared(
            extra_source,
            .decision,
            candidate_text,
            grant_id,
        ));
        const carrier_sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO {s}.memory_events (id, user_id, memory_id, event_type, payload) " ++
                "VALUES ('wp15-cardinality-meeting-{d}', {d}, NULL, 'legacy', " ++
                "jsonb_build_object('nested', jsonb_build_array(jsonb_build_object('value', '{s}'))))",
            .{ schema, index, user_a, extra.memoryKey() },
        );
        try execPostgresSql(allocator, test_url, carrier_sql, true);
    }
    const unrelated_cardinality_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO {s}.memory_events (id, user_id, memory_id, event_type, payload) " ++
            "SELECT 'wp15-cardinality-unrelated-' || g::text, {d}, NULL, 'legacy', " ++
            "jsonb_build_object('nested', jsonb_build_array(jsonb_build_object('value', '{s}'))) " ++
            "FROM generate_series(1, {d}) AS g",
        .{ schema, user_a, second_meeting.memoryKey(), unrelated_cardinality_events },
    );
    try execPostgresSql(allocator, test_url, unrelated_cardinality_sql, true);

    // Seed legacy/adversarial carriers directly. Canonical graph and working-
    // memory writers now reject these attachments, but exact erasure must also
    // clean residue created before that boundary existed. An unrelated edge
    // and event prove the payload-key deletion remains source scoped. Legacy
    // graph/timeline traversal arrays are carriers too: matching arrays must
    // be scrubbed while an unrelated traversal array survives.
    const residue_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO {s}.memory_edges (user_id, source_key, target_key, predicate, confidence, valid_from) VALUES " ++
            "({d}, '{s}', 'generic-identical', 'MENTIONS', 1.0, 1784200000), " ++
            "({d}, 'generic-unrelated', 'generic-identical', 'RELATED_TO', 1.0, 1784200000); " ++
            "INSERT INTO {s}.memory_events (id, user_id, memory_id, event_type, payload) VALUES " ++
            "('wp15-meeting-edge-event', {d}, NULL, 'edge_added', jsonb_build_object('source_key', '{s}', 'target_key', 'generic-identical')), " ++
            "('wp15-unrelated-edge-event', {d}, NULL, 'edge_added', jsonb_build_object('source_key', 'generic-unrelated', 'target_key', 'generic-identical')), " ++
            "('wp15-meeting-graph-event', {d}, NULL, 'traversal', jsonb_build_object('node_keys', jsonb_build_array('{s}', 'generic-identical'))), " ++
            "('wp15-meeting-timeline-event', {d}, NULL, 'traversal', jsonb_build_object('entry_keys', jsonb_build_array('generic-unrelated', '{s}'))), " ++
            "('wp15-meeting-nested-value-event', {d}, NULL, 'legacy', jsonb_build_object('nested', jsonb_build_array(jsonb_build_object('value', '{s}')))), " ++
            "('wp15-meeting-nested-property-event', {d}, NULL, 'legacy', jsonb_build_object('nested', jsonb_build_object('{s}', true))), " ++
            "('wp15-unrelated-nested-event', {d}, NULL, 'legacy', jsonb_build_object('nested', jsonb_build_array(jsonb_build_object('value', '{s}')))), " ++
            "('wp15-unrelated-traversal-event', {d}, NULL, 'traversal', jsonb_build_object('node_keys', jsonb_build_array('generic-unrelated', 'generic-identical'))); " ++
            "INSERT INTO {s}.working_memory (user_id, session_id, slot_id, slot_type, content, source_key, importance, pinned) " ++
            "VALUES ({d}, 'legacy-session', 1, 'decision', 'legacy meeting residue', '{s}', 1.0, false)",
        .{
            schema,
            user_a,
            first.memoryKey(),
            user_a,
            schema,
            user_a,
            first.memoryKey(),
            user_a,
            user_a,
            first.memoryKey(),
            user_a,
            first.memoryKey(),
            user_a,
            first.memoryKey(),
            user_a,
            first.memoryKey(),
            user_a,
            second_meeting.memoryKey(),
            user_a,
            schema,
            user_a,
            first.memoryKey(),
        },
    );
    try execPostgresSql(allocator, test_url, residue_sql, true);

    // Legacy rows can hide meeting provenance in an edge episode array or in
    // a payload-only memory ID even when both graph endpoints are generic.
    // Exact erasure must remove both carriers without touching their controls.
    const hidden_carriers_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO {s}.memory_edges " ++
            "(user_id, source_key, target_key, predicate, confidence, valid_from, fact, episodes) " ++
            "VALUES ({d}, 'generic-unrelated', 'generic-identical', 'EPISODE_CARRIER', " ++
            "1.0, 1784200000, 'Sensitive meeting fact', ARRAY['{s}']); " ++
            "INSERT INTO {s}.memory_events (id, user_id, memory_id, event_type, payload) " ++
            "SELECT 'wp15-meeting-memory-id-event', {d}, NULL, 'legacy', " ++
            "jsonb_build_object('nested', jsonb_build_array(jsonb_build_object('memory_id', m.id))) " ++
            "FROM {s}.memories AS m WHERE m.user_id = {d} AND m.key = '{s}'",
        .{
            schema,
            user_a,
            first.memoryKey(),
            schema,
            user_a,
            schema,
            user_a,
            first.memoryKey(),
        },
    );
    try execPostgresSql(allocator, test_url, hidden_carriers_sql, true);

    // These EXPLAIN probes force index consideration and prove the complete-
    // history erasure predicates have usable tenant/key/episode access paths.
    const event_explain_sql = try std.fmt.allocPrint(
        allocator,
        "SET enable_seqscan = off; EXPLAIN (COSTS OFF) " ++
            "WITH targets AS MATERIALIZED (SELECT m.id, m.key FROM {s}.memories AS m " ++
            "JOIN {s}.memory_source_links AS l ON l.user_id = m.user_id AND l.memory_key = m.key " ++
            "WHERE l.user_id = {d} AND l.source_spoke = 'minutes' " ++
            "AND l.meeting_scope_digest = '{s}') " ++
            "DELETE FROM {s}.memory_events AS e WHERE e.user_id = {d} AND (" ++
            "e.memory_id IN (SELECT id FROM targets) OR EXISTS (" ++
            "SELECT 1 FROM jsonb_path_query(e.payload, '$.**') AS carrier(value) " ++
            "JOIN targets AS t ON (jsonb_typeof(carrier.value) = 'string' AND " ++
            "(carrier.value = to_jsonb(t.key) OR carrier.value = to_jsonb(t.id))) OR " ++
            "(jsonb_typeof(carrier.value) = 'object' AND " ++
            "(carrier.value ? t.key OR carrier.value ? t.id))))",
        .{ schema, schema, user_a, meeting_a_scope, schema, user_a },
    );
    const event_plan = try queryPostgresText(allocator, test_url, event_explain_sql);
    try std.testing.expect(std.mem.indexOf(u8, event_plan, "idx_memory_events_user_memory_all") != null);
    try std.testing.expect(std.mem.indexOf(u8, event_plan, "Seq Scan on memory_events") == null);

    const edge_explain_sql = try std.fmt.allocPrint(
        allocator,
        "SET enable_seqscan = off; EXPLAIN (COSTS OFF) " ++
            "WITH targets AS MATERIALIZED (SELECT l.memory_key AS key " ++
            "FROM {s}.memory_source_links AS l WHERE l.user_id = {d} " ++
            "AND l.source_spoke = 'minutes' AND l.meeting_scope_digest = '{s}'), " ++
            "doomed AS MATERIALIZED (" ++
            "SELECT e.id FROM targets AS t JOIN {s}.memory_edges AS e " ++
            "ON e.user_id = {d} AND e.source_key = t.key UNION " ++
            "SELECT e.id FROM targets AS t JOIN {s}.memory_edges AS e " ++
            "ON e.user_id = {d} AND e.target_key = t.key UNION " ++
            "SELECT e.id FROM targets AS t JOIN {s}.memory_edges AS e " ++
            "ON e.user_id = {d} AND e.episodes @> ARRAY[t.key]) " ++
            "DELETE FROM {s}.memory_edges AS e USING doomed AS d WHERE e.id = d.id",
        .{
            schema,
            user_a,
            meeting_a_scope,
            schema,
            user_a,
            schema,
            user_a,
            schema,
            user_a,
            schema,
        },
    );
    const edge_plan = try queryPostgresText(allocator, test_url, edge_explain_sql);
    try std.testing.expect(std.mem.indexOf(u8, edge_plan, "idx_memory_edges_source_all") != null);
    try std.testing.expect(std.mem.indexOf(u8, edge_plan, "idx_memory_edges_target_all") != null);
    try std.testing.expect(std.mem.indexOf(u8, edge_plan, "Seq Scan on memory_edges") == null);

    const episode_explain_sql = try std.fmt.allocPrint(
        allocator,
        "SET enable_seqscan = off; EXPLAIN (COSTS OFF) " ++
            "SELECT id FROM {s}.memory_edges WHERE episodes @> ARRAY['{s}']",
        .{ schema, first.memoryKey() },
    );
    const episode_plan = try queryPostgresText(allocator, test_url, episode_explain_sql);
    try std.testing.expect(std.mem.indexOf(u8, episode_plan, "idx_memory_edges_episodes_all") != null);

    // A nonexistent meeting must not issue carrier DELETE statements at all.
    // Statement triggers turn an accidental empty-target scan into a loud test
    // failure, independent of planner cost estimates or fixture cardinality.
    const empty_scope_guard_sql = try std.fmt.allocPrint(
        allocator,
        "CREATE FUNCTION {s}.wp15_reject_empty_scope_carrier_delete() RETURNS trigger " ++
            "LANGUAGE plpgsql AS $wp15$ BEGIN RAISE EXCEPTION 'empty-scope carrier delete'; END $wp15$; " ++
            "CREATE TRIGGER wp15_no_empty_event_delete BEFORE DELETE ON {s}.memory_events " ++
            "FOR EACH STATEMENT EXECUTE FUNCTION {s}.wp15_reject_empty_scope_carrier_delete(); " ++
            "CREATE TRIGGER wp15_no_empty_edge_delete BEFORE DELETE ON {s}.memory_edges " ++
            "FOR EACH STATEMENT EXECUTE FUNCTION {s}.wp15_reject_empty_scope_carrier_delete()",
        .{ schema, schema, schema, schema, schema },
    );
    try execPostgresSql(allocator, test_url, empty_scope_guard_sql, true);
    const empty_request = try meeting_memory.ErasureRequest.init(
        &test_pseudonymizer,
        user_a,
        "meeting-never-created",
        "request-empty-scope",
    );
    const empty_erased = try mgr.eraseMeetingMemories(empty_request);
    try std.testing.expectEqual(meeting_memory.ErasureDisposition.already_absent, empty_erased.manifest.disposition);
    try std.testing.expectEqual(@as(u64, 0), empty_erased.manifest.counts.memory_events_deleted);
    try std.testing.expectEqual(@as(u64, 0), empty_erased.manifest.counts.memory_edges_deleted);
    const empty_scope_guard_cleanup_sql = try std.fmt.allocPrint(
        allocator,
        "DROP TRIGGER wp15_no_empty_event_delete ON {s}.memory_events; " ++
            "DROP TRIGGER wp15_no_empty_edge_delete ON {s}.memory_edges; " ++
            "DROP FUNCTION {s}.wp15_reject_empty_scope_carrier_delete()",
        .{ schema, schema, schema },
    );
    try execPostgresSql(allocator, test_url, empty_scope_guard_cleanup_sql, true);

    const erase_request = try meeting_memory.ErasureRequest.init(&test_pseudonymizer, user_a, "meeting-a", "request-a");
    const erased = try mgr.eraseMeetingMemories(erase_request);
    try std.testing.expectEqual(1 + cardinality_targets, erased.manifest.counts.memory_source_links_deleted);
    try std.testing.expectEqual(1 + cardinality_targets, erased.manifest.counts.memories_deleted);
    try std.testing.expectEqual(6 + cardinality_targets, erased.manifest.counts.memory_events_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_embeddings_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_vectors_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_entities_deleted);
    try std.testing.expectEqual(@as(u64, 2), erased.manifest.counts.memory_edges_deleted);
    try std.testing.expectEqual(@as(u64, 1), erased.manifest.counts.working_memory_deleted);

    const retry_request = try meeting_memory.ErasureRequest.init(&test_pseudonymizer, user_a, "meeting-a", "request-a-retry");
    const erased_replay = try mgr.eraseMeetingMemories(retry_request);
    try std.testing.expect(erased_replay.replayed);
    try std.testing.expectEqual(erased.manifest.counts.memories_deleted, erased_replay.manifest.counts.memories_deleted);
    try std.testing.expectEqualStrings(erased.receiptKeyId(), erased_replay.receiptKeyId());
    try std.testing.expectEqualStrings(erased.receiptSignature(), erased_replay.receiptSignature());

    const gone = try mgr.getMemory(allocator, user_a, first.memoryKey());
    if (gone) |entry| entry.deinit(allocator);
    try std.testing.expect(gone == null);

    const generic = try mgr.getMemory(allocator, user_a, "generic-identical");
    if (generic) |entry| entry.deinit(allocator);
    try std.testing.expect(generic != null);

    const meeting_b_still_there = try mgr.getMemory(allocator, user_a, second_meeting.memoryKey());
    if (meeting_b_still_there) |entry| entry.deinit(allocator);
    try std.testing.expect(meeting_b_still_there != null);

    const tenant_b_still_there = try mgr.getMemory(allocator, user_b, second_tenant.memoryKey());
    if (tenant_b_still_there) |entry| entry.deinit(allocator);
    try std.testing.expect(tenant_b_still_there != null);

    try std.testing.expectError(
        error.MeetingMemoryErased,
        mgr.storeMeetingMemory(memory_a),
    );

    const meeting_events = try mgr.listEventsForMemoryKey(allocator, user_a, first.memoryKey(), 10);
    defer freeEvents(allocator, meeting_events);
    try std.testing.expectEqual(@as(usize, 0), meeting_events.len);
    const unrelated_events = try mgr.listEventsForMemoryKey(allocator, user_a, "generic-unrelated", 10);
    defer freeEvents(allocator, unrelated_events);
    var saw_unrelated_edge_event = false;
    for (unrelated_events) |event| {
        if (std.mem.eql(u8, event.id, "wp15-unrelated-edge-event")) {
            saw_unrelated_edge_event = true;
        }
    }
    try std.testing.expect(saw_unrelated_edge_event);
    const traversal_residue_sql = try std.fmt.allocPrint(
        allocator,
        "DO $wp15$ BEGIN " ++
            "IF EXISTS (SELECT 1 FROM {s}.memory_events WHERE user_id = {d} " ++
            "AND id IN ('wp15-meeting-graph-event', 'wp15-meeting-timeline-event', " ++
            "'wp15-meeting-nested-value-event', 'wp15-meeting-nested-property-event', " ++
            "'wp15-meeting-memory-id-event')) " ++
            "THEN RAISE EXCEPTION 'meeting traversal carrier survived'; END IF; " ++
            "IF NOT EXISTS (SELECT 1 FROM {s}.memory_events WHERE user_id = {d} " ++
            "AND id IN ('wp15-unrelated-traversal-event', 'wp15-unrelated-nested-event') " ++
            "GROUP BY user_id HAVING COUNT(*) = 2) " ++
            "THEN RAISE EXCEPTION 'unrelated nested/traversal event was over-deleted'; END IF; " ++
            "IF (SELECT count(*) FROM {s}.memory_events WHERE user_id = {d} " ++
            "AND id LIKE 'wp15-cardinality-unrelated-%') <> {d} " ++
            "THEN RAISE EXCEPTION 'unrelated cardinality controls were over-deleted'; END IF; " ++
            "END $wp15$",
        .{ schema, user_a, schema, user_a, schema, user_a, unrelated_cardinality_events },
    );
    try execPostgresSql(allocator, test_url, traversal_residue_sql, true);
    const remaining_edges = try mgr.listEdgesForUser(allocator, user_a);
    defer {
        for (remaining_edges) |*edge| edge.deinit(allocator);
        allocator.free(remaining_edges);
    }
    var saw_unrelated_edge = false;
    for (remaining_edges) |edge| {
        try std.testing.expect(!std.mem.eql(u8, edge.source_key, first.memoryKey()));
        try std.testing.expect(!std.mem.eql(u8, edge.target_key, first.memoryKey()));
        if (std.mem.eql(u8, edge.source_key, "generic-unrelated")) saw_unrelated_edge = true;
    }
    try std.testing.expect(saw_unrelated_edge);

    // Receipt retention may remove the detailed audit row, but never the
    // minimal meeting tombstone. Cleanup cannot reopen the write gate.
    const receipt_cleanup_sql = try std.fmt.allocPrint(
        allocator,
        "DELETE FROM {s}.meeting_memory_erasure_receipts WHERE user_scope_digest = '{s}'",
        .{
            schema,
            meeting_memory.formatSha256(try meeting_memory.userScopeDigest(&test_pseudonymizer, user_a)),
        },
    );
    try execPostgresSql(allocator, test_url, receipt_cleanup_sql, true);
    try std.testing.expectError(error.MeetingMemoryErased, mgr.storeMeetingMemory(memory_a));
    const after_retention_request = try meeting_memory.ErasureRequest.init(&test_pseudonymizer, user_a, "meeting-a", "request-after-retention");
    const after_retention = try mgr.eraseMeetingMemories(after_retention_request);
    try std.testing.expect(after_retention.replayed);
    try std.testing.expectEqual(meeting_memory.ErasureDisposition.already_absent, after_retention.manifest.disposition);
    try std.testing.expectEqual(@as(u64, 0), after_retention.manifest.counts.memories_deleted);

    // The content-free meeting tombstone intentionally survives the tenant
    // cascade. Replaying erasure after account deletion returns a signed
    // already-absent proof; reprovisioning the same numeric tenant cannot
    // resurrect this erased meeting.
    try mgr.deleteUser(user_a);
    const after_account_request = try meeting_memory.ErasureRequest.init(&test_pseudonymizer, user_a, "meeting-a", "request-after-account");
    const after_account = try mgr.eraseMeetingMemories(after_account_request);
    try std.testing.expect(after_account.replayed);
    try mgr.provisionUser(user_a, "/tmp/nullalis-minutes-a-reprovisioned");
    try std.testing.expectError(error.MeetingMemoryAccountErased, mgr.storeMeetingMemory(memory_a));
    try std.testing.expectError(error.MeetingMemoryAccountErased, mgr.storeMeetingMemory(memory_b));
}

test "WP-15 live: receipt replay verifies immutable compliance evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);

    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "meeting_receipt_integrity");
    var mgr = try harness.newManager(allocator, test_url, schema);
    defer harness.dropAndDeinit(&mgr, "meeting_receipt_integrity");
    mgr.skipExternalIdentityForTests();
    try installMeetingMemoryCrypto(&mgr);

    const user_id = harness.testUid();
    try mgr.provisionUser(user_id, "/tmp/nullalis-minutes-receipt-integrity");
    const source_tuple = try source(user_id, "transcript-a", "meeting-a");
    const memory = try prepared(source_tuple, .decision, "Use a staged rollout", "grant-a");
    _ = try mgr.storeMeetingMemory(memory);
    const request = try meeting_memory.ErasureRequest.init(&test_pseudonymizer, user_id, "meeting-a", "request-a");
    const erased = try mgr.eraseMeetingMemories(request);
    try std.testing.expect(erased.manifest.erased_at_unix_us > 0);
    try std.testing.expect(std.mem.startsWith(u8, erased.receiptKeyId(), "sha256="));
    try std.testing.expect(std.mem.startsWith(u8, erased.receiptSignature(), "ed25519="));

    // The secondary public key keeps old receipts verifiable after the signer
    // flips. A later rotation that would retire a still-retained key is
    // rejected before the runtime swaps keys.
    const original_signer = try meeting_memory.ErasureReceiptSigner.init(
        test_receipt_signing_seed,
    );
    const rotated_seed = [_]u8{0x32} ** 32;
    const rotated_signer = try meeting_memory.ErasureReceiptSigner.init(rotated_seed);
    try mgr.installMeetingMemoryCryptoForTests(
        test_pseudonym_key,
        rotated_seed,
        original_signer.publicKeyBytes(),
    );
    const rotated_replay = try mgr.eraseMeetingMemories(request);
    try std.testing.expect(rotated_replay.replayed);
    try std.testing.expectEqualStrings(erased.receiptKeyId(), rotated_replay.receiptKeyId());
    try std.testing.expectEqualStrings(erased.receiptSignature(), rotated_replay.receiptSignature());
    try std.testing.expectError(
        error.MeetingMemoryReceiptVerificationKeyMissing,
        mgr.installMeetingMemoryCryptoForTests(
            test_pseudonym_key,
            [_]u8{0x33} ** 32,
            rotated_signer.publicKeyBytes(),
        ),
    );

    const user_scope_digest = meeting_memory.formatSha256(
        try meeting_memory.userScopeDigest(&test_pseudonymizer, user_id),
    );
    const meeting_scope_digest = meeting_memory.formatSha256(request.meeting_digest);

    // Runtime SQL cannot mutate the pseudonym-key binding, permanent
    // tombstones, or retained receipt evidence. Receipt DELETE remains
    // intentionally available to the separate retention role and is covered
    // by the source-scoped erasure test above.
    const guarded_tamper_sql = try std.fmt.allocPrint(
        allocator,
        "UPDATE {s}.meeting_memory_erasure_receipts SET memories_deleted = 99 " ++
            "WHERE user_scope_digest = '{s}'",
        .{ schema, user_scope_digest },
    );
    const immutable_mutations = [_][]const u8{
        try std.fmt.allocPrint(
            allocator,
            "UPDATE {s}.meeting_memory_crypto_state SET pseudonym_key_id = pseudonym_key_id",
            .{schema},
        ),
        try std.fmt.allocPrint(
            allocator,
            "DELETE FROM {s}.meeting_memory_crypto_state",
            .{schema},
        ),
        try std.fmt.allocPrint(
            allocator,
            "TRUNCATE TABLE {s}.meeting_memory_crypto_state",
            .{schema},
        ),
        try std.fmt.allocPrint(
            allocator,
            "UPDATE {s}.meeting_memory_erasure_tombstones SET erased_at = erased_at " ++
                "WHERE meeting_scope_digest = '{s}'",
            .{ schema, meeting_scope_digest },
        ),
        try std.fmt.allocPrint(
            allocator,
            "DELETE FROM {s}.meeting_memory_erasure_tombstones " ++
                "WHERE meeting_scope_digest = '{s}'",
            .{ schema, meeting_scope_digest },
        ),
        try std.fmt.allocPrint(
            allocator,
            "TRUNCATE TABLE {s}.meeting_memory_erasure_tombstones",
            .{schema},
        ),
        try std.fmt.allocPrint(
            allocator,
            "UPDATE {s}.meeting_memory_account_erasure_tombstones SET erased_at = erased_at",
            .{schema},
        ),
        try std.fmt.allocPrint(
            allocator,
            "DELETE FROM {s}.meeting_memory_account_erasure_tombstones",
            .{schema},
        ),
        try std.fmt.allocPrint(
            allocator,
            "TRUNCATE TABLE {s}.meeting_memory_account_erasure_tombstones",
            .{schema},
        ),
        guarded_tamper_sql,
        try std.fmt.allocPrint(
            allocator,
            "TRUNCATE TABLE {s}.meeting_memory_erasure_receipts",
            .{schema},
        ),
    };
    for (immutable_mutations) |sql| {
        try execPostgresSql(allocator, test_url, sql, false);
    }

    // Simulate out-of-band corruption by the schema owner, then prove the
    // application recomputes the signed envelope and fails complete-or-loud.
    const disable_trigger_sql = try std.fmt.allocPrint(
        allocator,
        "ALTER TABLE {s}.meeting_memory_erasure_receipts " ++
            "DISABLE TRIGGER meeting_memory_erasure_receipts_no_update",
        .{schema},
    );
    try execPostgresSql(allocator, test_url, disable_trigger_sql, true);
    try execPostgresSql(allocator, test_url, guarded_tamper_sql, true);
    const enable_trigger_sql = try std.fmt.allocPrint(
        allocator,
        "ALTER TABLE {s}.meeting_memory_erasure_receipts " ++
            "ENABLE TRIGGER meeting_memory_erasure_receipts_no_update",
        .{schema},
    );
    try execPostgresSql(allocator, test_url, enable_trigger_sql, true);
    try std.testing.expectError(
        error.MeetingMemoryReceiptIntegrity,
        mgr.eraseMeetingMemories(request),
    );

    // Restore the count but move the database erasure timestamp. Timestamp is
    // part of the canonical manifest/digest because it controls retention.
    try execPostgresSql(allocator, test_url, disable_trigger_sql, true);
    const timestamp_tamper_sql = try std.fmt.allocPrint(
        allocator,
        "UPDATE {s}.meeting_memory_erasure_receipts " ++
            "SET memories_deleted = {d}, erased_at = erased_at - INTERVAL '1 microsecond' " ++
            "WHERE user_scope_digest = '{s}'",
        .{ schema, erased.manifest.counts.memories_deleted, user_scope_digest },
    );
    try execPostgresSql(allocator, test_url, timestamp_tamper_sql, true);
    try execPostgresSql(allocator, test_url, enable_trigger_sql, true);
    try std.testing.expectError(
        error.MeetingMemoryReceiptIntegrity,
        mgr.eraseMeetingMemories(request),
    );

    // A canonical-looking forged signature and a canonical-looking unknown
    // key ID must also fail. Syntax checks alone are not receipt verification.
    try execPostgresSql(allocator, test_url, disable_trigger_sql, true);
    const signature_tamper_sql = try std.fmt.allocPrint(
        allocator,
        "UPDATE {s}.meeting_memory_erasure_receipts " ++
            "SET memories_deleted = {d}, " ++
            "erased_at = to_timestamp({d}::numeric / 1000000), " ++
            "receipt_signature = 'ed25519={s}' " ++
            "WHERE user_scope_digest = '{s}'",
        .{
            schema,
            erased.manifest.counts.memories_deleted,
            erased.manifest.erased_at_unix_us,
            [_]u8{'0'} ** 128,
            user_scope_digest,
        },
    );
    try execPostgresSql(allocator, test_url, signature_tamper_sql, true);
    try execPostgresSql(allocator, test_url, enable_trigger_sql, true);
    try std.testing.expectError(
        error.MeetingMemoryReceiptIntegrity,
        mgr.eraseMeetingMemories(request),
    );

    try execPostgresSql(allocator, test_url, disable_trigger_sql, true);
    const key_id_tamper_sql = try std.fmt.allocPrint(
        allocator,
        "UPDATE {s}.meeting_memory_erasure_receipts " ++
            "SET receipt_key_id = 'sha256={s}', receipt_signature = '{s}' " ++
            "WHERE user_scope_digest = '{s}'",
        .{
            schema,
            [_]u8{'0'} ** 64,
            erased.receiptSignature(),
            user_scope_digest,
        },
    );
    try execPostgresSql(allocator, test_url, key_id_tamper_sql, true);
    try execPostgresSql(allocator, test_url, enable_trigger_sql, true);
    try std.testing.expectError(
        error.MeetingMemoryReceiptIntegrity,
        mgr.eraseMeetingMemories(request),
    );
}
