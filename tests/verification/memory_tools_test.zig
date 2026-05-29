//! S6.10 — memory tools contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const pii_detect = nullalis.memory.pii_detect;
const harness = @import("harness.zig");

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

test "S6.10 memory: tool surface (store/recall/forget/doctor/purge_pii) is mentioned in the UI contract" {
    const allocator = std.testing.allocator;
    const ui_handoff = try harness.loadProjectFile(allocator, "docs/ui-handoff.md");
    defer allocator.free(ui_handoff);

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
