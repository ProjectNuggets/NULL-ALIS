//! V1.14.8 — Boundary extraction parsers.
//!
//! Two parsers, each robust to LLM output drift:
//!
//!   parseExtraction(allocator, raw) → ExtractionResult
//!     Strict JSON parse first. If that fails, regex-extract the first
//!     `{...}` substring (mem0 pattern) and retry once. If still fails,
//!     return empty result. Non-fatal at every step.
//!
//!   parseHydration(allocator, raw) → HydrationSummary
//!     XML tag extractor — pulls <focus>...</focus> etc. lenient: missing
//!     tags become empty strings; the persistence layer treats empties
//!     as "no signal in that slot."

const std = @import("std");
const log = std.log.scoped(.extraction_parser);
const schema = @import("schema.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Extraction parser (JSON, Graphiti shape)
// ═══════════════════════════════════════════════════════════════════════════

pub fn parseExtraction(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !schema.ExtractionResult {
    return parseExtractionImpl(allocator, raw, false);
}

fn parseExtractionImpl(
    allocator: std.mem.Allocator,
    raw: []const u8,
    is_retry: bool,
) !schema.ExtractionResult {
    // Strip whitespace and optional code fence (```json ... ```).
    var s = std.mem.trim(u8, raw, &std.ascii.whitespace);
    s = stripCodeFence(s);

    if (s.len == 0) return schema.ExtractionResult.empty(allocator);
    if (std.mem.eql(u8, s, "{}")) return schema.ExtractionResult.empty(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, s, .{}) catch |err| {
        // mem0-style regex fallback: extract the first {...} block and retry.
        // Single retry only — prevents infinite recursion on truly malformed
        // input.
        if (!is_retry) {
            if (extractFirstJsonObject(s)) |substr| {
                log.info("extraction.parse_fallback regex_recovered orig_err={s} substr_len={d}", .{
                    @errorName(err), substr.len,
                });
                return parseExtractionImpl(allocator, substr, true);
            }
        }
        log.warn("extraction.parse_failed err={s} raw_len={d} fallback_used={}", .{
            @errorName(err), s.len, is_retry,
        });
        return schema.ExtractionResult.empty(allocator);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        log.warn("extraction.parse_not_object kind={s}", .{@tagName(parsed.value)});
        return schema.ExtractionResult.empty(allocator);
    }
    const root = parsed.value.object;

    // Parse entities
    var entities: std.ArrayListUnmanaged(schema.Entity) = .empty;
    errdefer {
        for (entities.items) |*e| e.deinit(allocator);
        entities.deinit(allocator);
    }
    if (root.get("entities")) |ents_v| {
        if (ents_v == .array) {
            for (ents_v.array.items) |item| {
                const e = parseOneEntity(allocator, item) catch continue;
                if (e) |valid_entity| {
                    try entities.append(allocator, valid_entity);
                }
            }
        }
    }

    // Parse edges
    var edges: std.ArrayListUnmanaged(schema.Edge) = .empty;
    errdefer {
        for (edges.items) |*e| e.deinit(allocator);
        edges.deinit(allocator);
    }
    if (root.get("edges")) |edges_v| {
        if (edges_v == .array) {
            for (edges_v.array.items) |item| {
                const edge_opt = parseOneEdge(allocator, item) catch continue;
                if (edge_opt) |edge| {
                    try edges.append(allocator, edge);
                }
            }
        }
    }

    return .{
        .entities = try entities.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
    };
}

/// Parse a single entity JSON object. Returns null when required fields
/// missing or malformed (caller continues to the next item).
fn parseOneEntity(allocator: std.mem.Allocator, item: std.json.Value) !?schema.Entity {
    if (item != .object) return null;
    const name_v = item.object.get("name") orelse return null;
    if (name_v != .string) return null;
    if (name_v.string.len == 0) return null;
    if (name_v.string.len > 200) return null; // sanity cap; ≤5 words ~= ≤80 chars

    const type_str = if (item.object.get("type")) |t| switch (t) {
        .string => t.string,
        else => "concept",
    } else "concept";

    return schema.Entity{
        .name = try allocator.dupe(u8, name_v.string),
        .entity_type = schema.Entity.EntityType.fromString(type_str),
    };
}

/// Parse a single edge JSON object. Returns null when required fields
/// missing/malformed. Supports both `predicate` (canonical) and
/// `relation_type` (graphiti-compat) field names.
fn parseOneEdge(allocator: std.mem.Allocator, item: std.json.Value) !?schema.Edge {
    if (item != .object) return null;

    const source_v = item.object.get("source") orelse return null;
    const target_v = item.object.get("target") orelse return null;
    const fact_v = item.object.get("fact") orelse return null;
    if (source_v != .string or target_v != .string or fact_v != .string) return null;
    if (source_v.string.len == 0 or target_v.string.len == 0 or fact_v.string.len == 0) return null;

    // Predicate field has two acceptable names (mirror graphiti's flexibility):
    //   "predicate" — our canonical
    //   "relation_type" — graphiti's name
    const pred_v = item.object.get("predicate") orelse item.object.get("relation_type") orelse return null;
    if (pred_v != .string or pred_v.string.len == 0) return null;

    // Optional slot_intent
    const slot_intent: ?schema.Edge.SlotIntent = if (item.object.get("slot_intent")) |si| switch (si) {
        .string => schema.Edge.SlotIntent.fromString(si.string),
        .null => null,
        else => null,
    } else null;

    // Optional confidence
    const confidence: ?f64 = if (item.object.get("confidence")) |c| switch (c) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    } else null;

    // Optional valid_at — accept ISO-8601 string or unix integer
    const valid_at: ?i64 = if (item.object.get("valid_at")) |v| switch (v) {
        .integer => |i| i,
        .string => parseIsoToUnix(v.string),
        else => null,
    } else null;

    return schema.Edge{
        .source_name = try allocator.dupe(u8, source_v.string),
        .target_name = try allocator.dupe(u8, target_v.string),
        .relation_type = try allocator.dupe(u8, pred_v.string),
        .fact = try allocator.dupe(u8, fact_v.string),
        .slot_intent = slot_intent,
        .confidence = confidence,
        .valid_at = valid_at,
    };
}

/// Strip a markdown code fence if present. Handles ```json...``` and ```...```.
fn stripCodeFence(s: []const u8) []const u8 {
    var out = s;
    if (std.mem.startsWith(u8, out, "```")) {
        // Skip past the opening fence + optional language tag + newline
        if (std.mem.indexOfPos(u8, out, 3, "\n")) |nl| {
            out = out[nl + 1 ..];
        }
        if (std.mem.endsWith(u8, out, "```")) {
            out = out[0 .. out.len - 3];
        }
        out = std.mem.trim(u8, out, &std.ascii.whitespace);
    }
    return out;
}

/// Find the first `{...}` object substring in `s` with brace-balanced
/// matching (mem0's regex_extract_json equivalent). Returns null if no
/// balanced object found. Used as the parse fallback.
fn extractFirstJsonObject(s: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
    var depth: i32 = 0;
    var in_string = false;
    var escape = false;
    var i: usize = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (c == '\\') {
            escape = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return s[start .. i + 1];
        }
    }
    return null;
}

/// Minimal ISO-8601 → unix-seconds converter. Supports YYYY-MM-DD and
/// YYYY-MM-DDTHH:MM:SS[Z]. Returns null on parse failure (best-effort).
fn parseIsoToUnix(iso: []const u8) ?i64 {
    if (iso.len < 10) return null;
    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return null;
    if (iso[4] != '-') return null;
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return null;
    if (iso[7] != '-') return null;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) return null;
    // Days from epoch via Howard Hinnant's algorithm.
    const y = if (month <= 2) year - 1 else year;
    const m = if (month <= 2) month + 9 else month - 3;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divFloor(@as(i64, 153 * @as(i64, m) + 2), 5) + @as(i64, day) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = era * 146097 + doe - 719468;
    return days * 86400;
}

// ═══════════════════════════════════════════════════════════════════════════
// Hydration parser (XML, Claude Code shape)
// ═══════════════════════════════════════════════════════════════════════════

pub fn parseHydration(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !schema.HydrationSummary {
    const s = std.mem.trim(u8, raw, &std.ascii.whitespace);

    return .{
        .focus = (try extractTagContent(allocator, s, "focus")) orelse try allocator.dupe(u8, ""),
        .decisions = (try extractTagContent(allocator, s, "decisions")) orelse try allocator.dupe(u8, ""),
        .open_loops = (try extractTagContent(allocator, s, "open_loops")) orelse try allocator.dupe(u8, ""),
        .next = (try extractTagContent(allocator, s, "next")) orelse try allocator.dupe(u8, ""),
        .facts = (try extractTagContent(allocator, s, "facts")) orelse try allocator.dupe(u8, ""),
    };
}

/// Extract content between `<tag>` and `</tag>`. Lenient: returns null when
/// either tag is absent. Caller owns the returned slice.
fn extractTagContent(
    allocator: std.mem.Allocator,
    s: []const u8,
    tag_name: []const u8,
) !?[]u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open_tag = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag_name}) catch return null;
    const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag_name}) catch return null;

    const open_idx = std.mem.indexOf(u8, s, open_tag) orelse return null;
    const content_start = open_idx + open_tag.len;
    const close_idx = std.mem.indexOfPos(u8, s, content_start, close_tag) orelse return null;

    const content = std.mem.trim(u8, s[content_start..close_idx], &std.ascii.whitespace);
    return try allocator.dupe(u8, content);
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "parseExtraction with valid graphiti-shape JSON returns entities + edges" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "entities": [
        \\    {"name": "Caroline", "type": "person"},
        \\    {"name": "LGBTQ support group", "type": "organization"}
        \\  ],
        \\  "edges": [
        \\    {"source": "Caroline", "target": "LGBTQ support group", "predicate": "ATTENDED",
        \\     "fact": "Caroline attended an LGBTQ support group on May 7, 2023.",
        \\     "slot_intent": null, "confidence": 0.9}
        \\  ]
        \\}
    ;
    const result = try parseExtraction(allocator, raw);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.entities.len);
    try std.testing.expectEqualStrings("Caroline", result.entities[0].name);
    try std.testing.expectEqual(schema.Entity.EntityType.person, result.entities[0].entity_type);
    try std.testing.expectEqualStrings("LGBTQ support group", result.entities[1].name);
    try std.testing.expectEqual(schema.Entity.EntityType.organization, result.entities[1].entity_type);

    try std.testing.expectEqual(@as(usize, 1), result.edges.len);
    try std.testing.expectEqualStrings("Caroline", result.edges[0].source_name);
    try std.testing.expectEqualStrings("LGBTQ support group", result.edges[0].target_name);
    try std.testing.expectEqualStrings("ATTENDED", result.edges[0].relation_type);
    try std.testing.expect(result.edges[0].slot_intent == null);
    try std.testing.expectEqual(@as(?f64, 0.9), result.edges[0].confidence);
}

test "parseExtraction with empty arrays returns empty result" {
    const allocator = std.testing.allocator;
    const result = try parseExtraction(allocator, "{\"entities\":[],\"edges\":[]}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.entities.len);
    try std.testing.expectEqual(@as(usize, 0), result.edges.len);
}

test "parseExtraction with malformed JSON falls back to regex recovery" {
    const allocator = std.testing.allocator;
    // LLM accidentally wrapped JSON in prose
    const raw =
        \\Here is the extracted graph:
        \\
        \\{"entities":[{"name":"Alice","type":"person"}],"edges":[]}
        \\
        \\Hope that helps!
    ;
    const result = try parseExtraction(allocator, raw);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entities.len);
    try std.testing.expectEqualStrings("Alice", result.entities[0].name);
}

test "parseExtraction with code-fence wrapper succeeds" {
    const allocator = std.testing.allocator;
    const raw =
        \\```json
        \\{"entities":[{"name":"Bob","type":"person"}],"edges":[]}
        \\```
    ;
    const result = try parseExtraction(allocator, raw);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entities.len);
    try std.testing.expectEqualStrings("Bob", result.entities[0].name);
}

test "parseExtraction with totally garbage input returns empty result (no crash)" {
    const allocator = std.testing.allocator;
    const result = try parseExtraction(allocator, "this is not JSON at all, just words");
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.entities.len);
    try std.testing.expectEqual(@as(usize, 0), result.edges.len);
}

test "parseExtraction skips edges with missing required fields" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "entities": [{"name":"X","type":"person"}],
        \\  "edges": [
        \\    {"source":"X","target":"Y","predicate":"KNOWS","fact":"X knows Y."},
        \\    {"source":"X","predicate":"INVALID"},
        \\    {"target":"Z","predicate":"INVALID"},
        \\    {"source":"X","target":"Z","predicate":"VALID","fact":"X knows Z."}
        \\  ]
        \\}
    ;
    const result = try parseExtraction(allocator, raw);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.edges.len);
    try std.testing.expectEqualStrings("KNOWS", result.edges[0].relation_type);
    try std.testing.expectEqualStrings("VALID", result.edges[1].relation_type);
}

test "parseExtraction recognizes slot_intent values" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "entities": [{"name":"User","type":"person"},{"name":"call Alfred","type":"event"}],
        \\  "edges": [
        \\    {"source":"User","target":"call Alfred","predicate":"REMINDS_ME_TO",
        \\     "fact":"User wants to call Alfred about MNDA.","slot_intent":"open_loop"}
        \\  ]
        \\}
    ;
    const result = try parseExtraction(allocator, raw);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.edges.len);
    try std.testing.expectEqual(@as(?schema.Edge.SlotIntent, .open_loop), result.edges[0].slot_intent);
}

test "parseExtraction accepts both 'predicate' and 'relation_type' field names" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "entities": [{"name":"X","type":"person"}],
        \\  "edges": [
        \\    {"source":"X","target":"X","relation_type":"GRAPHITI_STYLE","fact":"x"}
        \\  ]
        \\}
    ;
    const result = try parseExtraction(allocator, raw);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.edges.len);
    try std.testing.expectEqualStrings("GRAPHITI_STYLE", result.edges[0].relation_type);
}

test "parseHydration extracts all five tags" {
    const allocator = std.testing.allocator;
    const raw =
        \\<summary>
        \\<focus>shipping V1.14.8</focus>
        \\<decisions>
        \\- split hydration from extraction
        \\</decisions>
        \\<open_loops>
        \\- finalize parser tests
        \\</open_loops>
        \\<next>
        \\- run integration test
        \\</next>
        \\<facts>
        \\- new module at src/agent/extraction/
        \\</facts>
        \\</summary>
    ;
    const h = try parseHydration(allocator, raw);
    defer h.deinit(allocator);
    try std.testing.expectEqualStrings("shipping V1.14.8", h.focus);
    try std.testing.expectEqualStrings("- split hydration from extraction", h.decisions);
    try std.testing.expectEqualStrings("- finalize parser tests", h.open_loops);
    try std.testing.expectEqualStrings("- run integration test", h.next);
    try std.testing.expectEqualStrings("- new module at src/agent/extraction/", h.facts);
}

test "parseHydration with missing tags returns empty strings" {
    const allocator = std.testing.allocator;
    const raw = "<summary><focus>only focus</focus></summary>";
    const h = try parseHydration(allocator, raw);
    defer h.deinit(allocator);
    try std.testing.expectEqualStrings("only focus", h.focus);
    try std.testing.expectEqualStrings("", h.decisions);
    try std.testing.expectEqualStrings("", h.open_loops);
    try std.testing.expectEqualStrings("", h.next);
    try std.testing.expectEqualStrings("", h.facts);
}

test "extractFirstJsonObject handles nested braces correctly" {
    const found = extractFirstJsonObject("prefix {\"a\": {\"b\": 1}} suffix") orelse unreachable;
    try std.testing.expectEqualStrings("{\"a\": {\"b\": 1}}", found);
}

test "extractFirstJsonObject ignores braces inside strings" {
    const found = extractFirstJsonObject("prefix {\"a\": \"}{}\"} suffix") orelse unreachable;
    try std.testing.expectEqualStrings("{\"a\": \"}{}\"}", found);
}

test "parseIsoToUnix handles YYYY-MM-DD" {
    // 2023-05-07 = unix 1683417600
    try std.testing.expectEqual(@as(?i64, 1683417600), parseIsoToUnix("2023-05-07"));
    try std.testing.expectEqual(@as(?i64, 1683417600), parseIsoToUnix("2023-05-07T12:00:00Z"));
    try std.testing.expectEqual(@as(?i64, null), parseIsoToUnix("not-a-date"));
    try std.testing.expectEqual(@as(?i64, null), parseIsoToUnix(""));
}
