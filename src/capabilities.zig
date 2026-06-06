const std = @import("std");
const build_options = @import("build_options");
const channel_catalog = @import("channel_catalog.zig");
const config_mod = @import("config.zig");
const memory_registry = @import("memory/engines/registry.zig");
const tools_mod = @import("tools/root.zig");

const Config = config_mod.Config;
const Tool = tools_mod.Tool;

const core_tool_names = [_][]const u8{
    "shell",
    "file_read",
    "file_write",
    "file_edit",
    "file_append",
    "git_operations",
    "image_info",
    "memory_store",
    "memory_edit",
    "memory_recall",
    "memory_list",
    "memory_timeline",
    "memory_forget",
    "delegate",
    "schedule",
    "cron_add",
    "cron_list",
    "cron_remove",
    "cron_runs",
    "cron_run",
    "cron_update",
    "pushover",
    "runtime_info",
    "skill_registry",
    "spawn",
    "screenshot",
    // V1.12 — wiki_link: on-demand entity-mention extraction. Per-3-turn
    // auto-trigger handles forward-flow ingestion; this tool surfaces it
    // for explicit invocation (user "relink this" / button / admin CLI).
    "wiki_link",
};

const optional_tool_names = [_][]const u8{
    "http_request",
    "web_fetch",
    "web_search",
    "browser_new_session",
    "browser_navigate",
    "browser_snapshot",
    "browser_exec",
    "browser_close_session",
    "composio",
    "message",
    // hardware_board_info, hardware_memory, i2c, spi: removed D19
    // (2026-04-25). Hardware/IoT tool surface stripped in V1
    // convergence; no consumers, no runtime registration.
};

const ChannelMode = enum {
    build_enabled,
    build_disabled,
    configured,
};

const EngineMode = enum {
    build_enabled,
    build_disabled,
};

const OptionalToolMode = enum {
    enabled,
    disabled,
};

fn runtimeHasTool(runtime_tools: ?[]const Tool, name: []const u8) bool {
    const tools = runtime_tools orelse return false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), name)) return true;
    }
    return false;
}

fn optionalToolEnabledByConfig(cfg: *const Config, name: []const u8) bool {
    if (std.mem.eql(u8, name, "http_request")) return cfg.http_request.enabled;
    if (std.mem.eql(u8, name, "web_fetch")) return cfg.http_request.enabled;
    if (std.mem.eql(u8, name, "web_search")) return cfg.http_request.enabled;
    // agent_browser backend — the five browser_* tools are the only
    // browser_-prefixed optional names, so a prefix check is safe and
    // keeps this in lockstep with optional_tool_names.
    if (std.mem.startsWith(u8, name, "browser_")) return cfg.browser.enabled and std.mem.eql(u8, cfg.browser.backend, "agent_browser");
    if (std.mem.eql(u8, name, "composio")) return cfg.composio.enabled and cfg.composio.api_key != null;
    // message depends on event_bus wiring at runtime, not config alone.
    if (std.mem.eql(u8, name, "message")) return false;
    // hardware_board_info / hardware_memory / i2c / spi gates removed
    // D19 (2026-04-25) alongside the hardware tool surface itself.
    return false;
}

fn collectEstimatedToolNamesFromConfig(
    allocator: std.mem.Allocator,
    cfg: *const Config,
) ![]const []const u8 {
    // agent_browser backend — mirror the gateway: construct a throwaway
    // OrchestratorClient only when the backend is active, so the estimated
    // tool set advertises the browser_* family iff it would really register.
    // This is an estimation-only path (no live requests are issued), so the
    // client lives for the duration of this function alongside the tools.
    const OrchestratorClient = @import("browser_backend/client.zig").OrchestratorClient;
    var ab_client: OrchestratorClient = undefined;
    const agent_browser_client: ?*OrchestratorClient =
        if (cfg.browser.enabled and std.mem.eql(u8, cfg.browser.backend, "agent_browser")) blk: {
            ab_client = .{ .base_url = cfg.browser.agent_browser.orchestrator_url, .timeout_ms = cfg.browser.agent_browser.timeout_ms };
            break :blk &ab_client;
        } else null;

    const estimated_tools = try tools_mod.allTools(allocator, cfg.workspace_dir, .{
        .config = cfg,
        .http_enabled = cfg.http_request.enabled,
        .screenshot_enabled = true,
        .composio_api_key = if (cfg.composio.enabled) cfg.composio.api_key else null,
        .agent_browser_client = agent_browser_client,
        .agents = cfg.agents,
        .tools_config = cfg.tools,
        .allowed_paths = cfg.autonomy.allowed_paths,
    });
    defer tools_mod.deinitTools(allocator, estimated_tools);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (estimated_tools) |tool| {
        try out.append(allocator, tool.name());
    }
    return try out.toOwnedSlice(allocator);
}

fn collectChannelNames(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    mode: ChannelMode,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    for (channel_catalog.known_channels) |meta| {
        const enabled = channel_catalog.isBuildEnabled(meta.id);
        const configured = if (cfg_opt) |cfg| channel_catalog.configuredCount(cfg, meta.id) > 0 else false;
        const include = switch (mode) {
            .build_enabled => enabled,
            .build_disabled => !enabled,
            .configured => enabled and configured,
        };
        if (!include) continue;
        try out.append(allocator, meta.key);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectMemoryEngineNames(allocator: std.mem.Allocator, mode: EngineMode) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    for (memory_registry.known_backend_names) |name| {
        const enabled = memory_registry.findBackend(name) != null;
        const include = switch (mode) {
            .build_enabled => enabled,
            .build_disabled => !enabled,
        };
        if (!include) continue;
        try out.append(allocator, name);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectOptionalTools(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    mode: OptionalToolMode,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    const cfg = cfg_opt orelse {
        if (mode == .disabled) {
            for (optional_tool_names) |name| {
                try out.append(allocator, name);
            }
        }
        return try out.toOwnedSlice(allocator);
    };

    for (optional_tool_names) |name| {
        const enabled = optionalToolEnabledByConfig(cfg, name);
        const include = switch (mode) {
            .enabled => enabled,
            .disabled => !enabled,
        };
        if (!include) continue;
        try out.append(allocator, name);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectRuntimeToolNames(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]const []const u8 {
    if (runtime_tools) |tools| {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(allocator);
        for (tools) |t| {
            try out.append(allocator, t.name());
        }
        return try out.toOwnedSlice(allocator);
    }

    if (cfg_opt) |cfg| {
        return collectEstimatedToolNamesFromConfig(allocator, cfg);
    }

    var estimated: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer estimated.deinit(allocator);
    for (core_tool_names) |name| {
        try estimated.append(allocator, name);
    }
    const optional_enabled = try collectOptionalTools(allocator, cfg_opt, .enabled);
    defer allocator.free(optional_enabled);
    for (optional_enabled) |name| {
        try estimated.append(allocator, name);
    }
    return try estimated.toOwnedSlice(allocator);
}

fn joinNames(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    if (names.len == 0) {
        try w.writeAll("(none)");
        return try out.toOwnedSlice(allocator);
    }

    for (names, 0..) |name, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(name);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendJsonStringArray(w: anytype, names: []const []const u8) !void {
    try w.writeAll("[");
    for (names, 0..) |name, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{f}", .{std.json.fmt(name, .{})});
    }
    try w.writeAll("]");
}

pub fn buildManifestJson(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]u8 {
    const runtime_loaded_names = if (runtime_tools) |tools|
        try collectRuntimeToolNames(allocator, cfg_opt, tools)
    else
        try allocator.alloc([]const u8, 0);
    defer allocator.free(runtime_loaded_names);

    const estimated_tool_names = if (runtime_tools == null)
        try collectRuntimeToolNames(allocator, cfg_opt, null)
    else
        try allocator.alloc([]const u8, 0);
    defer allocator.free(estimated_tool_names);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll("{\n");
    try w.print("  \"version\": {f},\n", .{std.json.fmt(build_options.version, .{})});

    const memory_backend = if (cfg_opt) |cfg| cfg.memory.backend else "";
    try w.print("  \"active_memory_backend\": {f},\n", .{std.json.fmt(memory_backend, .{})});

    try w.writeAll("  \"channels\": [\n");
    for (channel_catalog.known_channels, 0..) |meta, i| {
        const enabled = channel_catalog.isBuildEnabled(meta.id);
        const configured_count: usize = if (cfg_opt) |cfg| channel_catalog.configuredCount(cfg, meta.id) else 0;
        const configured = enabled and configured_count > 0;
        if (i != 0) try w.writeAll(",\n");
        try w.print(
            "    {{\"key\": {f}, \"label\": {f}, \"enabled_in_build\": {}, \"configured\": {}, \"configured_count\": {d}}}",
            .{
                std.json.fmt(meta.key, .{}),
                std.json.fmt(meta.label, .{}),
                enabled,
                configured,
                configured_count,
            },
        );
    }
    try w.writeAll("\n  ],\n");

    try w.writeAll("  \"memory_engines\": [\n");
    for (memory_registry.known_backend_names, 0..) |name, i| {
        const enabled = memory_registry.findBackend(name) != null;
        const configured = cfg_opt != null and std.mem.eql(u8, cfg_opt.?.memory.backend, name);
        if (i != 0) try w.writeAll(",\n");
        try w.print(
            "    {{\"name\": {f}, \"enabled_in_build\": {}, \"configured\": {}}}",
            .{ std.json.fmt(name, .{}), enabled, configured },
        );
    }
    try w.writeAll("\n  ],\n");

    try w.writeAll("  \"tools\": {\n");
    try w.writeAll("    \"runtime_loaded\": ");
    try appendJsonStringArray(w, runtime_loaded_names);
    try w.writeAll(",\n");

    try w.writeAll("    \"estimated_enabled_from_config\": ");
    try appendJsonStringArray(w, estimated_tool_names);
    try w.writeAll(",\n");

    const optional_enabled = try collectOptionalTools(allocator, cfg_opt, .enabled);
    defer allocator.free(optional_enabled);
    const optional_disabled = try collectOptionalTools(allocator, cfg_opt, .disabled);
    defer allocator.free(optional_disabled);

    try w.writeAll("    \"optional_enabled_by_config\": ");
    try appendJsonStringArray(w, optional_enabled);
    try w.writeAll(",\n");

    try w.writeAll("    \"optional_disabled_by_config\": ");
    try appendJsonStringArray(w, optional_disabled);
    try w.writeAll("\n  }\n");

    try w.writeAll("}\n");
    return try out.toOwnedSlice(allocator);
}

pub fn buildSummaryText(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]u8 {
    const channels_enabled = try collectChannelNames(allocator, cfg_opt, .build_enabled);
    defer allocator.free(channels_enabled);
    const channels_disabled = try collectChannelNames(allocator, cfg_opt, .build_disabled);
    defer allocator.free(channels_disabled);
    const channels_configured = try collectChannelNames(allocator, cfg_opt, .configured);
    defer allocator.free(channels_configured);

    const engines_enabled = try collectMemoryEngineNames(allocator, .build_enabled);
    defer allocator.free(engines_enabled);
    const engines_disabled = try collectMemoryEngineNames(allocator, .build_disabled);
    defer allocator.free(engines_disabled);

    const runtime_tool_names = try collectRuntimeToolNames(allocator, cfg_opt, runtime_tools);
    defer allocator.free(runtime_tool_names);
    const optional_disabled = try collectOptionalTools(allocator, cfg_opt, .disabled);
    defer allocator.free(optional_disabled);

    const channels_enabled_s = try joinNames(allocator, channels_enabled);
    defer allocator.free(channels_enabled_s);
    const channels_disabled_s = try joinNames(allocator, channels_disabled);
    defer allocator.free(channels_disabled_s);
    const channels_configured_s = try joinNames(allocator, channels_configured);
    defer allocator.free(channels_configured_s);
    const engines_enabled_s = try joinNames(allocator, engines_enabled);
    defer allocator.free(engines_enabled_s);
    const engines_disabled_s = try joinNames(allocator, engines_disabled);
    defer allocator.free(engines_disabled_s);
    const runtime_tools_s = try joinNames(allocator, runtime_tool_names);
    defer allocator.free(runtime_tools_s);
    const optional_disabled_s = try joinNames(allocator, optional_disabled);
    defer allocator.free(optional_disabled_s);

    const active_backend = if (cfg_opt) |cfg| cfg.memory.backend else "(unknown)";
    const tools_label = if (runtime_tools != null) "tools (loaded)" else "tools (estimated from config)";

    return try std.fmt.allocPrint(
        allocator,
        "Capabilities\n" ++
            "\nAvailable in this runtime:\n" ++
            "  channels (build): {s}\n" ++
            "  channels (configured): {s}\n" ++
            "  memory engines (build): {s}\n" ++
            "  active memory backend: {s}\n" ++
            "  {s}: {s}\n" ++
            "\nScheduling guidance:\n" ++
            "  use `schedule` for user-facing reminders, briefs, reports, and other proactive jobs\n" ++
            "  use `cron_*` only for raw scheduler inspection or operator maintenance\n" ++
            "  only wake turns may use `schedule ensure`, and only for jobs declared in `AUTOMATIONS.json`; `HEARTBEAT.md` is wake policy only\n" ++
            "  scheduler state is execution truth; scheduler-only jobs are valid and not drift\n" ++
            "\nNot available in this runtime:\n" ++
            "  channels (disabled in build): {s}\n" ++
            "  memory engines (disabled in build): {s}\n" ++
            "  optional tools (disabled by config): {s}\n",
        .{
            channels_enabled_s,
            channels_configured_s,
            engines_enabled_s,
            active_backend,
            tools_label,
            runtime_tools_s,
            channels_disabled_s,
            engines_disabled_s,
            optional_disabled_s,
        },
    );
}

pub fn buildPromptSection(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]u8 {
    const channels_enabled = try collectChannelNames(allocator, cfg_opt, .build_enabled);
    defer allocator.free(channels_enabled);
    const channels_disabled = try collectChannelNames(allocator, cfg_opt, .build_disabled);
    defer allocator.free(channels_disabled);
    const channels_configured = try collectChannelNames(allocator, cfg_opt, .configured);
    defer allocator.free(channels_configured);

    const engines_enabled = try collectMemoryEngineNames(allocator, .build_enabled);
    defer allocator.free(engines_enabled);
    const engines_disabled = try collectMemoryEngineNames(allocator, .build_disabled);
    defer allocator.free(engines_disabled);

    const runtime_tool_names = try collectRuntimeToolNames(allocator, cfg_opt, runtime_tools);
    defer allocator.free(runtime_tool_names);
    const optional_disabled = try collectOptionalTools(allocator, cfg_opt, .disabled);
    defer allocator.free(optional_disabled);

    const channels_enabled_s = try joinNames(allocator, channels_enabled);
    defer allocator.free(channels_enabled_s);
    const channels_disabled_s = try joinNames(allocator, channels_disabled);
    defer allocator.free(channels_disabled_s);
    const channels_configured_s = try joinNames(allocator, channels_configured);
    defer allocator.free(channels_configured_s);
    const engines_enabled_s = try joinNames(allocator, engines_enabled);
    defer allocator.free(engines_enabled_s);
    const engines_disabled_s = try joinNames(allocator, engines_disabled);
    defer allocator.free(engines_disabled_s);
    const runtime_tools_s = try joinNames(allocator, runtime_tool_names);
    defer allocator.free(runtime_tools_s);
    const optional_disabled_s = try joinNames(allocator, optional_disabled);
    defer allocator.free(optional_disabled_s);

    const active_backend = if (cfg_opt) |cfg| cfg.memory.backend else "(unknown)";
    const tools_line = if (runtime_tools != null)
        "Tools loaded in this runtime"
    else
        "Tools estimated from current config";

    return try std.fmt.allocPrint(
        allocator,
        "## Runtime Capabilities\n\n" ++
            "### Available in this runtime\n" ++
            "- Channels enabled in build: {s}\n" ++
            "- Configured channels: {s}\n" ++
            "- Memory backends enabled in build: {s}\n" ++
            "- Active memory backend: {s}\n" ++
            "- {s}: {s}\n\n" ++
            "### Scheduling Guidance\n" ++
            "- Use `schedule` for user-facing reminders, briefs, reports, and other proactive jobs.\n" ++
            "- Use `cron_*` only for raw scheduler inspection or operator maintenance.\n" ++
            "- Only wake turns may use `schedule ensure`, and only for jobs declared in `AUTOMATIONS.json`. `HEARTBEAT.md` is wake policy only.\n\n" ++
            "- Scheduler state is execution truth; scheduler-only jobs are valid and not drift.\n\n" ++
            "### Not available in this runtime\n" ++
            "- Channels disabled in build: {s}\n" ++
            "- Memory backends disabled in build: {s}\n" ++
            "- Optional tools disabled by current config: {s}\n\n",
        .{
            channels_enabled_s,
            channels_configured_s,
            engines_enabled_s,
            active_backend,
            tools_line,
            runtime_tools_s,
            channels_disabled_s,
            engines_disabled_s,
            optional_disabled_s,
        },
    );
}

test "buildManifestJson emits core sections" {
    const manifest = try buildManifestJson(std.testing.allocator, null, null);
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"channels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"memory_engines\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"tools\"") != null);
}

test "buildSummaryText includes availability sections" {
    const summary = try buildSummaryText(std.testing.allocator, null, null);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "Available in this runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Not available in this runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "use `schedule` for user-facing reminders") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "AUTOMATIONS.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "scheduler-only jobs are valid and not drift") != null);
}

test "buildManifestJson estimated tools align with runtime naming" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    const manifest = try buildManifestJson(std.testing.allocator, &cfg, null);
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"git_operations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"file_append\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"memory_edit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"memory_timeline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"cron_add\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"cron_update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"pushover\"") != null);
}

test "optional tools reflect http toggle for web tools" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.http_request.enabled = false;
    const optional_enabled_off = try collectOptionalTools(std.testing.allocator, &cfg, .enabled);
    defer std.testing.allocator.free(optional_enabled_off);
    try std.testing.expect(optional_enabled_off.len == 0);

    cfg.http_request.enabled = true;
    const optional_enabled_on = try collectOptionalTools(std.testing.allocator, &cfg, .enabled);
    defer std.testing.allocator.free(optional_enabled_on);

    var saw_http_request = false;
    var saw_web_fetch = false;
    var saw_web_search = false;
    for (optional_enabled_on) |name| {
        if (std.mem.eql(u8, name, "http_request")) saw_http_request = true;
        if (std.mem.eql(u8, name, "web_fetch")) saw_web_fetch = true;
        if (std.mem.eql(u8, name, "web_search")) saw_web_search = true;
    }

    try std.testing.expect(saw_http_request);
    try std.testing.expect(saw_web_fetch);
    try std.testing.expect(saw_web_search);
}
