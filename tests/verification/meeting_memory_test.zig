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

const meeting_memory = nullalis.meeting_memory;

test "WP-15 schema: provenance links are one-to-one and receipts cannot retain content" {
    const migration_sql = try harness.loadProjectFile("src/migrations/0011_meeting_memory_provenance.sql");
    const required = [_][]const u8{
        "CREATE TABLE IF NOT EXISTS {schema}.memory_source_links",
        "CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_receipts",
        "FOREIGN KEY (user_id, memory_key)",
        "UNIQUE INDEX IF NOT EXISTS idx_memory_source_links_memory",
        "(user_id, memory_key)",
        "source_item_id",
        "meeting_id",
        "meeting_scope_digest",
        "source_digest",
        "candidate_digest",
        "consent_grant_digest",
        "consent_policy_version",
        "consented_at",
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
    };
    for (forbidden_receipt_columns) |needle| {
        if (std.mem.indexOf(u8, receipt_sql, needle) != null) {
            std.debug.print("WP-15 receipt contains forbidden content field: {s}\n", .{needle});
            return error.ContentBearingMeetingErasureReceipt;
        }
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
    const candidate = try meeting_memory.Candidate.init(kind, text, .approved);
    const grant = try meeting_memory.ConfirmedConsentGrant.init(source_tuple, candidate, .{
        .grant_id = grant_id,
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    return meeting_memory.PreparedMemory.init(source_tuple, candidate, grant);
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

    // A generic row with byte-identical content is deliberately unrelated.
    try mgr.upsertMemory(user_a, "generic-identical", identical_text, .core, null);

    const first = try mgr.storeMeetingMemory(memory_a);
    try std.testing.expect(first.inserted);
    const replay = try mgr.storeMeetingMemory(memory_a);
    try std.testing.expect(!replay.inserted);
    try std.testing.expectEqualStrings(first.memoryKey(), replay.memoryKey());

    const second_meeting = try mgr.storeMeetingMemory(memory_b);
    const second_tenant = try mgr.storeMeetingMemory(memory_other_tenant);
    try std.testing.expect(!std.mem.eql(u8, first.memoryKey(), second_meeting.memoryKey()));
    try std.testing.expect(!std.mem.eql(u8, first.memoryKey(), second_tenant.memoryKey()));

    const erase_request = try meeting_memory.ErasureRequest.init(user_a, "meeting-a", "request-a");
    const erased = try mgr.eraseMeetingMemories(erase_request);
    try std.testing.expectEqual(@as(u64, 1), erased.manifest.counts.memory_source_links_deleted);
    try std.testing.expectEqual(@as(u64, 1), erased.manifest.counts.memories_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_events_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_embeddings_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_vectors_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_entities_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.memory_edges_deleted);
    try std.testing.expectEqual(@as(u64, 0), erased.manifest.counts.working_memory_deleted);

    const retry_request = try meeting_memory.ErasureRequest.init(user_a, "meeting-a", "request-a-retry");
    const erased_replay = try mgr.eraseMeetingMemories(retry_request);
    try std.testing.expect(erased_replay.replayed);
    try std.testing.expectEqual(erased.manifest.counts.memories_deleted, erased_replay.manifest.counts.memories_deleted);
    try std.testing.expectEqualStrings(erased.receiptDigest(), erased_replay.receiptDigest());

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
}
