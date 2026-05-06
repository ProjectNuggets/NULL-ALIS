//! Tools module — agent tool integrations for LLM function calling.
//!
//! Provides a common Tool vtable, ToolResult/ToolSpec types, and implementations
//! for shell execution, file I/O, HTTP requests, git operations, memory tools,
//! scheduling, delegation, browser, and image tools.

const std = @import("std");
const build_options = @import("build_options");
const bus = @import("../bus.zig");
const memory_mod = @import("../memory/root.zig");
const zaki_state = @import("../zaki_state.zig");
const observability = @import("../observability.zig");
const entitlement_mod = @import("../entitlement.zig");
const Memory = memory_mod.Memory;

pub const Entitlement = entitlement_mod.Entitlement;

// ── JSON arg extraction helpers ─────────────────────────────────
// Used by all tool implementations to extract typed fields from
// the pre-parsed ObjectMap passed by the dispatcher.

pub const JsonObjectMap = std.json.ObjectMap;
pub const JsonValue = std.json.Value;

pub fn getString(args: JsonObjectMap, key: []const u8) ?[]const u8 {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(args: JsonObjectMap, key: []const u8) ?bool {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getInt(args: JsonObjectMap, key: []const u8) ?i64 {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

pub fn getValue(args: JsonObjectMap, key: []const u8) ?JsonValue {
    return args.get(key);
}

/// Return the items of a JSON array argument, or null if the key is absent or not an array.
pub fn getArray(args: JsonObjectMap, key: []const u8) ?[]const JsonValue {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .array => |a| a.items,
        else => null,
    };
}

/// Test helper: parse a JSON string into a Parsed(Value) for use in tool tests.
/// The caller must `defer parsed.deinit()` and extract `.value.object` for the ObjectMap.
pub fn parseTestArgs(json_str: []const u8) !std.json.Parsed(JsonValue) {
    return std.json.parseFromSlice(JsonValue, std.testing.allocator, json_str, .{});
}

// Sub-modules
pub const metadata = @import("metadata.zig");
pub const shell = @import("shell.zig");
pub const file_read = @import("file_read.zig");
pub const file_write = @import("file_write.zig");
pub const file_edit = @import("file_edit.zig");
pub const http_request = @import("http_request.zig");
pub const git = @import("git.zig");
pub const memory_store = @import("memory_store.zig");
pub const memory_edit = @import("memory_edit.zig");
pub const memory_recall = @import("memory_recall.zig");
pub const memory_list = @import("memory_list.zig");
pub const memory_timeline = @import("memory_timeline.zig");
pub const transcript_read = @import("transcript_read.zig");
pub const memory_forget = @import("memory_forget.zig");
pub const memory_archive = @import("memory_archive.zig");
pub const memory_demote = @import("memory_demote.zig");
pub const memory_purge_topic = @import("memory_purge_topic.zig");
pub const memory_maintain = @import("memory_maintain.zig");
pub const time_now = @import("time_now.zig");
pub const schedule = @import("schedule.zig");
pub const todo = @import("todo.zig");
pub const compose_memory = @import("compose_memory.zig");
pub const brain_graph = @import("brain_graph.zig");
pub const delegate = @import("delegate.zig");
pub const browser = @import("browser.zig");
pub const image = @import("image.zig");
pub const image_generate = @import("image_generate.zig");
pub const composio = @import("composio.zig");
/// **D1.14** generalized tool-result cache. Tools opt in via
/// `ToolMetadata.flags.cacheable + cache_ttl_secs`. Module is
/// imported here so its 6 unit tests run with the rest of the suite.
pub const result_cache = @import("result_cache.zig");
pub const skill_registry = @import("skill_registry.zig");
pub const runtime_info = @import("runtime_info.zig");
pub const screenshot = @import("screenshot.zig");
pub const browser_open = @import("browser_open.zig");
pub const cron_add = @import("cron_add.zig");
pub const cron_list = @import("cron_list.zig");
pub const cron_remove = @import("cron_remove.zig");
pub const cron_runs = @import("cron_runs.zig");
pub const cron_run = @import("cron_run.zig");
pub const cron_update = @import("cron_update.zig");
pub const message = @import("message.zig");
pub const pushover = @import("pushover.zig");
pub const schema = @import("schema.zig");
pub const web_search = @import("web_search.zig");
pub const web_fetch = @import("web_fetch.zig");
pub const file_append = @import("file_append.zig");
pub const spawn = @import("spawn.zig");
pub const task_list = @import("task_list.zig");
pub const task_get = @import("task_get.zig");
pub const task_stop = @import("task_stop.zig");
pub const path_security = @import("path_security.zig");
pub const process_util = @import("process_util.zig");
pub const set_execution_mode = @import("set_execution_mode.zig");
pub const context_snapshot = @import("context_snapshot.zig");
pub const calculator = @import("calculator.zig");
pub const file_read_hashed = @import("file_read_hashed.zig");
pub const file_edit_hashed = @import("file_edit_hashed.zig");

// ── Core types ──────────────────────────────────────────────────────

/// Result of a tool execution.
///
/// Ownership: both `output` and `error_msg` are owned by the tool that produced them.
/// The caller (agent/dispatcher) must free them with `allocator.free()` after use.
/// Exception: static string literals (e.g. `""`, compile-time constants) must NOT be freed —
/// use `ToolResult.ok("")` or `ToolResult.fail("literal")` for those.
pub const ToolResult = struct {
    success: bool,
    /// Heap-allocated output string owned by caller. Free with allocator.free().
    /// May be an empty literal "" for void results — do NOT free in that case.
    output: []const u8,
    /// Heap-allocated error message owned by caller if non-null. Free with allocator.free().
    error_msg: ?[]const u8 = null,

    /// Create a success result with a static/literal output (do NOT free).
    pub fn ok(output: []const u8) ToolResult {
        return .{ .success = true, .output = output };
    }

    /// Create a failure result with a static/literal error message (do NOT free).
    pub fn fail(err: []const u8) ToolResult {
        return .{ .success = false, .output = "", .error_msg = err };
    }
};

/// Description of a tool for the LLM (function calling schema)
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

/// Tool vtable — implement for any capability.
/// Uses Zig's type-erased interface pattern.
pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult,
        name: *const fn (ptr: *anyopaque) []const u8,
        description: *const fn (ptr: *anyopaque) []const u8,
        parameters_json: *const fn (ptr: *anyopaque) []const u8,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub fn execute(self: Tool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        return self.vtable.execute(self.ptr, allocator, args);
    }

    pub fn name(self: Tool) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn description(self: Tool) []const u8 {
        return self.vtable.description(self.ptr);
    }

    pub fn parametersJson(self: Tool) []const u8 {
        return self.vtable.parameters_json(self.ptr);
    }

    pub fn spec(self: Tool) ToolSpec {
        return .{
            .name = self.name(),
            .description = self.description(),
            .parameters_json = self.parametersJson(),
        };
    }

    /// Free the heap-allocated backing struct. Safe to call even if
    /// the tool was not heap-allocated (deinit will be null).
    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self.ptr, allocator);
        }
    }
};

/// Generate a Tool.VTable from a tool struct type at comptime.
///
/// The type T must declare:
///   - `pub const tool_name: []const u8`
///   - `pub const tool_description: []const u8`
///   - `pub const tool_params: []const u8`
///   - `fn execute(self: *T, allocator: Allocator, args: JsonObjectMap) anyerror!ToolResult`
pub fn ToolVTable(comptime T: type) Tool.VTable {
    return .{
        .execute = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.execute(allocator, args);
            }
        }.f,
        .name = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_name;
            }
        }.f,
        .description = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_description;
            }
        }.f,
        .parameters_json = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_params;
            }
        }.f,
        .deinit = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                allocator.destroy(self);
            }
        }.f,
    };
}

/// Comptime check that a type correctly implements the Tool interface.
pub fn assertToolInterface(comptime T: type) void {
    if (!@hasDecl(T, "tool")) @compileError(@typeName(T) ++ " missing tool() method");
    if (!@hasDecl(T, "vtable")) @compileError(@typeName(T) ++ " missing vtable constant");
    const vt = T.vtable;
    _ = vt.execute;
    _ = vt.name;
    _ = vt.description;
    _ = vt.parameters_json;
}

// ── Default tool metadata registry ──────────────────────────────────
//
// Classifications for built-in tools created by `defaultToolsWithPaths` and
// `allTools`. Used by agent preflight to gate tool dispatch per ExecutionMode.
// Action-dependent tools (schedule, composio, git, http, browser,
// skill_registry) are classified conservatively here; finer arg-aware policy
// lives in `toolBlockedForCurrentTurn` and future approval layers.
// Unknown/MCP/dynamic tools fall back to `ToolMetadata.conservative`.
// cost_class billing classification per plan-v02 §4.4 (S2.9).
//   .a = cheap (local read, status, memory op, schedule metadata op)
//   .b = medium (external HTTP, small payload, light compute) — DEFAULT
//   .c = expensive (image gen, voice synth, subagent spawn, full browser,
//        arbitrary outbound HTTP, Composio execute with potentially large
//        third-party payloads)
// Intent is nominal — concrete $ translation lives on the entitlement side.
const DEFAULT_TOOL_METADATA = [_]metadata.ToolMetadata{
    // Read-only, safe in plan/review/background
    .{
        .name = runtime_info.RuntimeInfoTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = file_read.FileReadTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // D1.14c — cacheable. Same session re-asks the same question
        // (e.g. "what did I do yesterday") frequently in multi-turn
        // chat. 300s TTL covers continuation without missing fresh
        // user-stored facts beyond ~5min. Scope = .session because
        // memory state is per-session — never cross-key.
        .name = memory_recall.MemoryRecallTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true, .cacheable = true },
        .risk_level = .low,
        .cost_class = .a,
        .cache_ttl_secs = 300,
        .cache_scope = .session,
    },
    .{
        .name = memory_list.MemoryListTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = memory_timeline.MemoryTimelineTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = transcript_read.TranscriptReadTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // Paid search provider (Brave/Serper/etc.) — medium cost per call.
        // D1.14c — cacheable. No auth, no personalization → scope =
        // .global (cross-session sharing safe). 30s TTL — short enough
        // that fresh-results expectations hold for time-sensitive queries
        // (news, market data) but long enough that the agent's
        // multi-turn refinement on the same query (e.g. follow-up
        // questions about the same topic) hits cache.
        .name = web_search.WebSearchTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true, .cacheable = true },
        .risk_level = .low,
        .cost_class = .b,
        .cache_ttl_secs = 30,
        .cache_scope = .global,
    },
    .{
        // External HTTP fetch with up to 1MB response — medium cost.
        .name = web_fetch.WebFetchTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .medium,
        .cost_class = .b,
    },
    .{
        .name = task_list.TaskListTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = task_get.TaskGetTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },

    // Read-only, NOT background_safe (side channels, hardware, or sensitive output)
    .{
        .name = image.ImageInfoTool.tool_name,
        .flags = .{ .read_only = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    // image_generate: side-effectful (writes to external API, returns URL).
    // Not read_only, not background_safe (user-initiated action), low risk.
    // Together FLUX costs $0.003+ per call — expensive tier.
    .{
        .name = image_generate.ImageGenerateTool.tool_name,
        .flags = .{ .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .c,
    },
    .{
        .name = cron_list.CronListTool.tool_name,
        .flags = .{ .read_only = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = cron_runs.CronRunsTool.tool_name,
        .flags = .{ .read_only = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // Read-only, but medium risk because it can expose screen contents.
        // Local capture — cheap tier.
        .name = screenshot.ScreenshotTool.tool_name,
        .flags = .{ .read_only = true },
        .risk_level = .medium,
        .cost_class = .a,
    },

    // Mutating / side-effecting — never allowed in plan/review, never background_safe
    .{
        // Local shell — medium cost on average (long-running commands vary).
        .name = shell.ShellTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .critical,
        .cost_class = .b,
    },
    .{
        .name = file_write.FileWriteTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        .name = file_edit.FileEditTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        .name = file_append.FileAppendTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        // Action-dependent: some git subcommands are read-only, but the tool
        // as a whole can mutate the working tree and remotes. Conservative.
        // Network ops (push/fetch) make this medium cost.
        .name = git.GitTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .high,
        .cost_class = .b,
    },
    .{
        .name = memory_store.MemoryStoreTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = memory_edit.MemoryEditTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = memory_forget.MemoryForgetTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // Topic-scoped bulk purge of agent-generated artifacts. Mutating;
        // medium risk because an ill-chosen topic could delete more than
        // intended (heuristic protects against overly-short topics).
        // Local DB scan + delete — medium cost depending on scope.
        .name = memory_purge_topic.MemoryPurgeTopicTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .b,
    },
    .{
        // V1.9-5 — unified truth-maintenance toolkit. Six actions:
        // cascade_update / invalidate_when / resolve_contradiction /
        // propagate_correction / temporal_decay / survey. Mutating
        // (every action except `survey` rewrites graph state);
        // medium risk because a wrong predicate or pattern could
        // mass-close edges. Cost class b: per-action SQL UPDATEs
        // bounded by edge count or matched memory rows.
        .name = memory_maintain.MemoryMaintainTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .b,
    },
    .{
        // V1.9-DX1 — wall-clock awareness. Read-only, low risk,
        // tiny cost. Pairs with memory_maintain action=temporal_decay
        // for honest age reasoning.
        .name = time_now.TimeNowTool.tool_name,
        .flags = .{},
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // Schedule has read-only actions (list/get/runs) but the tool as a
        // whole mutates durable jobs. Arg-aware policy lives elsewhere.
        .name = schedule.ScheduleTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        // V1.5 todo tool — same shape as schedule (list/get is read-only
        // but the tool as a whole mutates persisted lists). Per-session
        // scope; cost is local memory writes only.
        .name = todo.TodoTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // V1.5 day-3 compose_memory tool — synthesizes 2+ existing
        // memories into one consolidated fact with provenance metadata.
        // Mutating (writes a new memory), but cost is a single memory
        // write + 1 memory_event row. Risk low: bounded inputs +
        // dangling references are filtered at /brain/graph render time.
        .name = compose_memory.ComposeMemoryTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // V1.7-ship S2a — read-only graph navigation tool. Wraps
        // V1.7a-Obsidian-parity primitives (local_graph, communities,
        // orphans, diff). No writes; one or two PG round trips per
        // call; bounded payloads. Safe + cheap.
        .name = brain_graph.BrainGraphTool.tool_name,
        .flags = .{},
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        // Spawns a full subagent turn — potentially many LLM calls + tools.
        .name = delegate.DelegateTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .high,
        .cost_class = .c,
    },
    .{
        // Spawns a long-running task — same reasoning as delegate.
        .name = spawn.SpawnTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .high,
        .cost_class = .c,
    },
    .{
        // External channel send — medium (Telegram/Slack/WhatsApp APIs).
        .name = message.MessageTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .b,
    },
    .{
        .name = pushover.PushoverTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .b,
    },
    .{
        .name = cron_add.CronAddTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        .name = cron_remove.CronRemoveTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        .name = cron_update.CronUpdateTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        // Ad-hoc job run triggers agent_runner — potentially heavy.
        .name = cron_run.CronRunTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .c,
    },
    .{
        // Arbitrary outbound HTTP — unknown payload size. Treat as expensive.
        .name = http_request.HttpRequestTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .high,
        .cost_class = .c,
    },
    .{
        // Full browser session — heavy.
        .name = browser.BrowserTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .c,
    },
    .{
        // Local open URL — cheap.
        .name = browser_open.BrowserOpenTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        // Composio is action-dependent: list/get are read-only but execute
        // can mutate third-party state. Conservative here; background policy
        // handles the read-only execute whitelist for proactive turns.
        // Third-party API calls, large payloads possible — expensive tier.
        .name = composio.ComposioTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .high,
        .cost_class = .c,
    },
    .{
        .name = skill_registry.SkillRegistryTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },
    .{
        .name = task_stop.TaskStopTool.tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    },

    // Self-control & self-inspection — read-only, allowed in every mode
    // including background (so background turns can still snapshot/plan).
    // `set_execution_mode` is concurrency_safe=false so it's never parallel-
    // dispatched alongside tools that would observe the old mode mid-batch.
    .{
        .name = set_execution_mode.SetExecutionModeTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = false },
        .risk_level = .low,
        .cost_class = .a,
    },
    .{
        .name = context_snapshot.ContextSnapshotTool.tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    },
};

/// Return the static default metadata registry for built-in tools.
/// Callers must still fall back to `ToolMetadata.conservative(name)` when
/// `lookupMetadata` returns null (MCP tools, dynamic tools, future additions).
///
/// S6.3 — delegate/spawn entries are kept in `DEFAULT_TOOL_METADATA` but
/// filtered out at lookup time when `NULLALIS_ENABLE_MULTIAGENT` is not set
/// to "1". Runtime tool registration at `buildDefaultTools` already gates
/// the tool instances behind the same env; without this filter the metadata
/// registry claimed classification for tools that weren't installed, which
/// confused `classifyTool` callers when a model hallucinated a `delegate`
/// call-by-name.
pub fn defaultMetadataRegistry() []const metadata.ToolMetadata {
    if (multiagentEnabledEnv()) return &DEFAULT_TOOL_METADATA;
    return &CORE_TOOL_METADATA;
}

/// Read `NULLALIS_ENABLE_MULTIAGENT` from the process env. Returns true
/// only for exact value "1" (allows whitespace trim). Mirrors the gate at
/// `buildDefaultTools` so metadata stays in lockstep with registration.
///
/// Post-review fix (MED-3 from sprint-4-5-6-review): cache the result
/// in a module-scoped atomic so the answer is determined once per
/// process. Without the cache the registry reader and the runtime-tool
/// registration reader could in principle disagree if third-party code
/// inside the process called `setenv()` between them. Nullalis doesn't
/// setenv today, but the drift would be invisible and hard to debug —
/// first-reader-wins is cheap insurance.
///
/// Encoding: 0 = unread (first caller populates), 1 = false, 2 = true.
/// Acquire-release ordering keeps the string-read visible before the
/// cache transitions out of 0.
var multiagent_env_cache: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

fn multiagentEnabledEnv() bool {
    const cached = multiagent_env_cache.load(.acquire);
    if (cached != 0) return cached == 2;

    // First caller performs the actual env read. 16-byte FBA is enough for
    // realistic values ("0" / "1" / "true" / "false"); longer values fall
    // through to `catch return false` which is semantically correct (fail
    // closed on multiagent when we can't confirm the enable flag).
    var fba_buf: [16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const allocator = fba.allocator();
    const enabled = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "NULLALIS_ENABLE_MULTIAGENT") catch break :blk false;
        defer allocator.free(raw);
        break :blk std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "1");
    };

    // Racy first-write is fine: two first-readers would write the same
    // value (env didn't change between their reads). compareAndSwap from
    // 0 ensures we don't clobber an answer that somebody else may have
    // already stored + read.
    _ = multiagent_env_cache.cmpxchgStrong(0, if (enabled) 2 else 1, .release, .monotonic);
    return enabled;
}

/// Test helper — clear the multiagent env cache. Only call from tests
/// that deliberately want to re-read the env. Production code should
/// never invalidate this cache.
pub fn resetMultiagentEnvCacheForTest() void {
    multiagent_env_cache.store(0, .release);
}

/// Core metadata slice — `DEFAULT_TOOL_METADATA` minus delegate + spawn.
/// Computed at comptime; no runtime allocation. Kept in sync with the
/// runtime filter in `defaultMetadataRegistry` — if you add a new
/// multiagent-gated tool, it needs to be excluded here too.
const CORE_TOOL_METADATA = blk: {
    var out: [DEFAULT_TOOL_METADATA.len]metadata.ToolMetadata = undefined;
    var count: usize = 0;
    for (DEFAULT_TOOL_METADATA) |m| {
        if (std.mem.eql(u8, m.name, delegate.DelegateTool.tool_name)) continue;
        if (std.mem.eql(u8, m.name, spawn.SpawnTool.tool_name)) continue;
        out[count] = m;
        count += 1;
    }
    break :blk out[0..count].*;
};

// ── Args-aware metadata refinement ──────────────────────────────────
//
// A handful of built-in tools dispatch on an `action`/`operation`/`method`
// field whose value flips the call between read-only and mutating semantics.
// `refineMetadata` is a central switch that inspects those args and
// downgrades the base (conservative) metadata to read-only when the
// specific call is known to be side-effect-free.
//
// Keeping this logic centralised (rather than per-tool `classifyArgs`) so
// the audit surface lives beside the static registry. Tools whose arg
// parsing grows more complex should migrate to a comptime hook instead of
// growing this switch.

fn isReadOnlyGitOperation(args: JsonObjectMap) bool {
    const op = getString(args, "operation") orelse return false;
    // Purely inspecting operations. `stash` mutates; `add/commit/checkout` mutate.
    return std.ascii.eqlIgnoreCase(op, "status") or
        std.ascii.eqlIgnoreCase(op, "diff") or
        std.ascii.eqlIgnoreCase(op, "log") or
        std.ascii.eqlIgnoreCase(op, "branch");
}

fn isReadOnlyHttpMethod(args: JsonObjectMap) bool {
    const method = getString(args, "method") orelse "GET";
    return std.ascii.eqlIgnoreCase(method, "GET") or
        std.ascii.eqlIgnoreCase(method, "HEAD") or
        std.ascii.eqlIgnoreCase(method, "OPTIONS");
}

fn isReadOnlySkillRegistryAction(args: JsonObjectMap) bool {
    const action = getString(args, "action") orelse "list";
    return std.ascii.eqlIgnoreCase(action, "list") or std.ascii.eqlIgnoreCase(action, "search");
}

fn isReadOnlyComposioCall(args: JsonObjectMap) bool {
    const action = getString(args, "action") orelse "execute";
    if (std.ascii.eqlIgnoreCase(action, "list") or std.ascii.eqlIgnoreCase(action, "get")) return true;
    if (!std.ascii.eqlIgnoreCase(action, "execute")) return false;
    return isReadOnlyComposioExecute(args);
}

/// Look up base metadata for a tool by name using the default registry.
/// Returns a conservative `mutating=true / risk=high` entry when the name is
/// unknown (MCP/dynamic tools). This is the one-step lookup used by reporting
/// paths that do not have parsed arguments on hand.
///
/// Callers that have `arguments_json` should prefer `canonicalMetadataForCall`
/// so that args-aware refinement (e.g. `git status` downgrading to read-only)
/// matches the runtime preflight decision.
pub fn canonicalMetadataForName(tool_name: []const u8) metadata.ToolMetadata {
    return metadata.lookupMetadata(tool_name, defaultMetadataRegistry()) orelse
        metadata.ToolMetadata.conservative(tool_name);
}

/// Canonical tool-metadata resolver for a specific call (name + arguments).
///
/// This is the single source of truth for how a tool invocation maps to
/// `ToolMetadata` before policy gates consult it. It performs:
///   1. Registry lookup (`defaultMetadataRegistry`).
///   2. Conservative fallback for unknown names.
///   3. Args-aware refinement via `refineMetadata` (downgrades known
///      read-only dispatch arguments like `schedule.list`, `git status`,
///      HTTP GET, etc.).
///
/// Any runtime gate that classifies tools — agent preflight, `/permissions`
/// reporting, SecurityPolicy.resolveApproval callers — must route through
/// this helper (or its name-only counterpart) so they cannot disagree.
/// Parse failures or non-object payloads fall back to the base metadata,
/// mirroring the conservative posture of the preflight path.
pub fn canonicalMetadataForCall(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments_json: []const u8,
) metadata.ToolMetadata {
    const base = canonicalMetadataForName(tool_name);
    if (base.flags.read_only) return base;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch return base;
    defer parsed.deinit();
    const args_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return base,
    };
    return refineMetadata(base, args_obj);
}

/// Downgrade a base metadata entry to read-only when the specific call's
/// arguments indicate a side-effect-free operation. Returns the base
/// metadata unchanged when the call is mutating or the tool is not
/// action-dependent.
///
/// The returned metadata is NOT marked background_safe — action-dependent
/// tools must be explicitly whitelisted for the background lane (see
/// `toolBlockedForCurrentTurn`).
pub fn refineMetadata(base: metadata.ToolMetadata, args: JsonObjectMap) metadata.ToolMetadata {
    if (base.flags.read_only) return base;

    const is_read_only = blk: {
        if (std.mem.eql(u8, base.name, schedule.ScheduleTool.tool_name)) break :blk isReadOnlyScheduleAction(args);
        if (std.mem.eql(u8, base.name, composio.ComposioTool.tool_name)) break :blk isReadOnlyComposioCall(args);
        if (std.mem.eql(u8, base.name, git.GitTool.tool_name)) break :blk isReadOnlyGitOperation(args);
        if (std.mem.eql(u8, base.name, http_request.HttpRequestTool.tool_name)) break :blk isReadOnlyHttpMethod(args);
        if (std.mem.eql(u8, base.name, skill_registry.SkillRegistryTool.tool_name)) break :blk isReadOnlySkillRegistryAction(args);
        if (std.mem.eql(u8, base.name, todo.TodoTool.tool_name)) break :blk isReadOnlyTodoAction(args);
        break :blk false;
    };

    if (!is_read_only) return base;
    var refined = base;
    refined.flags.read_only = true;
    refined.flags.mutating = false;
    // Read-only action-specific dispatch is inherently concurrency-safe —
    // no write side-effects means no racing on shared state. This keeps
    // the single-source-of-truth invariant: `flags.concurrency_safe` is
    // the canonical signal for parallel-dispatch eligibility. Without
    // this, `schedule list` / `composio list` would lose parallel-dispatch
    // capability when we rely on metadata (see `isParallelSafeToolCall`).
    refined.flags.concurrency_safe = true;

    // D1.14c — per-call cache opt-in for action-dependent tools that
    // are read-only on this specific dispatch. The base entry stays
    // cacheable=false (compatible with mutating=true at the registry
    // level); only the refined entry carries cache flags. Today this
    // covers composio list/get — per-tenant API key, so scope =
    // .tenant; catalog-style results, so 60s TTL is safe.
    //
    // Other action-dependent tools (schedule list, git status, http
    // GET, skill_registry list) intentionally do NOT opt in here:
    //   - schedule list: low-value cache; user expects to see fresh
    //     scheduled jobs after a write
    //   - git status: local + fast; no measurable cache win
    //   - http GET: per-URL responses may include user-specific data;
    //     blanket caching is risky (cache-key includes URL but not
    //     auth headers a tenant might pass via args — over-cautious)
    //   - skill_registry list: local + fast; no measurable cache win
    if (std.mem.eql(u8, base.name, composio.ComposioTool.tool_name)) {
        refined.flags.cacheable = true;
        refined.cache_ttl_secs = 60;
        refined.cache_scope = .tenant;
    }

    return refined;
}

/// Create the default tool set (shell, file_read, file_write).
pub fn defaultTools(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
) ![]Tool {
    return defaultToolsWithPaths(allocator, workspace_dir, &.{});
}

/// Create the default tool set with additional allowed paths.
pub fn defaultToolsWithPaths(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    allowed_paths: []const []const u8,
) ![]Tool {
    var list: std.ArrayList(Tool) = .{};
    errdefer {
        for (list.items) |t| {
            t.deinit(allocator);
        }
        list.deinit(allocator);
    }

    const st = try allocator.create(shell.ShellTool);
    st.* = .{ .workspace_dir = workspace_dir, .allowed_paths = allowed_paths };
    try list.append(allocator, st.tool());

    const ft = try allocator.create(file_read.FileReadTool);
    ft.* = .{ .workspace_dir = workspace_dir, .allowed_paths = allowed_paths };
    try list.append(allocator, ft.tool());

    const wt = try allocator.create(file_write.FileWriteTool);
    wt.* = .{ .workspace_dir = workspace_dir, .allowed_paths = allowed_paths };
    try list.append(allocator, wt.tool());

    const et = try allocator.create(file_edit.FileEditTool);
    et.* = .{ .workspace_dir = workspace_dir, .allowed_paths = allowed_paths };
    try list.append(allocator, et.tool());

    return list.toOwnedSlice(allocator);
}

/// Create all tools including optional ones.
pub fn allTools(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    opts: struct {
        tool_profile: ToolProfile = .main,
        config: ?*const @import("../config.zig").Config = null,
        http_enabled: bool = false,
        browser_enabled: bool = false,
        screenshot_enabled: bool = false,
        composio_api_key: ?[]const u8 = null,
        browser_open_domains: ?[]const []const u8 = null,
        // hardware_boards: removed D19 (2026-04-25) — V1 stripped the
        // hardware surface. The legacy-caller stub at line 1035 went
        // with it; restore from git history if a fork ever reintroduces
        // embedded-device support.
        mcp_tools: ?[]const Tool = null,
        agents: ?[]const @import("../config.zig").NamedAgentConfig = null,
        fallback_api_key: ?[]const u8 = null,
        delegate_depth: u32 = 0,
        subagent_manager: ?*@import("../subagent.zig").SubagentManager = null,
        event_bus: ?*bus.Bus = null,
        composio_entity_id: ?[]const u8 = null,
        allowed_paths: []const []const u8 = &.{},
        tools_config: @import("../config.zig").ToolsConfig = .{},
        policy: ?*const @import("../security/policy.zig").SecurityPolicy = null,
        task_delivery: ?*@import("../tasks/root.zig").TaskDelivery = null,
    },
) ![]Tool {
    var list: std.ArrayList(Tool) = .{};
    errdefer {
        for (list.items) |t| {
            t.deinit(allocator);
        }
        list.deinit(allocator);
    }

    // Core tools with workspace_dir + allowed_paths + tools_config limits
    const tc = opts.tools_config;

    // Sandbox auto-mode resolution (2026-04-28 sandbox-finish ACE).
    //
    // Resolution rules:
    // - sandbox.enabled = true  → strict: try sandbox; SandboxUnavailable on miss
    // - sandbox.enabled = false → never sandbox
    // - sandbox.enabled = null (default) → AUTO: probe ONCE here, enable iff
    //   a real backend (firejail/bwrap/docker — landlock excluded since it
    //   fail-closes until syscall layer ships) is available on this host.
    // - sandbox.fail_open_on_dev = true → if enabled resolves to true but
    //   the runtime sandbox path returns noop, log.warn and pass through
    //   instead of refusing. Production-safe default is false.
    //
    // Critical perf note: prior code passed `.auto` through to every shell
    // call, which made tool_sandbox_v1.resolve_sandboxed_argv invoke
    // detectBest per-call → 30-500ms `--version` spawn per shell tool
    // invocation. We now resolve `.auto` to a concrete backend ONCE here
    // and store the concrete value in the ShellTool/GitTool struct.
    const security_root = @import("../security/root.zig");
    const SandboxBackendT = @import("../config_types.zig").SandboxBackend;

    const sandbox_user_explicit_enabled: ?bool = if (opts.config) |cfg| cfg.security.sandbox.enabled else null;
    const sandbox_user_backend: SandboxBackendT = if (opts.config) |cfg| cfg.security.sandbox.backend else .auto;
    const sandbox_fail_open: bool = if (opts.config) |cfg| cfg.security.sandbox.fail_open_on_dev else false;

    // Probe once. Cost is bounded: 1-3 fork+execve+wait sequences (~30ms on
    // Linux, ~500ms on macOS through Docker Desktop daemon). Acceptable at
    // tool-factory init; was unacceptable per-shell-call.
    const avail = security_root.detectAvailable(allocator, workspace_dir);
    const has_real_backend = avail.firejail or avail.bubblewrap or avail.docker;

    const sandbox_enabled = if (sandbox_user_explicit_enabled) |e| e else has_real_backend;

    // Resolve `.auto` → concrete backend so tool_sandbox_v1 doesn't re-probe
    // on the hot path.
    const sandbox_backend: SandboxBackendT = if (sandbox_user_backend == .auto and sandbox_enabled) blk: {
        if (avail.firejail) break :blk .firejail;
        if (avail.bubblewrap) break :blk .bubblewrap;
        if (avail.docker) break :blk .docker;
        break :blk .auto;
    } else sandbox_user_backend;

    // Startup log line so operators see what was selected. Once per agent
    // init.
    std.log.scoped(.sandbox).info(
        "sandbox: enabled={any} backend={s} fail_open_on_dev={any} workspace={s} avail={{firejail:{any} bubblewrap:{any} docker:{any}}}",
        .{
            sandbox_enabled,
            @tagName(sandbox_backend),
            sandbox_fail_open,
            workspace_dir,
            avail.firejail,
            avail.bubblewrap,
            avail.docker,
        },
    );

    // Publish the resolved sandbox state for the gateway /api/v1/status
    // endpoint to surface as a UI badge. Process-global snapshot — multiple
    // agents in the same process all see the same host backends, so the
    // last-write-wins is fine (they should all write identical values).
    @import("tool_sandbox_v1.zig").setStateSnapshot(.{
        .enabled = sandbox_enabled,
        .backend = sandbox_backend,
        .fail_open_on_dev = sandbox_fail_open,
        .has_real_backend = has_real_backend,
        .avail_firejail = avail.firejail,
        .avail_bubblewrap = avail.bubblewrap,
        .avail_docker = avail.docker,
    });

    const st = try allocator.create(shell.ShellTool);
    st.* = .{
        .workspace_dir = workspace_dir,
        .allowed_paths = opts.allowed_paths,
        .timeout_ns = tc.shell_timeout_secs * std.time.ns_per_s,
        .max_output_bytes = tc.shell_max_output_bytes,
        .policy = opts.policy,
        .sandbox_enabled = sandbox_enabled,
        .sandbox_backend = sandbox_backend,
        .sandbox_fail_open_on_dev = sandbox_fail_open,
    };
    try list.append(allocator, st.tool());

    const ft = try allocator.create(file_read.FileReadTool);
    ft.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths, .max_file_size = tc.max_file_size_bytes };
    try list.append(allocator, ft.tool());

    const wt = try allocator.create(file_write.FileWriteTool);
    wt.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths };
    try list.append(allocator, wt.tool());

    const et2 = try allocator.create(file_edit.FileEditTool);
    et2.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths, .max_file_size = tc.max_file_size_bytes };
    try list.append(allocator, et2.tool());

    const fat = try allocator.create(file_append.FileAppendTool);
    fat.* = .{
        .workspace_dir = workspace_dir,
        .allowed_paths = opts.allowed_paths,
        .max_file_size = tc.max_file_size_bytes,
    };
    try list.append(allocator, fat.tool());

    const calct = try allocator.create(calculator.CalculatorTool);
    calct.* = .{};
    try list.append(allocator, calct.tool());

    const frht = try allocator.create(file_read_hashed.FileReadHashedTool);
    frht.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths, .max_file_size = tc.max_file_size_bytes };
    try list.append(allocator, frht.tool());

    const feht = try allocator.create(file_edit_hashed.FileEditHashedTool);
    feht.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths };
    try list.append(allocator, feht.tool());

    const gt = try allocator.create(git.GitTool);
    gt.* = .{
        .workspace_dir = workspace_dir,
        .allowed_paths = opts.allowed_paths,
        .sandbox_enabled = sandbox_enabled,
        .sandbox_backend = sandbox_backend,
        .sandbox_fail_open_on_dev = sandbox_fail_open,
    };
    try list.append(allocator, gt.tool());

    // Tools without workspace_dir
    const it = try allocator.create(image.ImageInfoTool);
    it.* = .{};
    try list.append(allocator, it.tool());

    // image_generate: api_key_override left empty at construction; the bind
    // helper `bindImageGenerate` wires the together api key at boot.
    // workspace_dir is set here so saved images land in the agent's workspace.
    const igt = try allocator.create(image_generate.ImageGenerateTool);
    igt.* = .{ .workspace_dir = workspace_dir };
    try list.append(allocator, igt.tool());

    // Memory tools (work gracefully without a backend)
    const mst = try allocator.create(memory_store.MemoryStoreTool);
    mst.* = .{};
    try list.append(allocator, mst.tool());

    const met = try allocator.create(memory_edit.MemoryEditTool);
    met.* = .{};
    try list.append(allocator, met.tool());

    const mrt = try allocator.create(memory_recall.MemoryRecallTool);
    mrt.* = .{};
    try list.append(allocator, mrt.tool());

    const mlt = try allocator.create(memory_list.MemoryListTool);
    mlt.* = .{};
    try list.append(allocator, mlt.tool());

    const mtt = try allocator.create(memory_timeline.MemoryTimelineTool);
    mtt.* = .{};
    try list.append(allocator, mtt.tool());

    const trt = try allocator.create(transcript_read.TranscriptReadTool);
    trt.* = .{};
    try list.append(allocator, trt.tool());

    const mft = try allocator.create(memory_forget.MemoryForgetTool);
    mft.* = .{};
    try list.append(allocator, mft.tool());

    // V1.6 commit 11 — soft-delete + demote-from-core agent surfaces.
    // Pair with memory_forget (hard delete). The agent picks based on
    // the user's intent: scrub forever (forget), preserve audit (archive),
    // unlock a core fact for editing (demote).
    const mat = try allocator.create(memory_archive.MemoryArchiveTool);
    mat.* = .{};
    try list.append(allocator, mat.tool());

    const mdt = try allocator.create(memory_demote.MemoryDemoteTool);
    mdt.* = .{};
    try list.append(allocator, mdt.tool());

    const mpt = try allocator.create(memory_purge_topic.MemoryPurgeTopicTool);
    mpt.* = .{};
    try list.append(allocator, mpt.tool());

    // V1.9-5 — unified truth-maintenance toolkit. state_mgr +
    // user_id wired separately via bindStateMgrTenant.
    const mmt = try allocator.create(memory_maintain.MemoryMaintainTool);
    mmt.* = .{};
    try list.append(allocator, mmt.tool());

    // V1.9-DX1 — time_now: wall-clock awareness for the agent.
    const tnt = try allocator.create(time_now.TimeNowTool);
    tnt.* = .{};
    try list.append(allocator, tnt.tool());

    // Delegate + spawn: dormant by default for V1. Both are coded but have
    // incomplete end-to-end behavior (subagent result visibility on follow-up
    // turns, delegation agent config prereqs). Showing them in the catalog
    // creates a broken-capability feel. Opt-in via NULLALIS_ENABLE_MULTIAGENT=1.
    const multiagent_enabled = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "NULLALIS_ENABLE_MULTIAGENT") catch break :blk false;
        defer allocator.free(raw);
        break :blk std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "1");
    };
    if (opts.tool_profile == .main and multiagent_enabled) {
        const dlt = try allocator.create(delegate.DelegateTool);
        dlt.* = .{
            .agents = opts.agents orelse &.{},
            .config_ref = opts.config,
            .fallback_api_key = opts.fallback_api_key,
            .depth = opts.delegate_depth,
        };
        try list.append(allocator, dlt.tool());
    }

    const scht = try allocator.create(schedule.ScheduleTool);
    scht.* = .{ .config = opts.config };
    try list.append(allocator, scht.tool());

    // V1.5 — Todo tool. Per-session task lists with status tracking,
    // persisted via the memory layer. Memory backend is bound below by
    // bindMemoryRuntime / bindMemory; if neither runs, the tool will
    // fail gracefully at execute() with "memory backend not configured."
    const todot = try allocator.create(todo.TodoTool);
    todot.* = .{};
    try list.append(allocator, todot.tool());

    // V1.5 day-3 — compose_memory tool. Synthesizes 2+ existing memories
    // into one consolidated fact with metadata-canonical provenance.
    // Same memory-backend wiring as todo; falls back to plain store
    // (metadata dropped) when the engine doesn't support metadata.
    // Production zaki_postgres engine implements the metadata path.
    const cmt = try allocator.create(compose_memory.ComposeMemoryTool);
    cmt.* = .{};
    try list.append(allocator, cmt.tool());

    // V1.7-ship S2a — brain_graph tool (graph navigation: local subgraph,
    // communities, orphans, diff). Tenant binding via bindStateMgrTenant
    // pass below. Falls back to clear "state manager not bound" failure
    // when postgres isn't configured (so the agent's prompt-time tool
    // listing always succeeds; runtime gracefully reports the gap).
    const bgt = try allocator.create(brain_graph.BrainGraphTool);
    bgt.* = .{};
    try list.append(allocator, bgt.tool());

    // Cron tools + push notifications
    const cat = try allocator.create(cron_add.CronAddTool);
    cat.* = .{ .config = opts.config };
    try list.append(allocator, cat.tool());

    const clt = try allocator.create(cron_list.CronListTool);
    clt.* = .{ .config = opts.config };
    try list.append(allocator, clt.tool());

    const crt = try allocator.create(cron_remove.CronRemoveTool);
    crt.* = .{ .config = opts.config };
    try list.append(allocator, crt.tool());

    const crst = try allocator.create(cron_runs.CronRunsTool);
    crst.* = .{ .config = opts.config };
    try list.append(allocator, crst.tool());

    const crut = try allocator.create(cron_run.CronRunTool);
    crut.* = .{ .config = opts.config };
    try list.append(allocator, crut.tool());

    const cupt = try allocator.create(cron_update.CronUpdateTool);
    cupt.* = .{ .config = opts.config };
    try list.append(allocator, cupt.tool());

    const pt = try allocator.create(pushover.PushoverTool);
    pt.* = .{
        .workspace_dir = workspace_dir,
        .allocator = allocator,
    };
    try list.append(allocator, pt.tool());

    const rit = try allocator.create(runtime_info.RuntimeInfoTool);
    rit.* = .{
        .config = opts.config orelse return error.InvalidArgument,
    };
    try list.append(allocator, rit.tool());

    const skrt = try allocator.create(skill_registry.SkillRegistryTool);
    skrt.* = .{ .workspace_dir = workspace_dir };
    try list.append(allocator, skrt.tool());

    // Spawn tool (async subagent) — dormant by default, same env gate as delegate.
    if (opts.tool_profile == .main and multiagent_enabled) {
        const sp = try allocator.create(spawn.SpawnTool);
        sp.* = .{ .manager = opts.subagent_manager };
        try list.append(allocator, sp.tool());
    }

    // Always publish the message tool in the main profile; the tool itself
    // handles bus-less runtimes by falling back to direct-send paths (e.g.
    // file-mode Telegram via user_root) and reports a clear error when no
    // delivery path is available. Keeping the tool advertised prevents the
    // "Unknown tool" experience in local/CLI runtimes where the gateway bus
    // is not wired in.
    if (opts.tool_profile == .main) {
        const mt = try allocator.create(message.MessageTool);
        mt.* = .{
            .event_bus = opts.event_bus,
            .outbound_allocator = allocator,
        };
        try list.append(allocator, mt.tool());
    }

    if (opts.http_enabled) {
        const ht = try allocator.create(http_request.HttpRequestTool);
        ht.* = .{};
        try list.append(allocator, ht.tool());

        const wft = try allocator.create(web_fetch.WebFetchTool);
        wft.* = .{ .default_max_chars = tc.web_fetch_max_chars };
        try list.append(allocator, wft.tool());

        const wst = try allocator.create(web_search.WebSearchTool);
        wst.* = .{
            .provider_mode_override = tc.web_search_provider,
            .exa_api_key_override = tc.web_search_exa_api_key,
            .brave_api_key_override = tc.web_search_brave_api_key,
        };
        try list.append(allocator, wst.tool());
    }

    if (opts.browser_enabled) {
        const bt = try allocator.create(browser.BrowserTool);
        bt.* = .{};
        try list.append(allocator, bt.tool());
    }

    if (opts.screenshot_enabled) {
        const sst = try allocator.create(screenshot.ScreenshotTool);
        sst.* = .{ .workspace_dir = workspace_dir };
        try list.append(allocator, sst.tool());
    }

    if (opts.composio_api_key) |api_key| {
        const ct = try allocator.create(composio.ComposioTool);
        ct.* = .{ .api_key = api_key, .entity_id = opts.composio_entity_id orelse "default" };
        try list.append(allocator, ct.tool());
    }

    if (opts.browser_open_domains) |domains| {
        const bot = try allocator.create(browser_open.BrowserOpenTool);
        bot.* = .{ .allowed_domains = domains };
        try list.append(allocator, bot.tool());
    }

    // Hardware/IoT tools fully removed D19 (2026-04-25). Was kept as
    // a one-release transition stub; that window has elapsed. The
    // hardware_boards field is now gone from the options struct too.

    // Task management tools (Phase 2: REQ-006)
    if (opts.task_delivery) |delivery| {
        const tlt = try allocator.create(task_list.TaskListTool);
        tlt.* = .{ .delivery = delivery };
        try list.append(allocator, tlt.tool());

        const tgt = try allocator.create(task_get.TaskGetTool);
        tgt.* = .{ .delivery = delivery };
        try list.append(allocator, tgt.tool());

        const tst = try allocator.create(task_stop.TaskStopTool);
        tst.* = .{ .delivery = delivery };
        try list.append(allocator, tst.tool());
    }

    // Self-control & self-inspection tools — always registered; tools read
    // the agent controller from a thread-local set by the agent per turn
    // (see `setAgentController` in this module and `Agent.turn` in agent/root.zig).
    const semt = try allocator.create(set_execution_mode.SetExecutionModeTool);
    semt.* = .{};
    try list.append(allocator, semt.tool());

    const cst = try allocator.create(context_snapshot.ContextSnapshotTool);
    cst.* = .{};
    try list.append(allocator, cst.tool());

    // MCP tools (pre-initialized externally)
    if (opts.mcp_tools) |mt| {
        for (mt) |t| {
            try list.append(allocator, t);
        }
    }

    const tools_slice = try list.toOwnedSlice(allocator);
    bindRuntimeInfoTools(tools_slice);
    return tools_slice;
}

pub const MessageTurnContext = message.MessageTool.TurnContext;
pub const ToolProfile = enum {
    main,
    subagent,
};
pub const TurnOrigin = enum {
    user,
    heartbeat,
    scheduler,
    wake,
    proactive,

    pub fn toSlice(self: TurnOrigin) []const u8 {
        return switch (self) {
            .user => "user",
            .heartbeat => "heartbeat",
            .scheduler => "scheduler",
            .wake => "wake",
            .proactive => "proactive",
        };
    }
};

pub const RuntimeTurnContext = struct {
    origin: TurnOrigin = .user,
    session_key: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Per-session billing + capability state. Default construction gives
    /// "pro active unlimited" so existing tests + un-plumbed call paths
    /// keep working. S2.1 (BFF provision response extension) installs the
    /// real Entitlement when a user session starts; S2.7 revocation
    /// webhook can swap it mid-session. S2.3-S2.6 enforcement sites read
    /// this field in preflight. See `src/entitlement.zig` for the type.
    entitlement: Entitlement = .{},
};

pub const ToolTenantContext = struct {
    user_id: ?[]const u8 = null,
    numeric_user_id: ?i64 = null,
    session_key: ?[]const u8 = null,
    state_mgr: ?*zaki_state.Manager = null,
    expect_postgres_state: bool = false,
    /// Optional user-scoped filesystem root used by tools that need a
    /// file-backed fallback for state or secrets (e.g. file-mode Telegram
    /// direct send reads `<user_root>/channel_state.json` and
    /// `<user_root>/secrets/telegram_bot_token`). Non-owning; the caller
    /// owns the underlying buffer for the duration of the turn.
    user_root: ?[]const u8 = null,
};

threadlocal var current_tenant_context: ToolTenantContext = .{};
threadlocal var current_turn_context: RuntimeTurnContext = .{};
threadlocal var current_agent_controller: ?AgentController = null;

/// Agent-self-introspection/control interface exposed to a narrow set of
/// agent-invokable tools (set_execution_mode, context_snapshot). The agent
/// installs one of these for the duration of each turn via
/// `setAgentController`; tools retrieve it via `getAgentController`.
///
/// Why an interface (not a direct *Agent pointer): `tools/` cannot import
/// `agent/root.zig` without creating an import cycle. The controller is
/// populated on the agent side where it CAN see the full Agent struct.
pub const AgentController = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_execution_mode: *const fn (*anyopaque, mode: []const u8) bool,
        get_execution_mode: *const fn (*anyopaque) []const u8,
        snapshot_json: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
    };

    pub fn setExecutionMode(self: AgentController, mode: []const u8) bool {
        return self.vtable.set_execution_mode(self.ptr, mode);
    }

    pub fn getExecutionMode(self: AgentController) []const u8 {
        return self.vtable.get_execution_mode(self.ptr);
    }

    pub fn snapshotJson(self: AgentController, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.snapshot_json(self.ptr, allocator);
    }
};

pub fn setAgentController(ctrl: AgentController) void {
    current_agent_controller = ctrl;
}

pub fn clearAgentController() void {
    current_agent_controller = null;
}

pub fn getAgentController() ?AgentController {
    return current_agent_controller;
}

// ── Tool-scoped observer (per-turn) ─────────────────────────────────
//
// Tools that want to surface system_notice events (connector_stale,
// multimodal_failure, etc.) to the caller's SSE stream read this threadlocal
// instead of holding a direct Observer pointer. The agent sets it on turn
// entry; the tool registry (`allTools`) is shared across sessions so
// holding a pointer on the tool struct itself would bind the wrong session.
//
// Observers are per-agent. When running outside an agent (gateway webhook
// parse, channel poll, etc.) this threadlocal stays null and tools silently
// drop notices — those paths have no attached user SSE anyway.

threadlocal var current_tool_observer: ?*observability.Observer = null;

pub fn setToolObserver(obs: ?*observability.Observer) void {
    current_tool_observer = obs;
}

pub fn clearToolObserver() void {
    current_tool_observer = null;
}

pub fn getToolObserver() ?*observability.Observer {
    return current_tool_observer;
}

pub fn setMessageTurnContext(ctx: ?MessageTurnContext) void {
    if (ctx) |value| {
        message.MessageTool.setTurnContext(value);
    } else {
        message.MessageTool.clearTurnContext();
    }
}

pub fn clearMessageTurnContext() void {
    message.MessageTool.clearTurnContext();
}

pub fn setTenantContext(ctx: ?ToolTenantContext) void {
    current_tenant_context = ctx orelse .{};
}

pub fn clearTenantContext() void {
    current_tenant_context = .{};
}

pub fn getTenantContext() ToolTenantContext {
    return current_tenant_context;
}

pub fn setTurnContext(ctx: ?RuntimeTurnContext) void {
    current_turn_context = ctx orelse .{};
}

pub fn clearTurnContext() void {
    current_turn_context = .{};
}

pub fn getTurnContext() RuntimeTurnContext {
    return current_turn_context;
}

pub fn isBackgroundTurnOrigin(origin: TurnOrigin) bool {
    return switch (origin) {
        .user => false,
        .heartbeat, .scheduler, .wake, .proactive => true,
    };
}

pub fn effectiveStateBackend(config: *const @import("../config.zig").Config, tenant_ctx: ToolTenantContext) []const u8 {
    if (!std.mem.eql(u8, config.state.backend, "postgres")) return "file";
    if (!build_options.enable_postgres) return "file";
    if (config.tenant.enabled and tenant_ctx.state_mgr == null) return "file";
    return "postgres";
}

pub fn schedulerBackend(config: *const @import("../config.zig").Config, tenant_ctx: ToolTenantContext) []const u8 {
    if (!config.tenant.enabled) return "file";
    if (std.mem.eql(u8, effectiveStateBackend(config, tenant_ctx), "postgres")) return "postgres";
    return "file";
}

pub fn degradedReason(config: *const @import("../config.zig").Config, tenant_ctx: ToolTenantContext) []const u8 {
    if (!std.mem.eql(u8, config.state.backend, "postgres")) return "";
    if (!build_options.enable_postgres) return "PostgresNotEnabled";
    if (config.tenant.enabled and tenant_ctx.state_mgr == null) return "PostgresUnavailable";
    return "";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn isReadOnlyComposioExecute(args: JsonObjectMap) bool {
    const slug = getString(args, "tool_slug") orelse
        getString(args, "action_name") orelse
        return false;

    const write_hints = [_][]const u8{
        "send",    "create", "update",    "delete",  "remove", "write", "post",   "put",  "patch",
        "insert",  "append", "modify",    "archive", "trash",  "star",  "label",  "move", "upload",
        "connect", "auth",   "authorize", "grant",   "revoke", "share", "invite", "book", "schedule",
    };
    if (containsAnyIgnoreCase(slug, &write_hints)) return false;

    const read_hints = [_][]const u8{
        "list", "get", "fetch", "read", "search", "find", "query", "lookup", "retrieve", "view", "download",
    };
    return containsAnyIgnoreCase(slug, &read_hints);
}

const BackgroundOriginPolicy = struct {
    allow_schedule_ensure: bool,
    allow_composio_read_execute: bool,
    allow_message: bool,
};

fn backgroundPolicyForOrigin(origin: TurnOrigin) BackgroundOriginPolicy {
    return switch (origin) {
        // Compatibility-only heartbeat lane; do not mutate durable automation.
        .heartbeat => .{
            .allow_schedule_ensure = false,
            .allow_composio_read_execute = false,
            .allow_message = false,
        },
        // Wake/reconcile turns may inspect and repair canonical durable jobs.
        .wake => .{
            .allow_schedule_ensure = true,
            .allow_composio_read_execute = false,
            .allow_message = false,
        },
        // User-visible delivery lane should execute existing jobs, not mutate schedule state.
        .proactive => .{
            .allow_schedule_ensure = false,
            .allow_composio_read_execute = true,
            .allow_message = true,
        },
        // Internal scheduler maintenance lane; keep conservative to avoid self-loop mutation.
        .scheduler => .{
            .allow_schedule_ensure = false,
            .allow_composio_read_execute = false,
            .allow_message = false,
        },
        .user => .{
            .allow_schedule_ensure = true,
            .allow_composio_read_execute = true,
            .allow_message = true,
        },
    };
}

fn isReadOnlyScheduleAction(args: JsonObjectMap) bool {
    const action = getString(args, "action") orelse return true;
    return std.ascii.eqlIgnoreCase(action, "list") or
        std.ascii.eqlIgnoreCase(action, "get") or
        std.ascii.eqlIgnoreCase(action, "runs");
}

/// V1.5 todo tool: `list` is read-only; `create` and `update` mutate.
fn isReadOnlyTodoAction(args: JsonObjectMap) bool {
    const action = getString(args, "action") orelse return false;
    return std.ascii.eqlIgnoreCase(action, "list");
}

fn isEnsureScheduleAction(args: JsonObjectMap) bool {
    const action = getString(args, "action") orelse return false;
    return std.ascii.eqlIgnoreCase(action, "ensure");
}

pub fn toolBlockedForCurrentTurn(tool_name: []const u8, args: JsonObjectMap) ?[]const u8 {
    const registry = defaultMetadataRegistry();
    const base_meta = metadata.lookupMetadata(tool_name, registry) orelse
        metadata.ToolMetadata.conservative(tool_name);
    return toolBlockedForCurrentTurnWithMeta(tool_name, args, base_meta);
}

/// Metadata-aware variant so callers that already resolved metadata (e.g.
/// `Agent.preflightToolPolicy`) don't re-lookup. Policy shape:
///   * Non-background turn origin -> always allow.
///   * Special-case tools (schedule, composio, message) keep their per-origin
///     argument-aware rules.
///   * Otherwise, defer to metadata: `read_only` or `background_safe` -> allow.
///     Everything else is denied with a listing-style message so a misbehaving
///     tool author can see which flag would have allowed the call.
pub fn toolBlockedForCurrentTurnWithMeta(
    tool_name: []const u8,
    args: JsonObjectMap,
    meta: metadata.ToolMetadata,
) ?[]const u8 {
    const turn_ctx = getTurnContext();
    if (!isBackgroundTurnOrigin(turn_ctx.origin)) return null;
    const policy = backgroundPolicyForOrigin(turn_ctx.origin);

    // Tools with argument-aware origin rules.
    if (std.mem.eql(u8, tool_name, schedule.ScheduleTool.tool_name)) {
        if (isReadOnlyScheduleAction(args)) return null;
        if (policy.allow_schedule_ensure and isEnsureScheduleAction(args)) return null;
        return "Background turns may only inspect schedule state; only wake turns may use schedule ensure for canonical reconciliation";
    }
    if (std.mem.eql(u8, tool_name, message.MessageTool.tool_name)) {
        if (policy.allow_message) return null;
        return "Message is disabled for this background turn origin";
    }
    if (std.mem.eql(u8, tool_name, composio.ComposioTool.tool_name)) {
        const action = getString(args, "action") orelse "execute";
        if (std.ascii.eqlIgnoreCase(action, "connect")) {
            return "Composio connect is disabled for background turns";
        }
        if (!policy.allow_composio_read_execute) {
            return "Composio is disabled for this background turn origin";
        }
        if (std.ascii.eqlIgnoreCase(action, "list")) return null;
        if (std.ascii.eqlIgnoreCase(action, "execute")) {
            if (isReadOnlyComposioExecute(args)) return null;
            return "Composio write/unknown execute actions are disabled for background turns";
        }
        return "Composio action is disabled for background turns";
    }

    // Fast per-origin explicit denials that must never be relaxed via metadata.
    if (std.mem.eql(u8, tool_name, shell.ShellTool.tool_name)) {
        return "Shell is disabled for background turns";
    }
    if (std.mem.eql(u8, tool_name, spawn.SpawnTool.tool_name)) {
        return "Spawn is disabled for background turns";
    }
    if (std.mem.eql(u8, tool_name, delegate.DelegateTool.tool_name)) {
        return "Delegate is disabled for background turns";
    }

    // Metadata-driven default: allow read-only or background_safe tools.
    // `read_only` is included so tools like grep/glob/cron_list (which are
    // not yet marked background_safe but are inherently non-mutating) are
    // not surprise-blocked in background lanes.
    if (meta.flags.background_safe or meta.flags.read_only) return null;

    return "Tool is disabled for this background turn; mark tool metadata `background_safe` or use schedule(read/ensure on wake), message/composio on proactive turns, or a read-only action";
}

pub fn bindRuntimeInfoTools(tools: []const Tool) void {
    for (tools) |t| {
        if (t.vtable == &runtime_info.RuntimeInfoTool.vtable) {
            const rt: *runtime_info.RuntimeInfoTool = @ptrCast(@alignCast(t.ptr));
            rt.runtime_tools = tools;
        }
    }
}

/// Bind a memory backend to memory tools in a pre-built tool list.
pub fn bindMemoryTools(tools: []const Tool, memory: ?Memory) void {
    for (tools) |t| {
        if (t.vtable == &memory_store.MemoryStoreTool.vtable) {
            const mt: *memory_store.MemoryStoreTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &memory_edit.MemoryEditTool.vtable) {
            const mt: *memory_edit.MemoryEditTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &memory_recall.MemoryRecallTool.vtable) {
            const mt: *memory_recall.MemoryRecallTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &memory_list.MemoryListTool.vtable) {
            const mt: *memory_list.MemoryListTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &memory_timeline.MemoryTimelineTool.vtable) {
            const mt: *memory_timeline.MemoryTimelineTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &memory_forget.MemoryForgetTool.vtable) {
            const mt: *memory_forget.MemoryForgetTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &memory_archive.MemoryArchiveTool.vtable) {
            // V1.6 cmt11 — memory_archive needs the Memory backend for
            // the protected-key lifecycle check; tenant context (state_mgr
            // + user_id) wired separately via bindStateMgrTenant below.
            const mt: *memory_archive.MemoryArchiveTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &memory_purge_topic.MemoryPurgeTopicTool.vtable) {
            const mt: *memory_purge_topic.MemoryPurgeTopicTool = @ptrCast(@alignCast(t.ptr));
            mt.memory = memory;
        } else if (t.vtable == &todo.TodoTool.vtable) {
            // V1.5 — todo tool persists via memory layer; bind same as
            // other memory-backed tools.
            const tt: *todo.TodoTool = @ptrCast(@alignCast(t.ptr));
            tt.memory = memory;
        } else if (t.vtable == &compose_memory.ComposeMemoryTool.vtable) {
            // V1.5 day-3 — compose_memory persists via memory layer;
            // uses storeWithMetadata when the backend supports it
            // (zaki_postgres production), falls back to plain store
            // otherwise (metadata dropped — graceful degrade).
            const cmt: *compose_memory.ComposeMemoryTool = @ptrCast(@alignCast(t.ptr));
            cmt.memory = memory;
        }
    }
}

/// Bind a MemoryRuntime to memory tools for retrieval pipeline and vector sync.
/// Call after bindMemoryTools to enable hybrid search and vector sync.
pub fn bindMemoryRuntime(tools: []const Tool, mem_rt: ?*memory_mod.MemoryRuntime) void {
    for (tools) |t| {
        if (t.vtable == &memory_store.MemoryStoreTool.vtable) {
            const mt: *memory_store.MemoryStoreTool = @ptrCast(@alignCast(t.ptr));
            mt.mem_rt = mem_rt;
        } else if (t.vtable == &memory_edit.MemoryEditTool.vtable) {
            const mt: *memory_edit.MemoryEditTool = @ptrCast(@alignCast(t.ptr));
            mt.mem_rt = mem_rt;
        } else if (t.vtable == &memory_recall.MemoryRecallTool.vtable) {
            const mt: *memory_recall.MemoryRecallTool = @ptrCast(@alignCast(t.ptr));
            mt.mem_rt = mem_rt;
        } else if (t.vtable == &memory_timeline.MemoryTimelineTool.vtable) {
            const mt: *memory_timeline.MemoryTimelineTool = @ptrCast(@alignCast(t.ptr));
            mt.mem_rt = mem_rt;
        } else if (t.vtable == &memory_forget.MemoryForgetTool.vtable) {
            const mt: *memory_forget.MemoryForgetTool = @ptrCast(@alignCast(t.ptr));
            mt.mem_rt = mem_rt;
        } else if (t.vtable == &memory_purge_topic.MemoryPurgeTopicTool.vtable) {
            const mt: *memory_purge_topic.MemoryPurgeTopicTool = @ptrCast(@alignCast(t.ptr));
            mt.mem_rt = mem_rt;
        } else if (t.vtable == &transcript_read.TranscriptReadTool.vtable) {
            const trt: *transcript_read.TranscriptReadTool = @ptrCast(@alignCast(t.ptr));
            trt.session_store = if (mem_rt) |rt| rt.session_store else null;
        }
    }
}

/// V1.6 cmt11 — bind tenant context (state_mgr + user_id) to tools that
/// need direct postgres access for bi-temporal close-out / demote operations.
/// Today's consumers: memory_archive (calls setMemoryInvalidation) and
/// memory_demote (calls demoteMemoryFromCore). Both require numeric user_id
/// for SQL params; pass null when tenant has no postgres lane (the tools
/// will surface a clear "soft-delete unavailable" error to the agent).
pub fn bindStateMgrTenant(tools: []const Tool, state_mgr: ?*zaki_state.Manager, user_id: ?i64) void {
    for (tools) |t| {
        if (t.vtable == &memory_archive.MemoryArchiveTool.vtable) {
            const mt: *memory_archive.MemoryArchiveTool = @ptrCast(@alignCast(t.ptr));
            mt.state_mgr = state_mgr;
            mt.user_id = user_id;
        } else if (t.vtable == &memory_demote.MemoryDemoteTool.vtable) {
            const mt: *memory_demote.MemoryDemoteTool = @ptrCast(@alignCast(t.ptr));
            mt.state_mgr = state_mgr;
            mt.user_id = user_id;
        } else if (t.vtable == &memory_store.MemoryStoreTool.vtable) {
            // V1.7 cmt9.6 — memory_store gains tenant context for the
            // unified write path. When agent supplies subject/predicate/
            // object alongside content, the tool routes through
            // extraction_persist.persistExtracted instead of inline upsert.
            // judge_provider + coref_embed wired separately via
            // bindMemoryStoreUnifiedContext.
            const mt: *memory_store.MemoryStoreTool = @ptrCast(@alignCast(t.ptr));
            mt.state_mgr = state_mgr;
            mt.user_id = user_id;
        } else if (t.vtable == &brain_graph.BrainGraphTool.vtable) {
            // V1.7-ship S2a — read-only graph navigation. Same tenant
            // binding as the writers above. With state_mgr=null (sqlite
            // build / pre-tenant), execute() returns a clean failure
            // rather than crashing.
            const bt: *brain_graph.BrainGraphTool = @ptrCast(@alignCast(t.ptr));
            bt.state_mgr = state_mgr;
            bt.user_id = user_id;
        } else if (t.vtable == &memory_maintain.MemoryMaintainTool.vtable) {
            // V1.9-5 — unified truth-maintenance toolkit. Every action
            // (cascade_update, invalidate_when, resolve_contradiction,
            // propagate_correction, temporal_decay, survey) needs the
            // tenant context. Without it the tool returns a clean
            // failure rather than crashing.
            const mt: *memory_maintain.MemoryMaintainTool = @ptrCast(@alignCast(t.ptr));
            mt.state_mgr = state_mgr;
            mt.user_id = user_id;
        } else if (t.vtable == &memory_recall.MemoryRecallTool.vtable) {
            // V1.10-D — memory_recall needs tenant context to fetch the
            // supersede skip-set per call. Without it (non-postgres
            // build / standalone deploy) the tool falls back to V1.9
            // behavior: no supersede filter, flagged rows surface.
            const mt: *memory_recall.MemoryRecallTool = @ptrCast(@alignCast(t.ptr));
            mt.state_mgr = state_mgr;
            mt.user_id = user_id;
        } else if (t.vtable == &memory_timeline.MemoryTimelineTool.vtable) {
            // V1.10-D — same supersede-filter binding as memory_recall.
            const mt: *memory_timeline.MemoryTimelineTool = @ptrCast(@alignCast(t.ptr));
            mt.state_mgr = state_mgr;
            mt.user_id = user_id;
        } else if (t.vtable == &memory_list.MemoryListTool.vtable) {
            // V1.10-D — same supersede-filter binding as memory_recall.
            const mt: *memory_list.MemoryListTool = @ptrCast(@alignCast(t.ptr));
            mt.state_mgr = state_mgr;
            mt.user_id = user_id;
        }
    }
}

/// V1.7 cmt9.6 — wire judge LLM provider + coref embedding provider to
/// memory_store for the unified write path. Without these, memory_store's
/// triple-routed path skips judging/coref (still produces an
/// extracted_<hash> row but without contradiction detection or entity
/// resolution). Pairs with bindStateMgrTenant.
pub fn bindMemoryStoreUnifiedContext(
    tools: []const Tool,
    judge_provider: ?@import("../providers/root.zig").Provider,
    judge_model_name: ?[]const u8,
    coref_embed: ?@import("../memory/vector/embeddings.zig").EmbeddingProvider,
) void {
    for (tools) |t| {
        if (t.vtable == &memory_store.MemoryStoreTool.vtable) {
            const mt: *memory_store.MemoryStoreTool = @ptrCast(@alignCast(t.ptr));
            mt.judge_provider = judge_provider;
            mt.judge_model_name = judge_model_name;
            mt.coref_embed = coref_embed;
        }
    }
}

/// V1.10-B — wire the sidecar judge provider to `memory_maintain` so the
/// `prose_survey` action can run the cheap LLM-judge prose-contradiction
/// surveyor.
///
/// Why this is a separate binding from `bindMemoryStoreUnifiedContext`:
///   memory_store's judge runs on EVERY triple-write (unified path —
///   contradiction detection on inbound facts), so it's bound to the
///   primary provider/model the agent uses. memory_maintain's prose
///   judge runs only when the agent explicitly invokes prose_survey
///   (cleanup operation, not write-path) and is meant to be the cheap
///   sidecar (Groq Llama 8B free at ZAKI's scale). Different provider,
///   different model, different invocation cadence — different binding.
///
/// Pass `null, ""` (or empty-string model) to leave it unwired —
/// prose_survey will then return a clean "sidecar not configured"
/// failure rather than crashing.
pub fn bindMemoryMaintainSidecar(
    tools: []const Tool,
    sidecar_provider: ?@import("../providers/root.zig").Provider,
    sidecar_model: []const u8,
) void {
    for (tools) |t| {
        if (t.vtable == &memory_maintain.MemoryMaintainTool.vtable) {
            const mt: *memory_maintain.MemoryMaintainTool = @ptrCast(@alignCast(t.ptr));
            mt.judge_provider = sidecar_provider;
            mt.judge_model = sidecar_model;
        }
    }
}

/// Bind a SessionStore to tools that need raw-transcript access (currently:
/// transcript_read). In tenant/per-user deployments the canonical session
/// store is the per-user PG store (zaki_state.UserSessionStore); in
/// standalone deployments it's mem_rt.session_store. Callers can use either
/// source — this setter accepts the already-resolved SessionStore.
pub fn bindSessionStore(tools: []const Tool, store: ?memory_mod.SessionStore) void {
    for (tools) |t| {
        if (t.vtable == &transcript_read.TranscriptReadTool.vtable) {
            const trt: *transcript_read.TranscriptReadTool = @ptrCast(@alignCast(t.ptr));
            trt.session_store = store;
        }
    }
}

/// Wire Together API key (and optional model override) into the
/// image_generate tool. Callers pass the already-resolved key from their
/// provider config (cfg.providers[together].api_key) so each runtime keeps
/// its own tenant-scoped credential flow. Empty string = fall back to
/// TOGETHER_API_KEY env var at invocation time.
pub fn bindImageGenerate(tools: []const Tool, together_api_key: []const u8, model_override: []const u8) void {
    for (tools) |t| {
        if (t.vtable == &image_generate.ImageGenerateTool.vtable) {
            const igt: *image_generate.ImageGenerateTool = @ptrCast(@alignCast(t.ptr));
            igt.api_key_override = together_api_key;
            igt.model_override = model_override;
        }
    }
}

/// Helper: look up a provider's api_key from cfg.providers[].
/// Returns empty string if not found — the consuming tool's resolver will
/// then fall back to the env var or surface a clear "not configured" error.
/// The returned slice is borrowed from the providers array and lives as
/// long as the Config.
pub fn lookupProviderApiKey(
    providers: []const @import("../config_types.zig").ProviderEntry,
    provider_name: []const u8,
) []const u8 {
    for (providers) |entry| {
        if (std.mem.eql(u8, entry.name, provider_name)) {
            if (entry.api_key) |k| return k;
            return "";
        }
    }
    return "";
}

/// Wire audit memory into tools that support command logging (currently: shell).
/// Called after memory initialization, similar to bindMemoryRuntime.
pub fn bindAuditMemory(tools: []const Tool, mem: memory_mod.Memory, session_id: ?[]const u8) void {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), shell.ShellTool.tool_name)) {
            const st: *shell.ShellTool = @ptrCast(@alignCast(t.ptr));
            st.audit_memory = mem;
            st.audit_session_id = session_id;
        }
    }
}

/// Free all heap-allocated tool structs and the tools slice itself.
/// Pairs with `allTools` / `defaultTools` / `subagentTools`.
pub fn deinitTools(allocator: std.mem.Allocator, tools: []const Tool) void {
    for (tools) |t| {
        t.deinit(allocator);
    }
    allocator.free(tools);
}

/// Create restricted tool set for subagents.
/// Includes: shell, file_read, file_write, file_edit, git, http (if enabled).
/// Excludes: message, spawn, delegate, schedule, memory, composio, browser —
/// to prevent infinite loops and cross-channel side effects.
pub fn subagentTools(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    opts: struct {
        http_enabled: bool = false,
        allowed_paths: []const []const u8 = &.{},
        policy: ?*const @import("../security/policy.zig").SecurityPolicy = null,
    },
) ![]Tool {
    var list: std.ArrayList(Tool) = .{};
    errdefer {
        for (list.items) |t| {
            t.deinit(allocator);
        }
        list.deinit(allocator);
    }

    const st = try allocator.create(shell.ShellTool);
    st.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths, .policy = opts.policy };
    try list.append(allocator, st.tool());

    const ft = try allocator.create(file_read.FileReadTool);
    ft.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths };
    try list.append(allocator, ft.tool());

    const wt = try allocator.create(file_write.FileWriteTool);
    wt.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths };
    try list.append(allocator, wt.tool());

    const et = try allocator.create(file_edit.FileEditTool);
    et.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths };
    try list.append(allocator, et.tool());

    const gt = try allocator.create(git.GitTool);
    gt.* = .{ .workspace_dir = workspace_dir };
    try list.append(allocator, gt.tool());

    if (opts.http_enabled) {
        const ht = try allocator.create(http_request.HttpRequestTool);
        ht.* = .{};
        try list.append(allocator, ht.tool());
    }

    return list.toOwnedSlice(allocator);
}

// ── Tests ───────────────────────────────────────────────────────────

test "getString returns unescaped newlines and tabs" {
    const parsed = try parseTestArgs("{\"content\":\"line1\\nline2\\ttab\"}");
    defer parsed.deinit();
    const val = getString(parsed.value.object, "content").?;
    try std.testing.expectEqualStrings("line1\nline2\ttab", val);
}

test "getString returns unescaped quotes and backslashes" {
    const parsed = try parseTestArgs("{\"s\":\"say \\\"hello\\\" path\\\\dir\"}");
    defer parsed.deinit();
    const val = getString(parsed.value.object, "s").?;
    try std.testing.expectEqualStrings("say \"hello\" path\\dir", val);
}

test "getString returns unescaped unicode" {
    // \u0041 = A, \u00c9 = É
    const parsed = try parseTestArgs("{\"s\":\"\\u0041BC \\u00c9\\u00f6\\u00fc\\u00e4\\u00e8\"}");
    defer parsed.deinit();
    const val = getString(parsed.value.object, "s").?;
    try std.testing.expectEqualStrings("ABC Éöüäè", val);
}

test "getString returns unescaped shell script content" {
    const parsed = try parseTestArgs("{\"content\":\"#!/bin/bash\\necho \\\"hello\\\"\\nexit 0\"}");
    defer parsed.deinit();
    const val = getString(parsed.value.object, "content").?;
    try std.testing.expectEqualStrings("#!/bin/bash\necho \"hello\"\nexit 0", val);
}

test "getString returns null for missing key" {
    const parsed = try parseTestArgs("{\"other\":\"val\"}");
    defer parsed.deinit();
    try std.testing.expect(getString(parsed.value.object, "content") == null);
}

test "getString returns null for non-string value" {
    const parsed = try parseTestArgs("{\"count\":42}");
    defer parsed.deinit();
    try std.testing.expect(getString(parsed.value.object, "count") == null);
}

test "getBool extracts boolean values" {
    const parsed = try parseTestArgs("{\"a\":true,\"b\":false}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?bool, true), getBool(parsed.value.object, "a"));
    try std.testing.expectEqual(@as(?bool, false), getBool(parsed.value.object, "b"));
    try std.testing.expect(getBool(parsed.value.object, "missing") == null);
}

test "getInt extracts integer values" {
    const parsed = try parseTestArgs("{\"n\":42,\"neg\":-5}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?i64, 42), getInt(parsed.value.object, "n"));
    try std.testing.expectEqual(@as(?i64, -5), getInt(parsed.value.object, "neg"));
    try std.testing.expect(getInt(parsed.value.object, "missing") == null);
}

test "tool result ok" {
    const r = ToolResult.ok("hello");
    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("hello", r.output);
    try std.testing.expect(r.error_msg == null);
}

test "background turns block shell and allow runtime info" {
    setTurnContext(.{ .origin = .heartbeat });
    defer clearTurnContext();

    const shell_args = try parseTestArgs("{\"command\":\"echo hello\"}");
    defer shell_args.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("shell", shell_args.value.object) != null);

    const runtime_args = try parseTestArgs("{\"section\":\"summary\"}");
    defer runtime_args.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("runtime_info", runtime_args.value.object) == null);
}

test "all background origins allow web search" {
    const args = try parseTestArgs("{\"query\":\"latest zig release\"}");
    defer args.deinit();
    defer clearTurnContext();

    setTurnContext(.{ .origin = .heartbeat });
    try std.testing.expect(toolBlockedForCurrentTurn("web_search", args.value.object) == null);

    setTurnContext(.{ .origin = .scheduler });
    try std.testing.expect(toolBlockedForCurrentTurn("web_search", args.value.object) == null);

    setTurnContext(.{ .origin = .wake });
    try std.testing.expect(toolBlockedForCurrentTurn("web_search", args.value.object) == null);

    setTurnContext(.{ .origin = .proactive });
    try std.testing.expect(toolBlockedForCurrentTurn("web_search", args.value.object) == null);
}

test "background turns allow memory timeline tool" {
    setTurnContext(.{ .origin = .heartbeat });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"query\":\"Neptune\"}");
    defer parsed.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("memory_timeline", parsed.value.object) == null);
}

test "proactive origin allows message tool" {
    setTurnContext(.{ .origin = .proactive });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"content\":\"hello\",\"channel\":\"telegram\",\"chat_id\":\"42\"}");
    defer parsed.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("message", parsed.value.object) == null);
}

test "wake origin blocks message tool" {
    setTurnContext(.{ .origin = .wake });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"content\":\"hello\",\"channel\":\"telegram\",\"chat_id\":\"42\"}");
    defer parsed.deinit();
    const blocked = toolBlockedForCurrentTurn("message", parsed.value.object) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "disabled") != null);
}

test "scheduler-origin maintenance blocks schedule writes" {
    setTurnContext(.{ .origin = .scheduler });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"action\":\"create\",\"expression\":\"*/5 * * * *\",\"command\":\"echo hi\"}");
    defer parsed.deinit();
    const blocked = toolBlockedForCurrentTurn("schedule", parsed.value.object) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "schedule ensure") != null);
}

test "wake origin allows schedule ensure only" {
    setTurnContext(.{ .origin = .wake });
    defer clearTurnContext();

    const ensure_parsed = try parseTestArgs("{\"action\":\"ensure\",\"expression\":\"*/5 * * * *\",\"command\":\"echo hi\"}");
    defer ensure_parsed.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("schedule", ensure_parsed.value.object) == null);

    const parsed = try parseTestArgs("{\"action\":\"create\",\"expression\":\"*/5 * * * *\",\"command\":\"echo hi\"}");
    defer parsed.deinit();
    const blocked = toolBlockedForCurrentTurn("schedule", parsed.value.object) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "schedule ensure") != null);
}

test "proactive origin blocks schedule ensure" {
    setTurnContext(.{ .origin = .proactive });
    defer clearTurnContext();

    const ensure_parsed = try parseTestArgs("{\"action\":\"ensure\",\"expression\":\"*/5 * * * *\",\"command\":\"echo hi\"}");
    defer ensure_parsed.deinit();
    const blocked = toolBlockedForCurrentTurn("schedule", ensure_parsed.value.object) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "wake turns") != null);
}

test "proactive origin allows composio read-only execute" {
    setTurnContext(.{ .origin = .proactive });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"action\":\"execute\",\"tool_slug\":\"gmail-list-messages\"}");
    defer parsed.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("composio", parsed.value.object) == null);
}

test "background turns block composio connect" {
    setTurnContext(.{ .origin = .scheduler });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"action\":\"connect\",\"app\":\"gmail\"}");
    defer parsed.deinit();
    const blocked = toolBlockedForCurrentTurn("composio", parsed.value.object) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "disabled") != null);
}

test "proactive origin allows composio list" {
    setTurnContext(.{ .origin = .proactive });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"action\":\"list\",\"app\":\"gmail\"}");
    defer parsed.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("composio", parsed.value.object) == null);
}

test "wake origin blocks composio list" {
    setTurnContext(.{ .origin = .wake });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"action\":\"list\",\"app\":\"gmail\"}");
    defer parsed.deinit();
    const blocked = toolBlockedForCurrentTurn("composio", parsed.value.object) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "disabled") != null);
}

test "background turns allow composio read-only execute only in proactive origin" {
    setTurnContext(.{ .origin = .proactive });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"action\":\"execute\",\"tool_slug\":\"gmail-list-messages\"}");
    defer parsed.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("composio", parsed.value.object) == null);
}

test "background turns block composio write execute" {
    setTurnContext(.{ .origin = .heartbeat });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"action\":\"execute\",\"tool_slug\":\"gmail-send-email\"}");
    defer parsed.deinit();
    const blocked = toolBlockedForCurrentTurn("composio", parsed.value.object) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "disabled") != null);
}

test "origin gate honors background_safe metadata for task_list/task_get" {
    setTurnContext(.{ .origin = .heartbeat });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{}");
    defer parsed.deinit();
    try std.testing.expect(toolBlockedForCurrentTurn("task_list", parsed.value.object) == null);
    try std.testing.expect(toolBlockedForCurrentTurn("task_get", parsed.value.object) == null);
}

test "origin gate blocks mutating tools lacking background_safe" {
    setTurnContext(.{ .origin = .heartbeat });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{}");
    defer parsed.deinit();
    // pushover is mutating and not background_safe
    try std.testing.expect(toolBlockedForCurrentTurn("pushover", parsed.value.object) != null);
    // shell is always explicitly blocked regardless
    try std.testing.expect(toolBlockedForCurrentTurn("shell", parsed.value.object) != null);
}

test "origin gate allows read-only tools without background_safe flag" {
    setTurnContext(.{ .origin = .heartbeat });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{}");
    defer parsed.deinit();
    // cron_list is read_only but not marked background_safe; it still inspects
    // durable state and is safe to invoke on background turns.
    try std.testing.expect(toolBlockedForCurrentTurn("cron_list", parsed.value.object) == null);
}

test "tool result fail" {
    const r = ToolResult.fail("boom");
    try std.testing.expect(!r.success);
    try std.testing.expectEqualStrings("", r.output);
    try std.testing.expectEqualStrings("boom", r.error_msg.?);
}

test "default tools returns four" {
    const tools = try defaultTools(std.testing.allocator, "/tmp/yc_test");
    defer {
        // Free the heap-allocated tool structs
        std.testing.allocator.destroy(@as(*shell.ShellTool, @ptrCast(@alignCast(tools[0].ptr))));
        std.testing.allocator.destroy(@as(*file_read.FileReadTool, @ptrCast(@alignCast(tools[1].ptr))));
        std.testing.allocator.destroy(@as(*file_write.FileWriteTool, @ptrCast(@alignCast(tools[2].ptr))));
        std.testing.allocator.destroy(@as(*file_edit.FileEditTool, @ptrCast(@alignCast(tools[3].ptr))));
        std.testing.allocator.free(tools);
    }
    try std.testing.expectEqual(@as(usize, 4), tools.len);

    // Verify names
    try std.testing.expectEqualStrings("shell", tools[0].name());
    try std.testing.expectEqualStrings("file_read", tools[1].name());
    try std.testing.expectEqualStrings("file_write", tools[2].name());
    try std.testing.expectEqualStrings("file_edit", tools[3].name());
}

test "all tools has descriptions" {
    const tools = try defaultTools(std.testing.allocator, "/tmp/yc_test");
    defer {
        std.testing.allocator.destroy(@as(*shell.ShellTool, @ptrCast(@alignCast(tools[0].ptr))));
        std.testing.allocator.destroy(@as(*file_read.FileReadTool, @ptrCast(@alignCast(tools[1].ptr))));
        std.testing.allocator.destroy(@as(*file_write.FileWriteTool, @ptrCast(@alignCast(tools[2].ptr))));
        std.testing.allocator.destroy(@as(*file_edit.FileEditTool, @ptrCast(@alignCast(tools[3].ptr))));
        std.testing.allocator.free(tools);
    }
    for (tools) |t| {
        try std.testing.expect(t.description().len > 0);
    }
}

test "all tools have parameter schemas" {
    const tools = try defaultTools(std.testing.allocator, "/tmp/yc_test");
    defer {
        std.testing.allocator.destroy(@as(*shell.ShellTool, @ptrCast(@alignCast(tools[0].ptr))));
        std.testing.allocator.destroy(@as(*file_read.FileReadTool, @ptrCast(@alignCast(tools[1].ptr))));
        std.testing.allocator.destroy(@as(*file_write.FileWriteTool, @ptrCast(@alignCast(tools[2].ptr))));
        std.testing.allocator.destroy(@as(*file_edit.FileEditTool, @ptrCast(@alignCast(tools[3].ptr))));
        std.testing.allocator.free(tools);
    }
    for (tools) |t| {
        const json = t.parametersJson();
        try std.testing.expect(json.len > 0);
        // Should be valid JSON object
        try std.testing.expect(json[0] == '{');
    }
}

test "tool spec generation" {
    const tools = try defaultTools(std.testing.allocator, "/tmp/yc_test");
    defer {
        std.testing.allocator.destroy(@as(*shell.ShellTool, @ptrCast(@alignCast(tools[0].ptr))));
        std.testing.allocator.destroy(@as(*file_read.FileReadTool, @ptrCast(@alignCast(tools[1].ptr))));
        std.testing.allocator.destroy(@as(*file_write.FileWriteTool, @ptrCast(@alignCast(tools[2].ptr))));
        std.testing.allocator.destroy(@as(*file_edit.FileEditTool, @ptrCast(@alignCast(tools[3].ptr))));
        std.testing.allocator.free(tools);
    }
    for (tools) |t| {
        const s = t.spec();
        try std.testing.expectEqualStrings(t.name(), s.name);
        try std.testing.expectEqualStrings(t.description(), s.description);
        try std.testing.expect(s.parameters_json.len > 0);
    }
}

test "all tools includes extras when enabled" {
    const Config = @import("../config.zig").Config;
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{
        .config = &cfg,
        .http_enabled = true,
        .browser_enabled = true,
    });
    defer deinitTools(std.testing.allocator, tools);
    // base 36 (delegate + spawn dormant by default; +1 for V1.5 todo,
    // +1 for V1.5 day-3 compose_memory; +1 calculator + 1 file_read_hashed
    // + 1 file_edit_hashed from nullclaw cherry-pick; +1 memory_archive
    // + 1 memory_demote from V1.6 cmt11) + http_request + web_fetch +
    // web_search + browser + brain_graph (V1.7-ship S2a)
    // + memory_maintain (V1.9-5 truth-maintenance toolkit)
    // + time_now (V1.9-DX1 wall-clock tool) = 43.
    try std.testing.expectEqual(@as(usize, 43), tools.len);
}

test "all tools excludes extras when disabled" {
    const Config = @import("../config.zig").Config;
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{ .config = &cfg });
    defer deinitTools(std.testing.allocator, tools);
    // Core tool catalog (delegate + spawn gated behind NULLALIS_ENABLE_MULTIAGENT):
    // shell + file_read + file_write + file_edit + file_append + git + image_info + image_generate
    // + memory_store + memory_edit + memory_recall + memory_list + memory_timeline + transcript_read + memory_forget + memory_purge_topic + schedule + todo + compose_memory
    // + cron_add + cron_list + cron_remove + cron_runs + cron_run + cron_update + pushover
    // + runtime_info + skill_registry + message + set_execution_mode + context_snapshot
    // + calculator + file_read_hashed + file_edit_hashed (nullclaw cherry-pick)
    // + memory_archive + memory_demote (V1.6 cmt11) + brain_graph (V1.7-ship S2a)
    // + memory_maintain (V1.9-5 truth-maintenance toolkit)
    // + time_now (V1.9-DX1 wall-clock tool) = 39
    try std.testing.expectEqual(@as(usize, 39), tools.len);
}

test "all tools includes cron and pushover tools" {
    const Config = @import("../config.zig").Config;
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{ .config = &cfg });
    defer deinitTools(std.testing.allocator, tools);

    var saw_cron_add = false;
    var saw_cron_list = false;
    var saw_cron_remove = false;
    var saw_cron_runs = false;
    var saw_cron_run = false;
    var saw_cron_update = false;
    var saw_pushover = false;

    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), "cron_add")) saw_cron_add = true;
        if (std.mem.eql(u8, t.name(), "cron_list")) saw_cron_list = true;
        if (std.mem.eql(u8, t.name(), "cron_remove")) saw_cron_remove = true;
        if (std.mem.eql(u8, t.name(), "cron_runs")) saw_cron_runs = true;
        if (std.mem.eql(u8, t.name(), "cron_run")) saw_cron_run = true;
        if (std.mem.eql(u8, t.name(), "cron_update")) saw_cron_update = true;
        if (std.mem.eql(u8, t.name(), "pushover")) saw_pushover = true;
    }

    try std.testing.expect(saw_cron_add);
    try std.testing.expect(saw_cron_list);
    try std.testing.expect(saw_cron_remove);
    try std.testing.expect(saw_cron_runs);
    try std.testing.expect(saw_cron_run);
    try std.testing.expect(saw_cron_update);
    try std.testing.expect(saw_pushover);
}

test "all tools propagates sandbox config to shell and git" {
    const Config = @import("../config.zig").Config;
    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.security.sandbox.enabled = true;
    cfg.security.sandbox.backend = .none;

    const allowed_paths = [_][]const u8{"/tmp/yc_allowed"};
    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{
        .config = &cfg,
        .allowed_paths = &allowed_paths,
    });
    defer deinitTools(std.testing.allocator, tools);

    var saw_shell = false;
    var saw_git = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), "shell")) {
            const st: *shell.ShellTool = @ptrCast(@alignCast(t.ptr));
            try std.testing.expect(st.sandbox_enabled);
            try std.testing.expectEqual(@as(@import("../config_types.zig").SandboxBackend, .none), st.sandbox_backend);
            saw_shell = true;
        } else if (std.mem.eql(u8, t.name(), "git_operations")) {
            const gt: *git.GitTool = @ptrCast(@alignCast(t.ptr));
            try std.testing.expect(gt.sandbox_enabled);
            try std.testing.expectEqual(@as(@import("../config_types.zig").SandboxBackend, .none), gt.sandbox_backend);
            try std.testing.expectEqual(@as(usize, 1), gt.allowed_paths.len);
            try std.testing.expectEqualStrings("/tmp/yc_allowed", gt.allowed_paths[0]);
            saw_git = true;
        }
    }
    try std.testing.expect(saw_shell);
    try std.testing.expect(saw_git);
}

test "all tools binds runtime_info to finalized tool slice" {
    const Config = @import("../config.zig").Config;
    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{ .config = &cfg });
    defer deinitTools(std.testing.allocator, tools);

    setTurnContext(.{
        .origin = .user,
        .session_key = "agent:test",
        .provider = "openrouter",
        .model = "moonshotai/kimi-k2.5",
    });
    defer clearTurnContext();

    const parsed = try parseTestArgs("{\"section\":\"summary\"}");
    defer parsed.deinit();

    for (tools) |t| {
        if (!std.mem.eql(u8, t.name(), "runtime_info")) continue;
        const result = try t.execute(std.testing.allocator, parsed.value.object);
        defer std.testing.allocator.free(result.output);
        try std.testing.expect(result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "\"runtime_info\"") != null);
        return;
    }
    return error.TestUnexpectedResult;
}

test "all tools includes message when event bus is available" {
    const Config = @import("../config.zig").Config;
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    var event_bus = bus.Bus.init();
    defer event_bus.close();

    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{
        .config = &cfg,
        .event_bus = &event_bus,
    });
    defer deinitTools(std.testing.allocator, tools);

    // 36 core tools (was 30 — V1.5 day-3 added `compose_memory`; nullclaw
    // cherry-pick added calculator + file_read_hashed + file_edit_hashed;
    // V1.6 cmt11 added memory_archive + memory_demote);
    // delegate + spawn gated behind NULLALIS_ENABLE_MULTIAGENT.
    // V1.7-ship S2a added brain_graph → 37.
    // V1.9-5 added memory_maintain (truth-maintenance toolkit) → 38.
    // V1.9-DX1 added time_now (wall-clock awareness) → 39.
    try std.testing.expectEqual(@as(usize, 39), tools.len);

    var found_message = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), "message")) {
            found_message = true;
            break;
        }
    }
    try std.testing.expect(found_message);
}

test "all tools excludes spawn delegate and message in subagent profile" {
    const Config = @import("../config.zig").Config;
    const subagent_mod = @import("../subagent.zig");

    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = subagent_mod.SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();
    var event_bus = bus.Bus.init();
    defer event_bus.close();

    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{
        .config = &cfg,
        .tool_profile = .subagent,
        .subagent_manager = &manager,
        .event_bus = &event_bus,
    });
    defer deinitTools(std.testing.allocator, tools);

    for (tools) |t| {
        try std.testing.expect(!std.mem.eql(u8, t.name(), "spawn"));
        try std.testing.expect(!std.mem.eql(u8, t.name(), "delegate"));
        try std.testing.expect(!std.mem.eql(u8, t.name(), "message"));
    }
}

test "spawn + delegate are dormant by default in main profile" {
    const Config = @import("../config.zig").Config;
    const subagent_mod = @import("../subagent.zig");

    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = subagent_mod.SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();
    var event_bus = bus.Bus.init();
    defer event_bus.close();

    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{
        .config = &cfg,
        .tool_profile = .main,
        .subagent_manager = &manager,
        .event_bus = &event_bus,
    });
    defer deinitTools(std.testing.allocator, tools);

    // delegate + spawn are gated behind NULLALIS_ENABLE_MULTIAGENT. Absent
    // the env var, neither should register. message must stay present.
    var found_spawn = false;
    var found_delegate = false;
    var found_message = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), "spawn")) found_spawn = true;
        if (std.mem.eql(u8, t.name(), "delegate")) found_delegate = true;
        if (std.mem.eql(u8, t.name(), "message")) found_message = true;
    }

    try std.testing.expect(!found_spawn);
    try std.testing.expect(!found_delegate);
    try std.testing.expect(found_message);
}

test "all tools: spawn not registered when NULLALIS_ENABLE_MULTIAGENT unset" {
    const Config = @import("../config.zig").Config;
    const subagent_mod = @import("../subagent.zig");

    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = subagent_mod.SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    const tools = try allTools(std.testing.allocator, "/tmp/yc_test", .{
        .config = &cfg,
        .tool_profile = .main,
        .subagent_manager = &manager,
    });
    defer deinitTools(std.testing.allocator, tools);

    // Verify the dormant-by-default gate holds: spawn absent from catalog.
    for (tools) |t| {
        try std.testing.expect(!std.mem.eql(u8, t.name(), "spawn"));
    }
}

test "bindMemoryTools matches by vtable, not by colliding tool name" {
    const FakeCollidingTool = struct {
        sentinel: usize = 0xDEADBEEF,

        pub const tool_name = "memory_store";
        pub const tool_description = "fake";
        pub const tool_params = "{}";
        pub const vtable = ToolVTable(@This());

        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(_: *@This(), _: std.mem.Allocator, _: JsonObjectMap) anyerror!ToolResult {
            return ToolResult.ok("");
        }
    };

    const NoneMemory = @import("../memory/root.zig").NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var real_memory_store = memory_store.MemoryStoreTool{};
    var fake_memory_store_name = FakeCollidingTool{};
    const tools = [_]Tool{
        real_memory_store.tool(),
        fake_memory_store_name.tool(),
    };

    bindMemoryTools(&tools, backend.memory());

    try std.testing.expect(real_memory_store.memory != null);
    try std.testing.expectEqual(@as(usize, 0xDEADBEEF), fake_memory_store_name.sentinel);
}

// ── Default metadata registry tests ─────────────────────────────────

test "defaultMetadataRegistry has unique tool names" {
    const registry = defaultMetadataRegistry();
    for (registry, 0..) |entry, i| {
        for (registry[i + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.name, other.name)) {
                std.debug.print("duplicate name in registry: {s}\n", .{entry.name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "defaultMetadataRegistry flags all validate" {
    const registry = defaultMetadataRegistry();
    for (registry) |entry| {
        try entry.flags.validate();
    }
}

test "defaultMetadataRegistry classifies known read-only tools" {
    const registry = defaultMetadataRegistry();
    const read_only = [_][]const u8{
        "runtime_info",   "file_read",      "image_info",       "memory_recall",
        "memory_list",    "memory_timeline", "cron_list",       "cron_runs",
        "task_list",      "task_get",        "web_fetch",       "web_search",
        "screenshot",
    };
    for (read_only) |name| {
        const m = metadata.lookupMetadata(name, registry) orelse {
            std.debug.print("missing registry entry: {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(m.flags.read_only);
        try std.testing.expect(!m.flags.mutating);
    }
}

test "defaultMetadataRegistry classifies known mutating tools" {
    // S6.3 — delegate + spawn are no longer in the default-lane registry
    // when NULLALIS_ENABLE_MULTIAGENT is unset. They're still in
    // `DEFAULT_TOOL_METADATA` (the extended static slice) and still
    // classified correctly there — see the separate "multiagent-gated
    // tools still classify" test below.
    const registry = defaultMetadataRegistry();
    const mutating = [_][]const u8{
        "shell",         "file_write",    "file_edit",     "file_append",
        "git_operations", "memory_store", "memory_edit",   "memory_forget",
        "schedule",      "message",
        "pushover",      "cron_add",      "cron_remove",   "cron_update",
        "cron_run",      "http_request",  "browser",       "browser_open",
        "composio",      "skill_registry", "task_stop",
    };
    for (mutating) |name| {
        const m = metadata.lookupMetadata(name, registry) orelse {
            std.debug.print("missing registry entry: {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(m.flags.mutating);
        try std.testing.expect(!m.flags.read_only);
        try std.testing.expect(!m.flags.background_safe);
    }
}

test "multiagent-gated tools (delegate, spawn) still classify as mutating + non-background in the extended registry" {
    // The default lane filters delegate + spawn out of the registry
    // unless NULLALIS_ENABLE_MULTIAGENT is set. But the classifications
    // must still be correct in DEFAULT_TOOL_METADATA for the multiagent
    // path to use them. This test guards that they stay classified
    // correctly even though operators on the default lane can't see them.
    const registry: []const metadata.ToolMetadata = &DEFAULT_TOOL_METADATA;
    for ([_][]const u8{ "delegate", "spawn" }) |name| {
        const m = metadata.lookupMetadata(name, registry) orelse {
            std.debug.print("missing multiagent registry entry: {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(m.flags.mutating);
        try std.testing.expect(!m.flags.read_only);
        try std.testing.expect(!m.flags.background_safe);
    }
}

test "defaultMetadataRegistry only whitelists expected background_safe tools" {
    const registry = defaultMetadataRegistry();
    const background_safe_names = [_][]const u8{
        "runtime_info",    "file_read",      "memory_recall",
        "memory_list",     "memory_timeline", "transcript_read",
        "web_fetch",       "web_search",     "task_list",
        "task_get",        "set_execution_mode", "context_snapshot",
    };

    // Everything in the whitelist must be background_safe.
    for (background_safe_names) |name| {
        const m = metadata.lookupMetadata(name, registry) orelse return error.TestUnexpectedResult;
        try std.testing.expect(m.flags.background_safe);
    }

    // Nothing else may be background_safe.
    for (registry) |entry| {
        var expected = false;
        for (background_safe_names) |name| {
            if (std.mem.eql(u8, entry.name, name)) expected = true;
        }
        if (!expected and entry.flags.background_safe) {
            std.debug.print("unexpected background_safe tool: {s}\n", .{entry.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "defaultMetadataRegistry keeps sensitive tools off the background lane" {
    // S6.3 — as above: delegate + spawn are filtered out of the default
    // registry when NULLALIS_ENABLE_MULTIAGENT is unset. Background-lane
    // safety for those two is asserted in the adjacent test against the
    // extended `DEFAULT_TOOL_METADATA` slice.
    const registry = defaultMetadataRegistry();
    const must_not_be_background = [_][]const u8{
        "message", "schedule", "composio", "shell",
    };
    for (must_not_be_background) |name| {
        const m = metadata.lookupMetadata(name, registry) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!m.flags.background_safe);
    }
}

test "refineMetadata downgrades schedule list/get/runs to read-only" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("schedule", registry).?;
    const read_actions = [_][]const u8{ "list", "get", "runs" };
    for (read_actions) |action| {
        const buf = try std.fmt.allocPrint(std.testing.allocator, "{{\"action\":\"{s}\"}}", .{action});
        defer std.testing.allocator.free(buf);
        const parsed = try parseTestArgs(buf);
        defer parsed.deinit();
        const refined = refineMetadata(base, parsed.value.object);
        try std.testing.expect(refined.flags.read_only);
        try std.testing.expect(!refined.flags.mutating);
    }
}

test "refineMetadata keeps schedule create/update/remove mutating" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("schedule", registry).?;
    const mutating_actions = [_][]const u8{ "create", "update", "remove", "ensure" };
    for (mutating_actions) |action| {
        const buf = try std.fmt.allocPrint(std.testing.allocator, "{{\"action\":\"{s}\"}}", .{action});
        defer std.testing.allocator.free(buf);
        const parsed = try parseTestArgs(buf);
        defer parsed.deinit();
        const refined = refineMetadata(base, parsed.value.object);
        try std.testing.expect(refined.flags.mutating);
        try std.testing.expect(!refined.flags.read_only);
    }
}

test "refineMetadata downgrades git status/diff/log/branch" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("git_operations", registry).?;
    const read_ops = [_][]const u8{ "status", "diff", "log", "branch" };
    for (read_ops) |op| {
        const buf = try std.fmt.allocPrint(std.testing.allocator, "{{\"operation\":\"{s}\"}}", .{op});
        defer std.testing.allocator.free(buf);
        const parsed = try parseTestArgs(buf);
        defer parsed.deinit();
        const refined = refineMetadata(base, parsed.value.object);
        try std.testing.expect(refined.flags.read_only);
    }
}

test "refineMetadata keeps git commit/add/checkout/stash mutating" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("git_operations", registry).?;
    const mutating_ops = [_][]const u8{ "commit", "add", "checkout", "stash" };
    for (mutating_ops) |op| {
        const buf = try std.fmt.allocPrint(std.testing.allocator, "{{\"operation\":\"{s}\"}}", .{op});
        defer std.testing.allocator.free(buf);
        const parsed = try parseTestArgs(buf);
        defer parsed.deinit();
        const refined = refineMetadata(base, parsed.value.object);
        try std.testing.expect(refined.flags.mutating);
    }
}

test "refineMetadata downgrades HTTP GET/HEAD/OPTIONS" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("http_request", registry).?;

    const safe_methods = [_][]const u8{ "GET", "get", "HEAD", "OPTIONS" };
    for (safe_methods) |method| {
        const buf = try std.fmt.allocPrint(std.testing.allocator, "{{\"url\":\"https://x\",\"method\":\"{s}\"}}", .{method});
        defer std.testing.allocator.free(buf);
        const parsed = try parseTestArgs(buf);
        defer parsed.deinit();
        try std.testing.expect(refineMetadata(base, parsed.value.object).flags.read_only);
    }

    const default_parsed = try parseTestArgs("{\"url\":\"https://x\"}");
    defer default_parsed.deinit();
    try std.testing.expect(refineMetadata(base, default_parsed.value.object).flags.read_only);
}

test "refineMetadata keeps HTTP POST/PUT/DELETE/PATCH mutating" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("http_request", registry).?;
    const mutating_methods = [_][]const u8{ "POST", "PUT", "DELETE", "PATCH" };
    for (mutating_methods) |method| {
        const buf = try std.fmt.allocPrint(std.testing.allocator, "{{\"url\":\"https://x\",\"method\":\"{s}\"}}", .{method});
        defer std.testing.allocator.free(buf);
        const parsed = try parseTestArgs(buf);
        defer parsed.deinit();
        try std.testing.expect(refineMetadata(base, parsed.value.object).flags.mutating);
    }
}

test "refineMetadata downgrades composio list/get and read-only execute" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("composio", registry).?;

    const list_parsed = try parseTestArgs("{\"action\":\"list\",\"app\":\"gmail\"}");
    defer list_parsed.deinit();
    try std.testing.expect(refineMetadata(base, list_parsed.value.object).flags.read_only);

    const read_execute_parsed = try parseTestArgs("{\"action\":\"execute\",\"tool_slug\":\"gmail-list-messages\"}");
    defer read_execute_parsed.deinit();
    try std.testing.expect(refineMetadata(base, read_execute_parsed.value.object).flags.read_only);

    const send_parsed = try parseTestArgs("{\"action\":\"execute\",\"tool_slug\":\"gmail-send-email\"}");
    defer send_parsed.deinit();
    try std.testing.expect(refineMetadata(base, send_parsed.value.object).flags.mutating);

    const connect_parsed = try parseTestArgs("{\"action\":\"connect\",\"app\":\"gmail\"}");
    defer connect_parsed.deinit();
    try std.testing.expect(refineMetadata(base, connect_parsed.value.object).flags.mutating);
}

// D1.14c regression: verify the cache opt-ins activate correctly
// across the three flagged tools. web_search + memory_recall opt in
// at the registry level (read-only base); composio opts in only via
// refineMetadata (because base is mutating=true). All three must
// surface cacheable=true + nonzero TTL + correct scope to
// canonicalMetadataForCall consumers (the cache integration in
// agent/root.zig).
test "D1.14c — web_search/memory_recall/composio-list cache flags wired" {
    const registry = defaultMetadataRegistry();

    // web_search — read-only base, .global scope, 30s TTL
    const ws = metadata.lookupMetadata("web_search", registry).?;
    try std.testing.expect(ws.flags.cacheable);
    try std.testing.expectEqual(@as(u32, 30), ws.cache_ttl_secs);
    try std.testing.expectEqual(metadata.CacheScope.global, ws.cache_scope);

    // memory_recall — read-only base, .session scope, 300s TTL
    const mr = metadata.lookupMetadata("memory_recall", registry).?;
    try std.testing.expect(mr.flags.cacheable);
    try std.testing.expectEqual(@as(u32, 300), mr.cache_ttl_secs);
    try std.testing.expectEqual(metadata.CacheScope.session, mr.cache_scope);

    // composio base — mutating, NOT cacheable at base (passes flags.validate)
    const composio_base = metadata.lookupMetadata("composio", registry).?;
    try std.testing.expect(!composio_base.flags.cacheable);
    try std.testing.expect(composio_base.flags.mutating);

    // composio list — refineMetadata adds cacheable=true + .tenant + 60s
    const list_parsed = try parseTestArgs("{\"action\":\"list\",\"app\":\"gmail\"}");
    defer list_parsed.deinit();
    const list_refined = refineMetadata(composio_base, list_parsed.value.object);
    try std.testing.expect(list_refined.flags.cacheable);
    try std.testing.expect(!list_refined.flags.mutating);
    try std.testing.expectEqual(@as(u32, 60), list_refined.cache_ttl_secs);
    try std.testing.expectEqual(metadata.CacheScope.tenant, list_refined.cache_scope);

    // composio send (mutating) — must NOT be flagged cacheable post-refine
    const send_parsed = try parseTestArgs("{\"action\":\"execute\",\"tool_slug\":\"gmail-send-email\"}");
    defer send_parsed.deinit();
    const send_refined = refineMetadata(composio_base, send_parsed.value.object);
    try std.testing.expect(!send_refined.flags.cacheable);
    try std.testing.expect(send_refined.flags.mutating);
}

test "refineMetadata downgrades skill_registry list/search" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("skill_registry", registry).?;

    const list_parsed = try parseTestArgs("{\"action\":\"list\"}");
    defer list_parsed.deinit();
    try std.testing.expect(refineMetadata(base, list_parsed.value.object).flags.read_only);

    const search_parsed = try parseTestArgs("{\"action\":\"search\",\"query\":\"animate\"}");
    defer search_parsed.deinit();
    try std.testing.expect(refineMetadata(base, search_parsed.value.object).flags.read_only);

    const install_parsed = try parseTestArgs("{\"action\":\"install\",\"skill_ref\":\"x/y\"}");
    defer install_parsed.deinit();
    try std.testing.expect(refineMetadata(base, install_parsed.value.object).flags.mutating);
}

test "refineMetadata leaves already-read-only and unrelated tools unchanged" {
    const registry = defaultMetadataRegistry();
    const read_base = metadata.lookupMetadata("file_read", registry).?;
    const parsed = try parseTestArgs("{\"action\":\"anything\"}");
    defer parsed.deinit();
    const refined_read = refineMetadata(read_base, parsed.value.object);
    try std.testing.expectEqual(read_base.flags.read_only, refined_read.flags.read_only);
    try std.testing.expectEqual(read_base.flags.background_safe, refined_read.flags.background_safe);

    // shell has no action-dependent downgrade; stays mutating.
    const shell_base = metadata.lookupMetadata("shell", registry).?;
    const refined_shell = refineMetadata(shell_base, parsed.value.object);
    try std.testing.expect(refined_shell.flags.mutating);
    try std.testing.expect(!refined_shell.flags.read_only);
}

test "refineMetadata does not mark downgraded calls background_safe" {
    const registry = defaultMetadataRegistry();
    const base = metadata.lookupMetadata("git_operations", registry).?;
    const parsed = try parseTestArgs("{\"operation\":\"status\"}");
    defer parsed.deinit();
    const refined = refineMetadata(base, parsed.value.object);
    try std.testing.expect(refined.flags.read_only);
    try std.testing.expect(!refined.flags.background_safe);
}

test "defaultMetadataRegistry unknown tool falls back to conservative" {
    const registry = defaultMetadataRegistry();
    try std.testing.expect(metadata.lookupMetadata("mcp_some_unknown_tool", registry) == null);
    const fallback = metadata.ToolMetadata.conservative("mcp_some_unknown_tool");
    try std.testing.expect(fallback.flags.mutating);
    try std.testing.expect(!fallback.flags.read_only);
    try std.testing.expect(!fallback.flags.background_safe);
}

test "canonicalMetadataForName resolves known tools via real registry (no empty-slice drift)" {
    // Regression: `SecurityPolicy.resolveApproval` used to look up metadata in
    // an empty slice, which forced every known tool to the conservative
    // (mutating) default. Callers MUST use canonicalMetadataForName instead,
    // and it MUST read from defaultMetadataRegistry().
    const read = canonicalMetadataForName("file_read");
    try std.testing.expect(read.flags.read_only);
    try std.testing.expect(!read.flags.mutating);

    const mut = canonicalMetadataForName("shell");
    try std.testing.expect(mut.flags.mutating);
    try std.testing.expect(!mut.flags.read_only);

    const unk = canonicalMetadataForName("mcp_some_unknown_tool");
    try std.testing.expect(unk.flags.mutating);
    try std.testing.expect(!unk.flags.read_only);
    try std.testing.expectEqual(metadata.RiskLevel.high, unk.risk_level);
}

test "canonicalMetadataForCall applies args-aware refinement (schedule.list, git status, GET)" {
    const allocator = std.testing.allocator;

    const sched = canonicalMetadataForCall(allocator, "schedule", "{\"action\":\"list\"}");
    try std.testing.expect(sched.flags.read_only);
    try std.testing.expect(!sched.flags.mutating);

    const git_read = canonicalMetadataForCall(allocator, "git_operations", "{\"operation\":\"status\"}");
    try std.testing.expect(git_read.flags.read_only);

    const git_write = canonicalMetadataForCall(allocator, "git_operations", "{\"operation\":\"commit\"}");
    try std.testing.expect(git_write.flags.mutating);
    try std.testing.expect(!git_write.flags.read_only);

    const http_get = canonicalMetadataForCall(allocator, "http_request", "{\"method\":\"GET\"}");
    try std.testing.expect(http_get.flags.read_only);

    const http_post = canonicalMetadataForCall(allocator, "http_request", "{\"method\":\"POST\"}");
    try std.testing.expect(http_post.flags.mutating);
}

test "canonicalMetadataForCall falls back to base metadata on invalid JSON" {
    const allocator = std.testing.allocator;
    const bad = canonicalMetadataForCall(allocator, "shell", "not-json");
    try std.testing.expect(bad.flags.mutating);
    try std.testing.expect(!bad.flags.read_only);
}

test {
    @import("std").testing.refAllDecls(@This());
}
