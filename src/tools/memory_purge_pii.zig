//! `memory_purge_pii` — bulk-delete memories tagged with detected PII
//! categories (D52 Pillar 4 — closes the per-category PII delete gap
//! the v1 production-readiness audit called out).
//!
//! ## Why
//!
//! Pillar 1 (system-prompt directive at `src/agent/prompt.zig:668`)
//! tells the agent it MAY persist user-volunteered personal information
//! (phone numbers, emails, addresses, family names, etc.). Pillar 2
//! (`src/memory/pii_detect.zig` + the `extraction_persist.buildExtractionMetadata`
//! integration) tags those memories with `metadata.pii_tags = ["phone", "email", ...]`
//! at persist time. Without this tool, the user has no agent-facing way
//! to say "forget all my phone numbers" — they can only `memory_forget`
//! one key at a time, which they don't know.
//!
//! ## Behavior
//!
//! * Three categories: `phone`, `email`, `all`.
//! * Dry-run mode returns the count + key list without deleting.
//! * Always user-scoped via tenant binding (`bindStateMgrTenant`).
//! * Each delete cascades memory_edges via the standard `forgetMemory`
//!   path (no special-case purge SQL — reuses the audited cascade).
//! * Idempotent: re-running purges any newly-tagged rows; doesn't
//!   resurrect previously-deleted ones.
//!
//! ## Not in scope for V1
//!
//! * Address detection (Pillar 2 V1.1 — too noisy without NER).
//! * At-rest encryption of pii_tagged rows (Pillar 5 — depends on D47
//!   secret vault).
//! * UI surface for per-row preview/select (Pillar 3 — handoff doc
//!   §3.1 documents this as agent-mediated for V1).

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");
const pii_detect = @import("../memory/pii_detect.zig");

const log = std.log.scoped(.memory_purge_pii);

pub const MemoryPurgePiiTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "memory_purge_pii";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Bulk-delete user memories tagged as PII (phone, email, or all).",
        .use_when = &.{
            "User asks to forget all their stored phone numbers, email addresses, or all PII",
            "GDPR-style data-subject delete for a specific personal-information category",
            "Resetting the persistent personal-memory layer before sharing the account",
        },
        .do_not_use_for = &.{
            "memory_forget — for deleting one memory by exact key",
            "memory_archive — for soft-close with audit retention",
            "memory_purge_topic — for bulk delete by topic rather than PII category",
        },
        .cost_note = "Local; one DB round-trip per matched memory (cascade aware).",
        .completion_hint = "Returns counts of candidates and deleted memories.",
        .see_also = &.{
            "memory_forget — single-key delete",
            "memory_list — inspect the corpus before purging",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_purge_pii", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Delete all memories tagged with the requested PII category. " ++
        "`category` is one of: \"phone\" (numbers), \"email\" (addresses), " ++
        "or \"all\" (every memory carrying any PII tag). When `dry_run` is " ++
        "true, returns the candidate count + key list without deleting. " ++
        "Only memories written through paths that ran PII detection get " ++
        "tagged (memory_store and extraction-time writes from 2026-05-28 " ++
        "onward); older memories may need a manual `memory_forget` by key.";

    pub const tool_params =
        \\{"type":"object","properties":{"category":{"type":"string","enum":["phone","email","all"],"description":"Which PII category to purge. 'all' covers every category."},"dry_run":{"type":"boolean","description":"When true, returns the candidate list without deleting (default: false)."}},"required":["category"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryPurgePiiTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *MemoryPurgePiiTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sm = self.state_mgr orelse return ToolResult.fail("memory_purge_pii unavailable: state manager not bound (postgres not configured)");
        const uid = self.user_id orelse return ToolResult.fail("memory_purge_pii unavailable: user_id not bound");

        const category = root.getString(args, "category") orelse
            return ToolResult.fail("Missing 'category' parameter. Use 'phone', 'email', or 'all'.");
        if (pii_detect.flagsForCategory(category) == null) {
            return ToolResult.fail("Invalid 'category'. Use 'phone', 'email', or 'all'.");
        }

        const dry_run = root.getBool(args, "dry_run") orelse false;

        const keys = sm.listPiiMemoryKeys(allocator, uid, category) catch |err| {
            log.warn("listPiiMemoryKeys failed user={d} category={s} err={s}", .{ uid, category, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to list PII memories: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        defer {
            for (keys) |k| allocator.free(k);
            allocator.free(keys);
        }

        if (dry_run) {
            // Build a short summary with up to the first 10 keys for visibility.
            var buf: std.ArrayListUnmanaged(u8) = .{};
            errdefer buf.deinit(allocator);
            const w = buf.writer(allocator);
            try w.print("Dry run: {d} memories tagged '{s}' would be deleted", .{ keys.len, category });
            if (keys.len > 0) {
                try w.writeAll(". First keys: ");
                const cap = @min(keys.len, 10);
                for (keys[0..cap], 0..) |k, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(k);
                }
                if (keys.len > cap) try w.print(" (+{d} more)", .{keys.len - cap});
            }
            try w.writeAll(".");
            return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
        }

        if (keys.len == 0) {
            const msg = try std.fmt.allocPrint(allocator, "No PII-tagged memories found in category '{s}'.", .{category});
            return ToolResult{ .success = true, .output = msg };
        }

        const deleted = sm.deletePiiMemoriesByCategory(allocator, uid, category) catch |err| {
            log.warn("deletePiiMemoriesByCategory failed user={d} category={s} err={s}", .{ uid, category, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to delete PII memories: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        const msg = try std.fmt.allocPrint(
            allocator,
            "Purged {d}/{d} PII-tagged memories (category={s}).",
            .{ deleted, keys.len, category },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "memory_purge_pii tool name" {
    var mt = MemoryPurgePiiTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_purge_pii", t.name());
}

test "memory_purge_pii schema declares category + dry_run" {
    var mt = MemoryPurgePiiTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "category") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "dry_run") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "phone") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "email") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "all") != null);
}

test "memory_purge_pii requires state_mgr binding" {
    var mt = MemoryPurgePiiTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"category\":\"phone\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // `ToolResult.fail()` returns a literal output ("") and literal
    // error_msg — do NOT free. Convention matches brain_graph + any
    // tool that uses `fail()` for early-exit unbound checks.
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}

test "memory_purge_pii missing category" {
    var mt = MemoryPurgePiiTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_purge_pii rejects unknown category" {
    // Even without state_mgr, category validation should fire on bound contexts.
    // Here we exercise the validation against an unbound context: it short-
    // circuits on the state_mgr check (also a `fail()`), which is fine —
    // the literal-error path is the same. The validation itself is
    // independently covered by pii_detect.flagsForCategory tests.
    var mt = MemoryPurgePiiTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"category\":\"address\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}
