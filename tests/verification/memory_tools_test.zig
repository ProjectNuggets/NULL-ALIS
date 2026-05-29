//! S6.10 — memory tools contract pin.
//!
//! Two layers:
//!   STATIC unit pins on `pii_detect.detect` for V1 scope (phone+email
//!   only) + the UI-handoff doc.
//!
//!   LIVE PG pin on `memory_purge_pii` against tagged fixture rows —
//!   provision user, upsert memories with `pii_tags` metadata, run dry
//!   then wet purge via `listPiiMemoryKeys` / `deletePiiMemoriesByCategory`,
//!   verify only the targeted category was deleted.

const std = @import("std");
const nullalis = @import("nullalis");
const pii_detect = nullalis.memory.pii_detect;
const harness = @import("harness.zig");

// ── STATIC: pii_detect contract ──────────────────────────────────────

test "S6.10 memory: PII detector fires on a canonical US phone number" {
    const flags = pii_detect.detect("Call me at 555-867-5309 tomorrow.");
    try std.testing.expect(flags.phone);
}

test "S6.10 memory: PII detector fires on an international phone number" {
    const flags = pii_detect.detect("Reach me at +1-415-555-0123");
    try std.testing.expect(flags.phone);
}

test "S6.10 memory: PII detector fires on a canonical email address" {
    const flags = pii_detect.detect("Ping me at alice@example.com please");
    try std.testing.expect(flags.email);
}

test "S6.10 memory: PII detector does NOT fire on a US street address (V1 scope)" {
    const flags = pii_detect.detect("I live at 123 Main Street, Springfield IL.");
    try std.testing.expect(!flags.phone);
    try std.testing.expect(!flags.email);
}

test "S6.10 memory: PII detector does NOT fire on a personal name (V1 scope)" {
    const flags = pii_detect.detect("Her name is Dr. Emily Carter, MD.");
    try std.testing.expect(!flags.phone);
    try std.testing.expect(!flags.email);
}

test "S6.10 memory: PII detector does NOT fire on benign text" {
    const flags = pii_detect.detect("The cat sat on the mat.");
    try std.testing.expect(!flags.phone);
    try std.testing.expect(!flags.email);
    try std.testing.expect(!flags.any());
    try std.testing.expectEqual(@as(usize, 0), flags.count());
}

test "S6.10 memory: Flags.any() and Flags.count() roundtrip a mixed input" {
    const flags = pii_detect.detect("Email alice@example.com or call 555-867-5309");
    try std.testing.expect(flags.phone);
    try std.testing.expect(flags.email);
    try std.testing.expect(flags.any());
    try std.testing.expectEqual(@as(usize, 2), flags.count());
}

test "S6.10 memory: tool surface is mentioned in the UI contract" {
    const ui_handoff = try harness.loadProjectFile("docs/ui-handoff.md");
    const tools = [_][]const u8{
        "memory_store",
        "memory_recall",
        "memory_forget",
        "memory_doctor",
        "memory_purge_pii",
    };
    for (tools) |t| {
        if (std.mem.indexOf(u8, ui_handoff, t) == null) {
            std.debug.print("S6.10: memory tool '{s}' missing from ui-handoff.md\n", .{t});
            return error.MemoryToolNotDocumented;
        }
    }
}

// ── LIVE PG: memory_purge_pii roundtrip ──────────────────────────────

test "S6.10 memory_purge_pii live: phone-tagged row is deleted, email-tagged + untagged survive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_url = try harness.requirePostgresUrl(allocator);
    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "purge_pii");
    var mgr = try harness.newManager(allocator, test_url, schema);
    defer {
        mgr.dropSchemaForTests() catch {};
        mgr.deinit();
    }

    const uid: i64 = 1;
    try mgr.provisionUser(uid, "/tmp/nullalis-s6-purge");

    // Seed three memories: phone-tagged, email-tagged, untagged. The
    // production persist path (`memory_store.zig`) writes the `pii_tags`
    // JSON array onto `metadata` when `pii_detect.detect` fires; here we
    // construct the metadata directly so we can pin the purge surface
    // independent of the detector.
    try mgr.upsertMemoryWithMetadata(uid, "phone-row", "555-867-5309", .core, null, "{\"pii_tags\":[\"phone\"]}");
    try mgr.upsertMemoryWithMetadata(uid, "email-row", "x@y.z", .core, null, "{\"pii_tags\":[\"email\"]}");
    try mgr.upsertMemoryWithMetadata(uid, "benign-row", "the cat sat", .core, null, "{}");

    // DRY-RUN equivalent — listPiiMemoryKeys returns the candidate set
    // without mutating. We assert the candidate counts match expectations.
    const phone_candidates = try mgr.listPiiMemoryKeys(allocator, uid, "phone");
    defer {
        for (phone_candidates) |k| allocator.free(k);
        allocator.free(phone_candidates);
    }
    try std.testing.expectEqual(@as(usize, 1), phone_candidates.len);
    try std.testing.expectEqualStrings("phone-row", phone_candidates[0]);

    const email_candidates = try mgr.listPiiMemoryKeys(allocator, uid, "email");
    defer {
        for (email_candidates) |k| allocator.free(k);
        allocator.free(email_candidates);
    }
    try std.testing.expectEqual(@as(usize, 1), email_candidates.len);

    const all_candidates = try mgr.listPiiMemoryKeys(allocator, uid, "all");
    defer {
        for (all_candidates) |k| allocator.free(k);
        allocator.free(all_candidates);
    }
    try std.testing.expectEqual(@as(usize, 2), all_candidates.len);

    // WET purge of phone only.
    const deleted = try mgr.deletePiiMemoriesByCategory(allocator, uid, "phone");
    try std.testing.expectEqual(@as(usize, 1), deleted);

    // Post-condition: phone row gone, email + benign survive.
    const phone_after = try mgr.getMemory(allocator, uid, "phone-row");
    if (phone_after) |m| {
        m.deinit(allocator);
        std.debug.print("S6.10 purge live: phone-row SURVIVED wet purge\n", .{});
        return error.PiiPhonePurgeIneffective;
    }

    const email_after = try mgr.getMemory(allocator, uid, "email-row") orelse {
        std.debug.print("S6.10 purge live: email-row UNEXPECTEDLY purged (category isolation broken)\n", .{});
        return error.PiiPurgeOverreach;
    };
    email_after.deinit(allocator);

    const benign_after = try mgr.getMemory(allocator, uid, "benign-row") orelse {
        std.debug.print("S6.10 purge live: benign-row UNEXPECTEDLY purged (untagged row deleted)\n", .{});
        return error.PiiPurgeUntaggedDeletion;
    };
    benign_after.deinit(allocator);
}
