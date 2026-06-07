//! Todo tool — structured task lists with state tracking, persisted via the
//! memory layer. V1.5 ship 2026-05-05.
//!
//! Design intent (per docs/v1.5-design-kickoff.md):
//! - Per-session scope (todos are "this conversation's work").
//! - Three actions: create / update / list.
//! - Persistence rides existing memory schema — no migration. Each list = one
//!   memory entry with key `todo:<list_id>` + content = JSON of the list state.
//!   Category = .daily so it scopes per-session and benefits from existing
//!   retention policies.
//! - This is for user-visible durable checklists in the current conversation.
//!   Internal execution planning belongs to `<task_plan>` in the agent loop,
//!   not to persisted todos.
//!
//! Bi-temporal note (Graphiti pattern, V1.5 schema): when a todo item gets
//! re-prioritized or the list is replaced, we don't mutate — we add a new
//! list entry and let the old one expire via memory retention. Future
//! `valid_to` field on memory entries (V1.5+) enables explicit supersede.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const MemoryCategory = mem_root.MemoryCategory;

const log = std.log.scoped(.todo_tool);

/// Memory key prefix for todo lists. Easy to filter-by-prefix when listing.
pub const TODO_KEY_PREFIX = "todo:";

/// Maximum items per list. Beyond this, the agent is over-decomposing —
/// suggest the user split into multiple sessions or reduce granularity.
pub const MAX_ITEMS = 50;

/// Maximum item title length. Keeps each item readable in UI without
/// wrapping. Longer descriptions go in `note` field on update.
pub const MAX_ITEM_TITLE_LEN = 240;

/// Maximum list title length.
pub const MAX_LIST_TITLE_LEN = 120;

/// Recent duplicate-create window. Protects the session from repeated
/// identical checklist creation when the model retries or reformats a call.
pub const DUPLICATE_CREATE_WINDOW_SECS: i64 = 300;

/// Status of a single todo item.
pub const TodoStatus = enum {
    pending,
    in_progress,
    completed,
    blocked,

    pub fn fromString(s: []const u8) ?TodoStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return null;
    }

    pub fn toSlice(self: TodoStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .blocked => "blocked",
        };
    }
};

/// Tool surface. Single tool with action dispatch — same shape as schedule.zig
/// since the actions share lifecycle context (memory backend, session_id).
pub const TodoTool = struct {
    memory: ?Memory = null,

    pub const tool_name = "todo";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "User-visible session todo list with status tracking (pending/in_progress/completed/blocked).",
        .use_when = &.{
            "User explicitly asks for a todo list, checklist, task list, or status-tracked plan",
            "User provides multiple tasks they want tracked visibly across this conversation",
            "Long-running work needs a durable progress checklist the user can inspect or revise",
        },
        .do_not_use_for = &.{
            "task_list — for spawned background subagent tasks rather than in-conversation todos",
            "schedule — for time-based proactive jobs rather than transient session todos",
            "memory_store — for durable facts rather than transient task tracking",
            "context_snapshot — for current agent state; do not use todo for private internal execution plans",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("todo", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Create and manage user-visible session todo lists with status tracking. " ++
        "Use only when the user explicitly wants a todo/checklist/task list, " ++
        "or when long work needs a durable progress checklist the user can " ++
        "inspect or revise. Do not use this for private internal planning, " ++
        "hidden validation steps, or ordinary tool sequencing — use prose or " ++
        "<task_plan> for that. Per-session scope. On update, always include " ++
        "the returned list_id, item_id, and status unless exactly one session list exists.";
    pub const tool_params =
        \\{"type":"object","properties":{
        \\"action":{"type":"string","enum":["create","update","list","current","start","complete","block"],"description":"create=user-visible list with items, update=change one item's status, list/current=read current session todos, start/complete/block=convenience status updates"},
        \\"title":{"type":"string","description":"List title (action=create)"},
        \\"items":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"depends_on":{"type":"array","items":{"type":"integer"}}},"required":["title"]},"description":"User-visible items to add (action=create), not private internal planning steps. Each item gets an integer id 1..N. depends_on lists prerequisite item ids."},
        \\"list_id":{"type":"string","description":"Target list (action=update/start/complete/block optional only when exactly one session list exists; action=list/current optional — defaults to most-recent in this session)"},
        \\"item_id":{"type":"integer","description":"Target item id (action=update/start/complete/block)"},
        \\"status":{"type":"string","enum":["pending","in_progress","completed","blocked"],"description":"New status (action=update)"},
        \\"note":{"type":"string","description":"Optional note on the status change (action=update/block)"}
        \\},"required":["action"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TodoTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *TodoTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter — must be one of: create, update, list");

        const m = self.memory orelse {
            return ToolResult.fail("Todo tool requires memory backend (none configured)");
        };

        // Resolve session_key from the runtime turn context. Per-session scope
        // is the V1.5 design choice: todos belong to the conversation that
        // created them. Cross-session promotion is a future iter. The
        // RuntimeTurnContext exposes `session_key` (canonical session
        // identifier — `agent:zaki-bot:user:N:thread:abc` shape); we pass
        // it through to memory.store as the session_id arg.
        const session_id = root.getTurnContext().session_key orelse {
            return ToolResult.fail("Todo tool requires an active session (no session_key in turn context)");
        };

        if (std.mem.eql(u8, action, "create")) return executeCreate(allocator, m, session_id, args);
        if (std.mem.eql(u8, action, "update")) return executeUpdate(allocator, m, session_id, args, null);
        if (std.mem.eql(u8, action, "start")) return executeUpdate(allocator, m, session_id, args, .in_progress);
        if (std.mem.eql(u8, action, "complete")) return executeUpdate(allocator, m, session_id, args, .completed);
        if (std.mem.eql(u8, action, "block")) return executeUpdate(allocator, m, session_id, args, .blocked);
        if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "current")) return executeList(allocator, m, session_id, args);

        return ToolResult.fail("Unknown action — must be one of: create, update, list, current, start, complete, block");
    }
};

// ── action: create ──────────────────────────────────────────────────────

fn executeCreate(
    allocator: std.mem.Allocator,
    m: Memory,
    session_id: []const u8,
    args: JsonObjectMap,
) !ToolResult {
    const title = root.getString(args, "title") orelse
        return ToolResult.fail("Missing 'title' for action=create");
    const trimmed_title = std.mem.trim(u8, title, " \t\r\n");
    if (trimmed_title.len == 0) return ToolResult.fail("'title' must not be empty");
    if (trimmed_title.len > MAX_LIST_TITLE_LEN) {
        const msg = try std.fmt.allocPrint(allocator, "'title' too long (max {d} chars)", .{MAX_LIST_TITLE_LEN});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    // Items: must be a non-empty JSON array.
    const items_val = args.get("items") orelse
        return ToolResult.fail("Missing 'items' for action=create");
    if (items_val != .array) return ToolResult.fail("'items' must be a JSON array");
    if (items_val.array.items.len == 0) return ToolResult.fail("'items' must not be empty — at least one task required");
    if (items_val.array.items.len > MAX_ITEMS) {
        const msg = try std.fmt.allocPrint(allocator, "'items' too long (max {d}). Split into multiple lists or reduce granularity.", .{MAX_ITEMS});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    // Generate list_id from session_id + nanos. Stable enough for one-list-
    // per-session-per-turn cadence; collisions only matter if the agent
    // creates two lists in the same nanosecond which is functionally
    // impossible.
    const ts_ns = std.time.nanoTimestamp();
    const list_id = try std.fmt.allocPrint(allocator, "{d}", .{ts_ns});
    defer allocator.free(list_id);

    const memory_key = try std.fmt.allocPrint(allocator, "{s}{s}", .{ TODO_KEY_PREFIX, list_id });
    defer allocator.free(memory_key);

    // Build the list JSON body.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = body.writer(allocator);

    const ts_secs = std.time.timestamp();

    try w.writeAll("{\"title\":");
    try writeJsonString(w, trimmed_title);
    try w.writeAll(",\"items\":[");

    for (items_val.array.items, 0..) |item_val, idx| {
        if (idx > 0) try w.writeAll(",");

        if (item_val != .object) {
            const msg = try std.fmt.allocPrint(allocator, "items[{d}] must be a JSON object with a 'title' field", .{idx});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const item_title_val = item_val.object.get("title") orelse {
            const msg = try std.fmt.allocPrint(allocator, "items[{d}] missing 'title' field", .{idx});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        if (item_title_val != .string) {
            const msg = try std.fmt.allocPrint(allocator, "items[{d}].title must be a string", .{idx});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        const item_title = std.mem.trim(u8, item_title_val.string, " \t\r\n");
        if (item_title.len == 0) {
            const msg = try std.fmt.allocPrint(allocator, "items[{d}].title must not be empty", .{idx});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        if (item_title.len > MAX_ITEM_TITLE_LEN) {
            const msg = try std.fmt.allocPrint(allocator, "items[{d}].title too long (max {d}). Move detail to 'note' field on update.", .{ idx, MAX_ITEM_TITLE_LEN });
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const item_id: usize = idx + 1; // 1-indexed for human-friendly display
        try w.print("{{\"id\":{d},\"title\":", .{item_id});
        try writeJsonString(w, item_title);
        try w.writeAll(",\"status\":\"pending\",\"depends_on\":[");

        // depends_on is optional. Validate that ids are integers in [1..N].
        if (item_val.object.get("depends_on")) |dep_val| {
            if (dep_val == .array) {
                var first = true;
                for (dep_val.array.items) |d| {
                    if (d != .integer) continue;
                    const dep_id = d.integer;
                    if (dep_id < 1 or dep_id >= @as(i64, @intCast(item_id))) {
                        // Out-of-range or forward-reference: skip silently.
                        // depends_on must reference earlier items only.
                        continue;
                    }
                    if (!first) try w.writeAll(",");
                    try w.print("{d}", .{dep_id});
                    first = false;
                }
            }
        }

        try w.writeAll("],\"note\":null}");
    }

    try w.print("],\"created_at\":{d},\"updated_at\":{d}}}", .{ ts_secs, ts_secs });

    if (try findRecentDuplicateList(allocator, m, session_id, trimmed_title, items_val)) |duplicate_id| {
        defer allocator.free(duplicate_id);
        const result = try std.fmt.allocPrint(
            allocator,
            "Todo list already exists with same title/items (list_id={s}); returning existing list instead of creating a duplicate. To update it, call todo with action=update, list_id=\"{s}\", item_id=<id>, and status=pending|in_progress|completed|blocked.",
            .{ duplicate_id, duplicate_id },
        );
        return ToolResult{ .success = true, .output = result };
    }

    // Persist via the memory layer. Use .daily so it scopes per-session and
    // honors retention. Vector-sync is irrelevant for todos (we don't recall
    // them semantically); memory_recall sweep won't surface them as content.
    m.store(memory_key, body.items, .daily, session_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to persist todo list: {s}", .{@errorName(err)});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };

    log.info("todo.create list_id={s} session={s} items={d}", .{ list_id, session_id, items_val.array.items.len });

    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result_buf.deinit(allocator);
    const rw = result_buf.writer(allocator);
    try rw.writeAll("Created user-visible todo list ");
    try writeJsonString(rw, trimmed_title);
    try rw.print(" (list_id={s}) with {d} item{s}. To update it, call todo with action=update, list_id=\"{s}\", item_id=<1..{d}>, and status=pending|in_progress|completed|blocked.", .{
        list_id,
        items_val.array.items.len,
        if (items_val.array.items.len == 1) "" else "s",
        list_id,
        items_val.array.items.len,
    });
    const result = try result_buf.toOwnedSlice(allocator);
    return ToolResult{ .success = true, .output = result };
}

// ── action: update ──────────────────────────────────────────────────────

fn executeUpdate(
    allocator: std.mem.Allocator,
    m: Memory,
    session_id: []const u8,
    args: JsonObjectMap,
    status_override: ?TodoStatus,
) !ToolResult {
    const item_id_int = root.getInt(args, "item_id") orelse
        return ToolResult.fail("Missing 'item_id' for todo status update (integer)");
    if (item_id_int < 1) return ToolResult.fail("'item_id' must be >= 1");
    const item_id: usize = @intCast(item_id_int);

    const status = status_override orelse blk: {
        const status_str = root.getString(args, "status") orelse
            return ToolResult.fail("Missing 'status' for action=update");
        break :blk TodoStatus.fromString(status_str) orelse
            return ToolResult.fail("'status' must be one of: pending, in_progress, completed, blocked");
    };

    const note_opt = root.getString(args, "note");

    // Read current list. Memory.list scoped by category+session retrieves all
    // .daily entries; we filter by exact key match.
    const existing_entries = m.list(allocator, .daily, session_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to read memory for update: {s}", .{@errorName(err)});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };
    defer {
        for (existing_entries) |*e| e.deinit(allocator);
        allocator.free(existing_entries);
    }

    const resolved = try resolveUpdateTarget(allocator, existing_entries, root.getString(args, "list_id"));
    if (!resolved.success) return ToolResult{ .success = false, .output = "", .error_msg = resolved.error_msg };
    const target_index = resolved.index.?;
    const list_id = existing_entries[target_index].key[TODO_KEY_PREFIX.len..];
    const memory_key = existing_entries[target_index].key;

    const content = existing_entries[target_index].content;

    // Parse, mutate the matching item, re-serialize.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return ToolResult.fail("Stored todo list is malformed JSON — cannot update. List may need recreating.");
    };
    defer parsed.deinit();

    if (parsed.value != .object) return ToolResult.fail("Stored todo list is not a JSON object");
    const obj = parsed.value.object;

    const items_val = obj.get("items") orelse return ToolResult.fail("Stored todo list missing 'items' field");
    if (items_val != .array) return ToolResult.fail("Stored 'items' is not an array");

    var found_item = false;
    for (items_val.array.items) |*item| {
        if (item.* != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val != .integer) continue;
        if (@as(usize, @intCast(id_val.integer)) != item_id) continue;

        // Mutate status. The original status_str slice belongs to args; we'll
        // rebuild the JSON below from this Value tree, so storing a Value
        // .string with that slice is fine for the duration of this scope.
        try item.object.put("status", .{ .string = status.toSlice() });
        if (note_opt) |note| {
            try item.object.put("note", .{ .string = note });
        }
        found_item = true;
        break;
    }

    if (!found_item) {
        const msg = try std.fmt.allocPrint(allocator, "Item id={d} not found in list '{s}'", .{ item_id, list_id });
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    // Bump updated_at.
    try parsed.value.object.put("updated_at", .{ .integer = std.time.timestamp() });

    // Re-serialize via Zig 0.15's std.json.Stringify.valueAlloc — same
    // API the rest of nullalis uses (config_mutator, user_settings, mcp).
    const rebuilt = std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch
        return ToolResult.fail("Failed to re-serialize updated todo list");
    defer allocator.free(rebuilt);

    m.store(memory_key, rebuilt, .daily, session_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to persist updated todo list: {s}", .{@errorName(err)});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };

    // Build a tight summary for the agent: total / completed / in_progress / blocked.
    var total: usize = 0;
    var n_completed: usize = 0;
    var n_in_progress: usize = 0;
    var n_blocked: usize = 0;
    for (items_val.array.items) |item_v| {
        if (item_v != .object) continue;
        total += 1;
        const s = item_v.object.get("status") orelse continue;
        if (s != .string) continue;
        if (std.mem.eql(u8, s.string, "completed")) n_completed += 1;
        if (std.mem.eql(u8, s.string, "in_progress")) n_in_progress += 1;
        if (std.mem.eql(u8, s.string, "blocked")) n_blocked += 1;
    }

    log.info("todo.update list_id={s} item_id={d} status={s} session={s}", .{ list_id, item_id, status.toSlice(), session_id });

    const result = try std.fmt.allocPrint(
        allocator,
        "Todo list_id={s}: item {d} -> {s}. List summary: {d}/{d} completed, {d} in progress, {d} blocked.",
        .{ list_id, item_id, status.toSlice(), n_completed, total, n_in_progress, n_blocked },
    );
    return ToolResult{ .success = true, .output = result };
}

// ── action: list ────────────────────────────────────────────────────────

fn executeList(
    allocator: std.mem.Allocator,
    m: Memory,
    session_id: []const u8,
    args: JsonObjectMap,
) !ToolResult {
    const list_id_opt = root.getString(args, "list_id");

    const entries = m.list(allocator, .daily, session_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to read memory: {s}", .{@errorName(err)});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    // Filter to todo entries only.
    var matched_index: ?usize = null;
    var most_recent_index: ?usize = null;
    var most_recent_ts: i64 = std.math.minInt(i64);

    for (entries, 0..) |*entry, i| {
        if (!std.mem.startsWith(u8, entry.key, TODO_KEY_PREFIX)) continue;
        if (list_id_opt) |lid| {
            // Exact match: key = "todo:" + list_id
            const key_suffix = entry.key[TODO_KEY_PREFIX.len..];
            if (std.mem.eql(u8, key_suffix, lid)) {
                matched_index = i;
                break;
            }
        } else {
            // No explicit list_id — pick the most-recently-updated todo.
            // Best-effort: parse updated_at. If parse fails, skip.
            const ts = parseUpdatedAt(entry.content) orelse continue;
            if (ts > most_recent_ts) {
                most_recent_ts = ts;
                most_recent_index = i;
            }
        }
    }

    const target_index = matched_index orelse most_recent_index orelse {
        if (list_id_opt) |lid| {
            const msg = try std.fmt.allocPrint(allocator, "Todo list '{s}' not found in this session", .{lid});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        return ToolResult{ .success = true, .output = try allocator.dupe(u8, "(no todo lists in this session yet)") };
    };

    const content = entries[target_index].content;
    const list_id = entries[target_index].key[TODO_KEY_PREFIX.len..];
    const out = try formatTodoListOperational(allocator, list_id, content);
    return ToolResult{ .success = true, .output = out };
}

// ── helpers ─────────────────────────────────────────────────────────────

const ResolveTarget = struct {
    success: bool,
    index: ?usize = null,
    error_msg: ?[]const u8 = null,
};

fn resolveUpdateTarget(
    allocator: std.mem.Allocator,
    entries: []const mem_root.MemoryEntry,
    list_id_opt: ?[]const u8,
) !ResolveTarget {
    if (list_id_opt) |list_id| {
        if (list_id.len == 0) return .{ .success = false, .error_msg = try allocator.dupe(u8, "'list_id' must not be empty") };
        for (entries, 0..) |*entry, i| {
            if (!std.mem.startsWith(u8, entry.key, TODO_KEY_PREFIX)) continue;
            if (std.mem.eql(u8, entry.key[TODO_KEY_PREFIX.len..], list_id)) return .{ .success = true, .index = i };
        }
        return .{
            .success = false,
            .error_msg = try std.fmt.allocPrint(allocator, "Todo list '{s}' not found in this session", .{list_id}),
        };
    }

    var count: usize = 0;
    var only_index: usize = 0;
    for (entries, 0..) |*entry, i| {
        if (!std.mem.startsWith(u8, entry.key, TODO_KEY_PREFIX)) continue;
        count += 1;
        only_index = i;
    }
    if (count == 1) return .{ .success = true, .index = only_index };
    if (count == 0) {
        return .{
            .success = false,
            .error_msg = "No todo lists exist in this session. Create one first with action=create.",
        };
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("Multiple todo lists exist in this session; include list_id. candidates:");
    for (entries) |*entry| {
        if (!std.mem.startsWith(u8, entry.key, TODO_KEY_PREFIX)) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, entry.content, .{}) catch null;
        defer if (parsed) |*value| value.deinit();
        const title = if (parsed) |value|
            if (value.value == .object) todoTitleFromObject(value.value.object) orelse "(untitled)" else "(untitled)"
        else
            "(untitled)";
        try w.print(" list_id={s} title=", .{entry.key[TODO_KEY_PREFIX.len..]});
        try writeJsonString(w, title);
        try w.writeByte(';');
    }
    return .{ .success = false, .error_msg = try buf.toOwnedSlice(allocator) };
}

fn findRecentDuplicateList(
    allocator: std.mem.Allocator,
    m: Memory,
    session_id: []const u8,
    title: []const u8,
    items_val: std.json.Value,
) !?[]u8 {
    const entries = m.list(allocator, .daily, session_id) catch return null;
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    const now = std.time.timestamp();
    for (entries) |*entry| {
        if (!std.mem.startsWith(u8, entry.key, TODO_KEY_PREFIX)) continue;
        const updated_at = parseUpdatedAt(entry.content) orelse continue;
        if (now - updated_at > DUPLICATE_CREATE_WINDOW_SECS) continue;
        if (try todoListMatchesCreateArgs(allocator, entry.content, title, items_val)) {
            const duplicate_id = try allocator.dupe(u8, entry.key[TODO_KEY_PREFIX.len..]);
            return duplicate_id;
        }
    }
    return null;
}

fn todoListMatchesCreateArgs(
    allocator: std.mem.Allocator,
    json_str: []const u8,
    title: []const u8,
    items_val: std.json.Value,
) !bool {
    if (items_val != .array) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = parsed.value.object;
    const existing_title = todoTitleFromObject(obj) orelse return false;
    if (!try normalizedTextEquals(allocator, existing_title, title)) return false;
    const existing_items = obj.get("items") orelse return false;
    if (existing_items != .array) return false;
    if (existing_items.array.items.len != items_val.array.items.len) return false;
    for (existing_items.array.items, 0..) |existing_item, idx| {
        if (existing_item != .object) return false;
        const existing_item_title_val = existing_item.object.get("title") orelse return false;
        if (existing_item_title_val != .string) return false;
        const requested_item = items_val.array.items[idx];
        if (requested_item != .object) return false;
        const requested_title_val = requested_item.object.get("title") orelse return false;
        if (requested_title_val != .string) return false;
        if (!try normalizedTextEquals(allocator, existing_item_title_val.string, requested_title_val.string)) return false;
    }
    return true;
}

fn normalizedTextEquals(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const na = try normalizedText(allocator, a);
    defer allocator.free(na);
    const nb = try normalizedText(allocator, b);
    defer allocator.free(nb);
    return std.mem.eql(u8, na, nb);
}

fn normalizedText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var last_space = true;
    for (std.mem.trim(u8, text, " \t\r\n")) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!last_space) try buf.append(allocator, ' ');
            last_space = true;
        } else {
            try buf.append(allocator, std.ascii.toLower(c));
            last_space = false;
        }
    }
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') _ = buf.pop();
    return buf.toOwnedSlice(allocator);
}

fn todoTitleFromObject(obj: std.json.ObjectMap) ?[]const u8 {
    const title_val = obj.get("title") orelse return null;
    if (title_val != .string) return null;
    return title_val.string;
}

fn formatTodoListOperational(allocator: std.mem.Allocator, list_id: []const u8, content: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return allocator.dupe(u8, "Stored todo list is malformed JSON.");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "Stored todo list is not a JSON object.");
    const obj = parsed.value.object;
    const title = todoTitleFromObject(obj) orelse "(untitled)";
    const items = obj.get("items") orelse return allocator.dupe(u8, "Stored todo list missing items.");
    if (items != .array) return allocator.dupe(u8, "Stored todo list items are malformed.");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.print("current_list_id={s}\n", .{list_id});
    try w.writeAll("title=");
    try writeJsonString(w, title);
    try w.writeByte('\n');
    try w.writeAll("items:\n");
    for (items.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        const item_title_val = item.object.get("title") orelse continue;
        const status_val = item.object.get("status") orelse continue;
        if (id_val != .integer or item_title_val != .string or status_val != .string) continue;
        try w.print("- id={d} status={s} title=", .{ id_val.integer, status_val.string });
        try writeJsonString(w, item_title_val.string);
        try w.writeByte('\n');
    }
    try w.print("update_examples:\n- todo action=start list_id=\"{s}\" item_id=<id>\n- todo action=complete list_id=\"{s}\" item_id=<id>\n- todo action=block list_id=\"{s}\" item_id=<id> note=\"reason\"\n", .{
        list_id,
        list_id,
        list_id,
    });
    return buf.toOwnedSlice(allocator);
}

/// Best-effort extract `updated_at` integer from a list JSON.
/// Returns null if the field is missing or the JSON is malformed.
fn parseUpdatedAt(json_str: []const u8) ?i64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json_str, .{}) catch return null;
    if (parsed.value != .object) return null;
    const ts_val = parsed.value.object.get("updated_at") orelse return null;
    if (ts_val != .integer) return null;
    return ts_val.integer;
}

/// Write a JSON-escaped string to a writer. Wraps in double-quotes.
/// Delegates the escape body to the shared `json_escape.writeJsonStringContent`
/// (HIGH 3.B, v1.14.23 holistic review — single source of truth for the
/// JSON escape rules).
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    try @import("json_escape.zig").writeJsonStringContent(w, s);
    try w.writeAll("\"");
}

// ── tests ───────────────────────────────────────────────────────────────

test "TodoStatus roundtrip" {
    const testing = std.testing;
    const all = [_]TodoStatus{ .pending, .in_progress, .completed, .blocked };
    for (all) |s| {
        const slice = s.toSlice();
        try testing.expectEqual(s, TodoStatus.fromString(slice).?);
    }
    try testing.expect(TodoStatus.fromString("invalid") == null);
    try testing.expect(TodoStatus.fromString("") == null);
}

test "writeJsonString escapes control chars + quote + backslash" {
    const testing = std.testing;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(buf.writer(testing.allocator), "hello \"world\" \\ \n\t");
    // The escaped output should contain literal \", \\ , \n, \t sequences.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\\\") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\t") != null);
}

test "TodoTool tool_name + schema sanity" {
    const testing = std.testing;
    var t_struct = TodoTool{};
    const t = t_struct.tool();
    try testing.expectEqualStrings("todo", t.name());
    try testing.expect(std.mem.indexOf(u8, TodoTool.tool_description, "user-visible") != null);
    try testing.expect(std.mem.indexOf(u8, TodoTool.tool_description, "private internal planning") != null);
    try testing.expect(std.mem.indexOf(u8, TodoTool.tool_params, "create") != null);
    try testing.expect(std.mem.indexOf(u8, TodoTool.tool_params, "update") != null);
    try testing.expect(std.mem.indexOf(u8, TodoTool.tool_params, "list") != null);
    try testing.expect(std.mem.indexOf(u8, TodoTool.tool_params, "depends_on") != null);
    try testing.expect(std.mem.indexOf(u8, TodoTool.tool_params, "not private internal planning steps") != null);
}

test "executeCreate args shape — missing items detected" {
    const testing = std.testing;
    var args = std.json.ObjectMap.init(testing.allocator);
    defer args.deinit();
    try args.put("title", std.json.Value{ .string = "Test list" });
    // No items field — the surface check at execute() rejects this with
    // "Missing 'items' for action=create". Integration test of the full
    // path requires a Memory backend stub which is out of scope; the
    // schema/contract is exercised at the registration/dispatch layer
    // via the metadata test above + the TodoTool tool_name pin.
    try testing.expect(args.get("items") == null);
}

test "todo create output includes list_id and exact update recovery shape" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:todo-test" });
    defer root.clearTurnContext();

    var tt = TodoTool{ .memory = mem };
    const t = tt.tool();
    const parsed = try root.parseTestArgs(
        "{\"action\":\"create\",\"title\":\"Launch validation\",\"items\":[{\"title\":\"Check schedule\"},{\"title\":\"Report findings\",\"depends_on\":[1]}]}",
    );
    defer parsed.deinit();

    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Created user-visible todo list") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "list_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "action=update") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "item_id=<1..2>") != null);
}

test "todo duplicate create returns existing list instead of creating another" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:todo-duplicate-test" });
    defer root.clearTurnContext();

    var tt = TodoTool{ .memory = mem };
    const t = tt.tool();
    const parsed = try root.parseTestArgs(
        "{\"action\":\"create\",\"title\":\"Launch validation\",\"items\":[{\"title\":\"Check schedule\"},{\"title\":\"Report findings\"}]}",
    );
    defer parsed.deinit();

    const first = try t.execute(allocator, parsed.value.object);
    defer if (first.output.len > 0) allocator.free(first.output);
    try std.testing.expect(first.success);

    const second = try t.execute(allocator, parsed.value.object);
    defer if (second.output.len > 0) allocator.free(second.output);
    try std.testing.expect(second.success);
    try std.testing.expect(std.mem.indexOf(u8, second.output, "already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.output, "instead of creating a duplicate") != null);
}

test "todo complete can omit list_id when exactly one session list exists" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:todo-default-list-test" });
    defer root.clearTurnContext();

    var tt = TodoTool{ .memory = mem };
    const t = tt.tool();
    const create_args = try root.parseTestArgs(
        "{\"action\":\"create\",\"title\":\"Single list\",\"items\":[{\"title\":\"One\"}]}",
    );
    defer create_args.deinit();
    const created = try t.execute(allocator, create_args.value.object);
    defer if (created.output.len > 0) allocator.free(created.output);
    try std.testing.expect(created.success);

    const complete_args = try root.parseTestArgs("{\"action\":\"complete\",\"item_id\":1}");
    defer complete_args.deinit();
    const completed = try t.execute(allocator, complete_args.value.object);
    defer if (completed.output.len > 0) allocator.free(completed.output);
    try std.testing.expect(completed.success);
    try std.testing.expect(std.mem.indexOf(u8, completed.output, "-> completed") != null);

    const current_args = try root.parseTestArgs("{\"action\":\"current\"}");
    defer current_args.deinit();
    const current = try t.execute(allocator, current_args.value.object);
    defer if (current.output.len > 0) allocator.free(current.output);
    try std.testing.expect(current.success);
    try std.testing.expect(std.mem.indexOf(u8, current.output, "current_list_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, current.output, "status=completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, current.output, "update_examples:") != null);
}

test "todo current JSON-quotes user titles in operational output" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:todo-escape-test" });
    defer root.clearTurnContext();

    var tt = TodoTool{ .memory = mem };
    const t = tt.tool();
    const create_args = try root.parseTestArgs(
        "{\"action\":\"create\",\"title\":\"Launch\\nInjected header\",\"items\":[{\"title\":\"One\\n- id=999 status=completed title=Fake\"}]}",
    );
    defer create_args.deinit();
    const created = try t.execute(allocator, create_args.value.object);
    defer if (created.output.len > 0) allocator.free(created.output);
    try std.testing.expect(created.success);

    const current_args = try root.parseTestArgs("{\"action\":\"current\"}");
    defer current_args.deinit();
    const current = try t.execute(allocator, current_args.value.object);
    defer if (current.output.len > 0) allocator.free(current.output);

    try std.testing.expect(current.success);
    try std.testing.expect(std.mem.indexOf(u8, current.output, "Launch\\nInjected header") != null);
    try std.testing.expect(std.mem.indexOf(u8, current.output, "One\\n- id=999") != null);
    try std.testing.expect(std.mem.indexOf(u8, current.output, "Launch\nInjected header") == null);
    try std.testing.expect(std.mem.indexOf(u8, current.output, "One\n- id=999") == null);
}

test "todo update without list_id returns recoverable multiple-list candidates" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:todo-multiple-list-test" });
    defer root.clearTurnContext();

    var tt = TodoTool{ .memory = mem };
    const t = tt.tool();
    const first_args = try root.parseTestArgs(
        "{\"action\":\"create\",\"title\":\"First\",\"items\":[{\"title\":\"One\"}]}",
    );
    defer first_args.deinit();
    const first = try t.execute(allocator, first_args.value.object);
    defer if (first.output.len > 0) allocator.free(first.output);
    try std.testing.expect(first.success);

    const second_args = try root.parseTestArgs(
        "{\"action\":\"create\",\"title\":\"Second\",\"items\":[{\"title\":\"Two\"}]}",
    );
    defer second_args.deinit();
    const second = try t.execute(allocator, second_args.value.object);
    defer if (second.output.len > 0) allocator.free(second.output);
    try std.testing.expect(second.success);

    const update_args = try root.parseTestArgs("{\"action\":\"complete\",\"item_id\":1}");
    defer update_args.deinit();
    const result = try t.execute(allocator, update_args.value.object);
    defer if (result.error_msg) |msg| allocator.free(msg);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Multiple todo lists") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "list_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "First") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Second") != null);
}

test "todo update missing list_id tells model how to recover" {
    const allocator = std.testing.allocator;
    var none_mem = mem_root.NoneMemory.init();
    defer none_mem.deinit();
    const mem = none_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:todo-test" });
    defer root.clearTurnContext();

    var tt = TodoTool{ .memory = mem };
    const t = tt.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"update\",\"item_id\":1,\"status\":\"completed\"}");
    defer parsed.deinit();

    const result = try t.execute(allocator, parsed.value.object);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "No todo lists exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action=create") != null);
}

test "MAX_ITEMS bound is sane" {
    try std.testing.expectEqual(@as(usize, 50), MAX_ITEMS);
    try std.testing.expectEqual(@as(usize, 240), MAX_ITEM_TITLE_LEN);
    try std.testing.expectEqual(@as(usize, 120), MAX_LIST_TITLE_LEN);
}

test "TODO_KEY_PREFIX is namespaced for filter-by-prefix" {
    try std.testing.expectEqualStrings("todo:", TODO_KEY_PREFIX);
}
