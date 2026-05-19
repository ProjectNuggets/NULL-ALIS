//! Compose memory tool — synthesizes 2+ existing memories into a single
//! consolidated fact with provenance metadata. V1.5 day-3 ship 2026-05-05.
//!
//! Design intent (per docs/v1.5-design-kickoff.md):
//! - Visible authorship: `{synthesized_by:"agent", references:[source_keys]}`
//!   stored in the `metadata` JSONB column. /brain/graph reference-edge
//!   builder reads metadata.references to render provenance lines.
//! - Pure synthesis content — no `memory:<key>` markers in content.
//!   Provenance lives in metadata so the synthesis reads cleanly when the
//!   agent retrieves it later. (The /brain/graph builder reads metadata
//!   directly; old-style markers still work as a fallback for legacy.)
//! - Caller provides synthesis text. V1.5 ships the primitive; V1.6 will
//!   add an LLM-trigger endpoint that accepts just `references[]` and
//!   spawns an agent turn to do the synthesis.
//! - Each compose write also lands a `memory_events` row with
//!   `event_type='compose'` (handled by `state_mgr.upsertMemoryWithMetadata`).
//!   Sets up V1.5 day-4 traversal-event logging on existing infrastructure.
//!
//! Bi-temporal note: V1.5 always-null `valid_to` — composes don't yet
//! retire their source memories. V1.6 correction classifier will set
//! `valid_to=now()` on sources that the synthesis fully replaces; for
//! V1.5 the sources remain visible alongside the synthesis. Audit trail
//! is preserved via metadata.references regardless.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const MemoryCategory = mem_root.MemoryCategory;
const security_secrets = @import("../security/secrets.zig");
const zaki_state = @import("../zaki_state.zig");

const log = std.log.scoped(.compose_memory_tool);

/// Memory key prefix for synthesized memories. Easy to filter via memory_search.
pub const COMPOSE_KEY_PREFIX = "compose:";

/// Maximum synthesized title length. Matches todo tool conventions.
pub const MAX_TITLE_LEN = 240;

/// Maximum synthesis content length. Generous — a synthesis can fold many
/// underlying memories — but capped to prevent unbounded writes.
pub const MAX_CONTENT_LEN = 50_000;

/// Minimum reference count. Compose semantically distinct from a single
/// memory write — reject 0 or 1 references; the user wants `memory.save`.
pub const MIN_REFERENCES = 2;

/// Maximum reference count. 50 source memories is "fold the whole memory" —
/// agent is over-reaching. Larger consolidations should be staged in
/// multiple compose calls (synthesize subgroups, then synthesize the
/// syntheses).
pub const MAX_REFERENCES = 50;

/// Maximum reference key length. Memory keys today are well under this;
/// defensive cap against pathological inputs.
pub const MAX_REFERENCE_KEY_LEN = 256;

pub const ComposeMemoryTool = struct {
    memory: ?Memory = null,
    /// V1.14.12 (Memory audit Finding 11 fix, 2026-05-19) — tenant
    /// context for server-side reference validation. When set, the
    /// tool calls `state_mgr.existsMemoryKeys` to reject compose
    /// writes with dangling references, matching the HTTP
    /// /brain/compose path (gateway.zig:14292-14308). Pre-fix the
    /// agent tool only validated reference SHAPE (string, non-empty,
    /// length cap, no duplicates) but didn't check existence — so
    /// agent-issued compose rows could carry dangling refs that
    /// became invisible/broken provenance edges in /brain/graph.
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "compose_memory";
    pub const tool_description =
        "Synthesize 2+ existing memories into a single consolidated fact with " ++
        "visible provenance (synthesized_by + references). CALL THIS when you " ++
        "have multiple related memories (preferences, recurring topics, " ++
        "session insights) that should fold into one coherent understanding " ++
        "the user can SEE on the /brain page. Provide the synthesis text " ++
        "yourself — read the source memories, compose the fact, then call " ++
        "this tool to record it. Sources stay visible alongside the synthesis " ++
        "(audit trail). Minimum 2 references; maximum 50.";
    pub const tool_params =
        \\{"type":"object","properties":{
        \\"action":{"type":"string","enum":["create"],"description":"Only 'create' is supported in V1.5. compose_memory list/recall use the standard memory_search and memory_recall tools — synthesized memories are just memories with metadata."},
        \\"title":{"type":"string","description":"Short human-readable title for the synthesis (≤240 chars). Used as the memory key suffix when 'key' is not provided."},
        \\"content":{"type":"string","description":"The synthesis text — pure consolidated fact, no boilerplate. References are stored in metadata, not content."},
        \\"references":{"type":"array","items":{"type":"string"},"description":"Memory keys this synthesis is composed from (min 2, max 50). These appear as reference edges on /brain/graph."},
        \\"category":{"type":"string","enum":["core","daily","conversation"],"description":"Memory category. Default 'core' — synthesized facts are usually evergreen."},
        \\"link_type":{"type":"string","enum":["preference","attribute","supersession","relationship","usage","synthesis","episode"],"description":"V1.7a-5 — relationship category. Defaults to 'synthesis' for compose_memory output. Set explicitly when the synthesis represents a different semantic shape (e.g. 'preference' for a consolidated preference list, 'relationship' for a synthesized people-graph node)."},
        \\"key":{"type":"string","description":"Optional explicit key for the synthesized memory. If omitted, auto-generated as 'compose:<random_hex>'."}
        \\},"required":["action","title","content","references"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ComposeMemoryTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ComposeMemoryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter — only 'create' is supported in V1.5");

        const m = self.memory orelse {
            return ToolResult.fail("compose_memory tool requires memory backend (none configured)");
        };

        if (std.mem.eql(u8, action, "create")) return executeCreate(allocator, m, args, self.state_mgr, self.user_id);
        return ToolResult.fail("Unknown action — only 'create' is supported in V1.5");
    }
};

// ── action: create ──────────────────────────────────────────────────────

fn executeCreate(
    allocator: std.mem.Allocator,
    m: Memory,
    args: JsonObjectMap,
    state_mgr: ?*zaki_state.Manager,
    user_id: ?i64,
) !ToolResult {
    // ── title ──
    const title = root.getString(args, "title") orelse
        return ToolResult.fail("Missing 'title' for action=create");
    const trimmed_title = std.mem.trim(u8, title, " \t\r\n");
    if (trimmed_title.len == 0) return ToolResult.fail("'title' must not be empty");
    if (trimmed_title.len > MAX_TITLE_LEN) {
        const msg = try std.fmt.allocPrint(allocator, "'title' too long (max {d} chars)", .{MAX_TITLE_LEN});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    // ── content ──
    const content = root.getString(args, "content") orelse
        return ToolResult.fail("Missing 'content' for action=create");
    const trimmed_content = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed_content.len == 0) return ToolResult.fail("'content' must not be empty — synthesis required");
    if (trimmed_content.len > MAX_CONTENT_LEN) {
        const msg = try std.fmt.allocPrint(allocator, "'content' too long (max {d} chars). Synthesis should be a consolidation, not a dump.", .{MAX_CONTENT_LEN});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    // ── references ──
    const refs_val = args.get("references") orelse
        return ToolResult.fail("Missing 'references' for action=create — at least 2 source memory keys required");
    if (refs_val != .array) return ToolResult.fail("'references' must be a JSON array of memory keys");
    const refs = refs_val.array.items;
    if (refs.len < MIN_REFERENCES) {
        const msg = try std.fmt.allocPrint(allocator, "'references' must contain at least {d} memory keys — compose is for consolidating multiple memories. Use memory_save for single-source writes.", .{MIN_REFERENCES});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
    if (refs.len > MAX_REFERENCES) {
        const msg = try std.fmt.allocPrint(allocator, "'references' too long (max {d}). Synthesize sub-groups first, then compose the syntheses.", .{MAX_REFERENCES});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
    // Validate each reference is a non-empty string within the key length cap.
    for (refs, 0..) |r, idx| {
        if (r != .string) {
            const msg = try std.fmt.allocPrint(allocator, "references[{d}] must be a string memory key", .{idx});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        if (r.string.len == 0) {
            const msg = try std.fmt.allocPrint(allocator, "references[{d}] must not be empty", .{idx});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        if (r.string.len > MAX_REFERENCE_KEY_LEN) {
            const msg = try std.fmt.allocPrint(allocator, "references[{d}] key too long (max {d} chars)", .{ idx, MAX_REFERENCE_KEY_LEN });
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
    }
    // Detect duplicates — composing memory:k twice in the same synthesis is
    // a sign the agent is over-counting; surface it as an error rather than
    // dedup silently.
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);
    for (refs, 0..) |r, idx| {
        const key = r.string;
        if (seen.contains(key)) {
            const msg = try std.fmt.allocPrint(allocator, "references[{d}] '{s}' duplicates an earlier entry — each source memory should appear once", .{ idx, key });
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        try seen.put(allocator, key, {});
    }

    // V1.14.12 (Memory audit Finding 11 fix, 2026-05-19) — server-side
    // reference EXISTENCE validation, matching HTTP /brain/compose at
    // gateway.zig:14292-14308. Pre-fix the tool only validated reference
    // shape; agents could write compose rows pointing at keys that
    // didn't exist, producing dangling provenance edges that the
    // brain/graph reference-edge builder silently dropped. When tenant
    // context is available, reject upfront. When unavailable (sqlite
    // build / pre-tenant), the existing shape-only validation remains
    // the floor — no regression.
    if (state_mgr) |smgr| {
        if (user_id) |uid| {
            // Collect reference keys into a borrowed slice. The JSON
            // value array's strings live as long as `args`, which
            // outlives this scope.
            var ref_keys: std.ArrayListUnmanaged([]const u8) = .{};
            defer ref_keys.deinit(allocator);
            for (refs) |r| ref_keys.append(allocator, r.string) catch return ToolResult.fail("compose_memory: OOM during reference validation");
            var existing = smgr.existsMemoryKeys(allocator, uid, ref_keys.items) catch {
                return ToolResult.fail("compose_memory: reference existence check failed");
            };
            defer {
                var it = existing.iterator();
                while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                existing.deinit(allocator);
            }
            for (refs, 0..) |r, idx| {
                if (!existing.contains(r.string)) {
                    const msg = try std.fmt.allocPrint(
                        allocator,
                        "references[{d}] '{s}' does not resolve to an existing memory for this user. Compose only over keys that exist; check with memory_search before composing.",
                        .{ idx, r.string },
                    );
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                }
            }
        }
    }

    // ── category ──
    const cat_str = root.getString(args, "category") orelse "core";
    const category: MemoryCategory = blk_cat: {
        if (std.mem.eql(u8, cat_str, "core")) break :blk_cat .core;
        if (std.mem.eql(u8, cat_str, "daily")) break :blk_cat .daily;
        if (std.mem.eql(u8, cat_str, "conversation")) break :blk_cat .conversation;
        const msg = try std.fmt.allocPrint(allocator, "Unknown category '{s}' — must be core, daily, or conversation", .{cat_str});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };

    // ── link_type (V1.7a-5 — spec seam 3) ──
    // Optional. Default `.synthesis` matches compose_memory's natural
    // shape: consolidating multiple sources INTO one fact. Agents should
    // override only when the consolidation expresses a different
    // relationship category (e.g. `.preference` when the synthesis is
    // "user prefers X across these sources").
    const link_type: mem_root.LinkType = blk_lt: {
        const lt_str = root.getString(args, "link_type") orelse break :blk_lt .synthesis;
        const trimmed_lt = std.mem.trim(u8, lt_str, " \t\r\n");
        if (trimmed_lt.len == 0) break :blk_lt .synthesis;
        const parsed = mem_root.LinkType.fromString(trimmed_lt) orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Unknown link_type '{s}' — must be one of: preference, attribute, supersession, relationship, usage, synthesis, episode",
                .{trimmed_lt},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        break :blk_lt parsed;
    };

    // ── key (auto-generated when not provided) ──
    // V1.5 day-3 review fix: user-provided keys MUST start with the
    // compose: prefix. Without this guard, a caller could overwrite an
    // unrelated memory by passing its key (e.g. `"user_lang"` would
    // OVERWRITE the user_lang memory via the upsert ON CONFLICT path).
    // Enforcing the prefix isolates compose-write namespace from other
    // memory writers.
    var key_buf: [64]u8 = undefined;
    const memory_key = if (root.getString(args, "key")) |provided_key| blk_key: {
        const trimmed_key = std.mem.trim(u8, provided_key, " \t\r\n");
        if (trimmed_key.len == 0) return ToolResult.fail("'key' must not be empty if provided");
        if (!std.mem.startsWith(u8, trimmed_key, COMPOSE_KEY_PREFIX)) {
            return ToolResult.fail("'key' must start with 'compose:' to prevent overwriting unrelated memories");
        }
        break :blk_key try allocator.dupe(u8, trimmed_key);
    } else blk_key: {
        // Generate `compose:<16-hex>` from 8 random bytes. Use the
        // codebase's existing hexEncode helper from security/secrets
        // (Zig 0.15.2 dropped std.fmt.fmtSliceHexLower).
        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        var hex_buf: [16]u8 = undefined;
        const hex = security_secrets.hexEncode(&rand_buf, &hex_buf);
        const full = try std.fmt.bufPrint(&key_buf, "{s}{s}", .{ COMPOSE_KEY_PREFIX, hex });
        break :blk_key try allocator.dupe(u8, full);
    };
    defer allocator.free(memory_key);

    // ── Build metadata JSON ──
    // V1.7a-5 (spec seam 3): metadata now carries `link_type` so the
    // SQL-side `(metadata->>'link_type')` extraction populates the
    // memory row's link_type column atomically with the metadata write.
    // Shape: {"synthesized_by":"agent","references":[...],"composed_at":<unix>,"title":"...","link_type":"..."}
    var meta_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer meta_buf.deinit(allocator);
    const mw = meta_buf.writer(allocator);
    try mw.writeAll("{\"synthesized_by\":\"agent\",\"references\":[");
    for (refs, 0..) |r, idx| {
        if (idx > 0) try mw.writeAll(",");
        try writeJsonString(mw, r.string);
    }
    try mw.print("],\"composed_at\":{d},\"title\":", .{std.time.timestamp()});
    try writeJsonString(mw, trimmed_title);
    try mw.writeAll(",\"link_type\":");
    try writeJsonString(mw, link_type.toString());
    try mw.writeAll("}");

    // ── Write via storeWithMetadata ──
    // V1.5 uses session_id=null — synthesized memories are global (cross-
    // session). They consolidate facts that may have come from many
    // sessions, so binding them to one session is wrong. Future: when a
    // synthesis is session-scoped (e.g. "summary of this conversation"),
    // expose a session_id arg.
    m.storeWithMetadata(memory_key, trimmed_content, category, null, meta_buf.items) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "compose_memory store failed: {s}", .{@errorName(err)});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };

    // ── Build success output ──
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll("{\"action\":\"create\",\"key\":");
    try writeJsonString(w, memory_key);
    try w.writeAll(",\"title\":");
    try writeJsonString(w, trimmed_title);
    try w.writeAll(",\"references_count\":");
    try w.print("{d}", .{refs.len});
    try w.writeAll(",\"category\":");
    try writeJsonString(w, cat_str);
    try w.writeAll(",\"link_type\":");
    try writeJsonString(w, link_type.toString());
    try w.writeAll(",\"composed_at\":");
    try w.print("{d}", .{std.time.timestamp()});
    try w.writeAll("}");

    return ToolResult{
        .success = true,
        .output = try out.toOwnedSlice(allocator),
        .error_msg = "",
    };
}

// ── JSON helper ──────────────────────────────────────────────────────────

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // Other ASCII control bytes — escape as \u00XX. Carve out
            // the explicit cases above so this range doesn't overlap.
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeAll("\"");
}

// ── Tests ────────────────────────────────────────────────────────────────

test "compose_memory: tool_name and description present" {
    try std.testing.expect(ComposeMemoryTool.tool_name.len > 0);
    try std.testing.expect(ComposeMemoryTool.tool_description.len > 0);
    try std.testing.expect(ComposeMemoryTool.tool_params.len > 0);
}

test "compose_memory: bounds constants are sane" {
    try std.testing.expect(MIN_REFERENCES >= 2);
    try std.testing.expect(MAX_REFERENCES > MIN_REFERENCES);
    try std.testing.expect(MAX_CONTENT_LEN > MAX_TITLE_LEN);
    try std.testing.expect(MAX_REFERENCE_KEY_LEN > 0);
}

test "compose_memory: writeJsonString escapes special chars" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(std.testing.allocator), "hello \"world\"\n\t\\test");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\n\\t\\\\test\"", buf.items);
}

test "compose_memory: writeJsonString preserves UTF-8 bytes" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(std.testing.allocator), "السلام");
    // Should pass through UTF-8 unchanged (only escape ASCII control chars
    // and JSON-special chars).
    try std.testing.expectEqualStrings("\"السلام\"", buf.items);
}

test "compose_memory: writeJsonString escapes control chars below 0x20" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(std.testing.allocator), &[_]u8{ 'a', 0x01, 0x1f, 'b' });
    try std.testing.expectEqualStrings("\"a\\u0001\\u001fb\"", buf.items);
}

test "compose_memory: COMPOSE_KEY_PREFIX guards against arbitrary key writes" {
    // V1.5 day-3 review fix: user-provided keys must start with the
    // prefix to prevent overwriting unrelated memories via upsert ON
    // CONFLICT. The check uses startsWith — verify the prefix shape
    // here so a future rename catches missing-fix call sites.
    try std.testing.expect(std.mem.startsWith(u8, "compose:abc123", COMPOSE_KEY_PREFIX));
    try std.testing.expect(!std.mem.startsWith(u8, "user_lang", COMPOSE_KEY_PREFIX));
    try std.testing.expect(!std.mem.startsWith(u8, "Compose:abc", COMPOSE_KEY_PREFIX));
    try std.testing.expect(!std.mem.startsWith(u8, "memory:foo", COMPOSE_KEY_PREFIX));
}

test "compose_memory: tool_params link_type enum mirrors LinkType (V1.7a-5 drift guard)" {
    // V1.7a-5 self-review: tool_params is a hand-written JSON-string
    // schema. If a future commit adds a new LinkType variant in
    // memory_root.zig, the LLM-side hint AND this enum constraint must
    // update too — otherwise the model won't know about the new value.
    // This test FAILS if the enum drifts from ALL_LINK_TYPES.
    inline for (mem_root.ALL_LINK_TYPES) |lt| {
        // Tool params must contain the literal string "<lt>" (quoted) inside
        // the link_type field's enum array. Defensive bracketed check so we
        // don't false-positive against substrings of category descriptions.
        const quoted = "\"" ++ lt ++ "\"";
        const pos = std.mem.indexOf(u8, ComposeMemoryTool.tool_params, quoted);
        if (pos == null) {
            std.debug.print("\nLinkType '{s}' missing from compose_memory.tool_params enum — drift detected\n", .{lt});
            return error.LinkTypeEnumDriftDetected;
        }
    }
}
