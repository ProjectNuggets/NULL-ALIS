//! Transcript hygiene and provenance — clean exports with source attribution.
//!
//! ProvenanceTag attaches metadata to history entries (source channel,
//! timestamp, turn index) without changing the entry format.
//!
//! Hygiene functions strip internal markers before export:
//!   - [Memory context] prefixes injected by memory enrichment
//!   - [Queue notice] markers from queue overflow handling
//!   - Tool-internal output prefixes

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// ProvenanceTag
// ═══════════════════════════════════════════════════════════════════════════

/// Lightweight metadata that can be attached to a history entry.
/// All fields are optional — entries without provenance still work normally.
pub const ProvenanceTag = struct {
    source_channel: ?[]const u8 = null, // e.g. "telegram", "api", "cli"
    timestamp_ms: i64 = 0, // milliseconds since epoch
    turn_index: u32 = 0, // 0-based turn number in session
    tool_name: ?[]const u8 = null, // set for tool result entries
    is_synthetic: bool = false, // true for system-generated entries (compaction summaries, queue notices)

    /// Returns true when this tag carries no meaningful information.
    pub fn isEmpty(self: ProvenanceTag) bool {
        return self.source_channel == null and
            self.timestamp_ms == 0 and
            self.turn_index == 0 and
            self.tool_name == null and
            !self.is_synthetic;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Internal marker constants
// ═══════════════════════════════════════════════════════════════════════════

const MEMORY_CONTEXT_PREFIX = "[Memory context]\n";
const QUEUE_NOTICE_PREFIX = "[Queue notice:";
const QUEUE_DROP_MARKERS = [_][]const u8{
    "Queue policy dropped this queued turn.",
    "Queue overflow: dropped newest queued turn.",
    "Queue overflow: dropped and coalesced queued turns.",
    "Queue mode latest: this older queued turn was superseded",
    "Queue overflow: this older queued turn was dropped.",
};

// ═══════════════════════════════════════════════════════════════════════════
// Hygiene functions
// ═══════════════════════════════════════════════════════════════════════════

/// Remove internal prefixes/markers from content, returning a slice into the
/// original string (no allocation). Order of stripping:
///   1. [Memory context] prefix (strips everything up to and including "\n\n")
///   2. [Queue notice:...] prefix line (strips up to and including first '\n')
pub fn stripInternalMarkers(content: []const u8) []const u8 {
    var result = content;

    // Strip [Memory context] prefix (includes everything up to double newline)
    if (std.mem.startsWith(u8, result, MEMORY_CONTEXT_PREFIX)) {
        if (std.mem.indexOf(u8, result, "\n\n")) |sep_idx| {
            result = result[sep_idx + 2 ..];
        }
    }

    // Strip [Queue notice:...] prefix line
    if (std.mem.startsWith(u8, result, QUEUE_NOTICE_PREFIX)) {
        if (std.mem.indexOfScalar(u8, result, '\n')) |nl_idx| {
            result = result[nl_idx + 1 ..];
        }
    }

    return result;
}

/// Returns true when the entire message is a queue/system artifact that
/// should be omitted entirely from exported transcripts.
pub fn isInternalMessage(content: []const u8) bool {
    for (&QUEUE_DROP_MARKERS) |marker| {
        if (std.mem.startsWith(u8, content, marker)) return true;
    }
    return false;
}

/// Full sanitization pipeline: detect internal-only messages (return ""),
/// then strip [Memory context] and [Queue notice] prefixes.
pub fn sanitizeForExport(content: []const u8) []const u8 {
    if (isInternalMessage(content)) return "";
    return stripInternalMarkers(content);
}

// ═══════════════════════════════════════════════════════════════════════════
// Export formatting
// ═══════════════════════════════════════════════════════════════════════════

/// Format a single history entry as clean markdown for export.
///
/// If the content consists entirely of internal markers the entry is skipped
/// (nothing is written to writer). Optional provenance is rendered as an HTML
/// comment that is invisible in rendered markdown.
pub fn formatExportEntry(
    writer: anytype,
    role: []const u8,
    content: []const u8,
    provenance: ?ProvenanceTag,
) !void {
    const clean_content = sanitizeForExport(content);
    if (clean_content.len == 0) return; // skip internal-only messages

    try writer.print("## {s}\n\n", .{role});

    // Provenance annotation as HTML comment (invisible in rendered markdown)
    if (provenance) |prov| {
        if (!prov.isEmpty()) {
            try writer.writeAll("<!-- provenance:");
            if (prov.source_channel) |ch| {
                try writer.print(" channel={s}", .{ch});
            }
            if (prov.timestamp_ms != 0) {
                try writer.print(" ts={d}", .{prov.timestamp_ms});
            }
            if (prov.turn_index != 0) {
                try writer.print(" turn={d}", .{prov.turn_index});
            }
            if (prov.tool_name) |tool| {
                try writer.print(" tool={s}", .{tool});
            }
            if (prov.is_synthetic) {
                try writer.writeAll(" synthetic=true");
            }
            try writer.writeAll(" -->\n");
        }
    }

    try writer.print("{s}\n\n", .{clean_content});
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "stripInternalMarkers removes [Memory context] prefix" {
    const input = "[Memory context]\nsome memory data\n\nActual user content here";
    const result = stripInternalMarkers(input);
    try std.testing.expectEqualStrings("Actual user content here", result);
}

test "stripInternalMarkers passes through content without markers" {
    const input = "Normal user message with no markers.";
    const result = stripInternalMarkers(input);
    try std.testing.expectEqualStrings(input, result);
}

test "stripInternalMarkers removes [Queue notice:...] prefix line" {
    const input = "[Queue notice: 2 queued turn(s) were dropped due to overflow. Prioritize the latest request.]\nActual content after queue notice";
    const result = stripInternalMarkers(input);
    try std.testing.expectEqualStrings("Actual content after queue notice", result);
}

test "isInternalMessage returns true for DEFAULT_QUEUE_DROP_MESSAGE" {
    try std.testing.expect(isInternalMessage("Queue policy dropped this queued turn."));
}

test "isInternalMessage returns true for QUEUE_NEWEST_DROP_MESSAGE" {
    try std.testing.expect(isInternalMessage("Queue overflow: dropped newest queued turn."));
}

test "isInternalMessage returns true for QUEUE_SUMMARIZE_DROP_MESSAGE" {
    try std.testing.expect(isInternalMessage("Queue overflow: dropped and coalesced queued turns."));
}

test "isInternalMessage returns true for QUEUE_LATEST_SUPERSEDED_MESSAGE" {
    try std.testing.expect(isInternalMessage("Queue mode latest: this older queued turn was superseded"));
}

test "isInternalMessage returns true for QUEUE_OLDEST_DROPPED_MESSAGE" {
    try std.testing.expect(isInternalMessage("Queue overflow: this older queued turn was dropped."));
}

test "isInternalMessage returns false for normal user message" {
    try std.testing.expect(!isInternalMessage("Hello, can you help me with something?"));
}

test "sanitizeForExport returns empty string for internal-only messages" {
    const result = sanitizeForExport("Queue policy dropped this queued turn.");
    try std.testing.expectEqualStrings("", result);
}

test "sanitizeForExport strips markers and returns clean content for enriched messages" {
    const input = "[Memory context]\nsome memory data\n\nUser's actual question";
    const result = sanitizeForExport(input);
    try std.testing.expectEqualStrings("User's actual question", result);
}

test "ProvenanceTag.isEmpty returns true for default-initialized tag" {
    const tag = ProvenanceTag{};
    try std.testing.expect(tag.isEmpty());
}

test "ProvenanceTag.isEmpty returns false when source_channel is set" {
    const tag = ProvenanceTag{ .source_channel = "telegram" };
    try std.testing.expect(!tag.isEmpty());
}

test "formatExportEntry writes provenance comment when tag provided" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const prov = ProvenanceTag{
        .source_channel = "telegram",
        .timestamp_ms = 1700000000000,
        .turn_index = 3,
    };
    try formatExportEntry(buf.writer(std.testing.allocator), "user", "Hello world", prov);
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "<!-- provenance:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "channel=telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "turn=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello world") != null);
}

test "formatExportEntry skips internal-only messages (writes nothing)" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try formatExportEntry(buf.writer(std.testing.allocator), "user", "Queue policy dropped this queued turn.", null);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "formatExportEntry writes clean content without markers" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const enriched = "[Memory context]\nsome memories here\n\nClean user message";
    try formatExportEntry(buf.writer(std.testing.allocator), "user", enriched, null);
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "[Memory context]") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Clean user message") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "## user") != null);
}
