const std = @import("std");
const Config = @import("config.zig").Config;
const version = @import("version.zig");
const channel_catalog = @import("channel_catalog.zig");
const runtime_truth = @import("diagnostics/runtime_truth.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    return runWithUser(allocator, null);
}

pub fn runWithUser(allocator: std.mem.Allocator, user_id: ?[]const u8) !void {
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const w = &bw.interface;

    var cfg = Config.load(allocator) catch {
        try w.print("nullALIS Status (no config found -- run `nullalis onboard` first)\n", .{});
        try w.print("\nVersion: {s}\n", .{version.string});
        try w.flush();
        return;
    };
    defer cfg.deinit();
    var snapshot = try runtime_truth.collectRuntimeSnapshot(allocator, &cfg, user_id);
    defer snapshot.deinit(allocator);

    try w.print("nullALIS Status\n\n", .{});
    try w.print("Version:     {s}\n", .{version.string});
    try w.print("Workspace:   {s}\n", .{cfg.workspace_dir});
    try w.print("Config:      {s}\n", .{cfg.config_path});
    try w.print("\n", .{});
    try w.print("Provider:    {s}\n", .{cfg.default_provider});
    try w.print("Model:       {s}\n", .{cfg.default_model orelse "(default)"});
    try w.print("Temperature: {d:.1}\n", .{cfg.temperature});
    try w.print("\n", .{});
    try w.print("Memory:      {s} (auto-save: {s})\n", .{
        cfg.memory_backend,
        if (cfg.memory_auto_save) "on" else "off",
    });
    try w.print("Heartbeat:   {s}\n", .{
        if (cfg.heartbeat_enabled) "enabled" else "disabled",
    });
    try w.print("Security:    workspace_only={s}, max_actions/hr={d}\n", .{
        if (cfg.workspace_only) "yes" else "no",
        cfg.max_actions_per_hour,
    });
    try w.print("\n", .{});

    // Diagnostics
    try w.print("Diagnostics:   {s}\n", .{cfg.diagnostics.backend});

    // Runtime
    try w.print("Runtime:     {s}\n", .{cfg.runtime.kind});

    // Gateway
    try w.print("Gateway:     {s}:{d}\n", .{ cfg.gateway_host, cfg.gateway_port });

    // Scheduler
    try w.print("Scheduler:   {s} (max_tasks={d}, max_concurrent={d})\n", .{
        if (cfg.scheduler.enabled) "enabled" else "disabled",
        cfg.scheduler.max_tasks,
        cfg.scheduler.max_concurrent,
    });
    try w.print("Runtime:     source={s}, state configured={s}, effective={s}, scheduler_backend={s}\n", .{
        snapshot.source.toSlice(),
        snapshot.state_backend_configured,
        snapshot.state_backend_effective,
        snapshot.scheduler_backend,
    });
    try w.print("Runtime LLM: chat_provider={s}, fallbacks={s}, embedding_provider={s}, source={s}\n", .{
        snapshot.chat_provider_effective,
        snapshot.chat_fallback_chain,
        snapshot.embedding_provider_effective,
        snapshot.provider_data_source,
    });
    if (user_id) |resolved_user_id| {
        try w.print("Runtime:     scoped_user_id={s}\n", .{resolved_user_id});
    } else if (cfg.tenant.enabled and std.mem.eql(u8, cfg.state.backend, "postgres")) {
        try w.print("Runtime:     tenant runtime detected; add --user-id <id> for user-scoped integration truth\n", .{});
    }
    try w.print("Runtime HB:  enabled={s}, interval={d}m, tenant={s}, degraded={s}\n", .{
        if (snapshot.heartbeat_enabled) "true" else "false",
        snapshot.heartbeat_interval_minutes,
        if (snapshot.tenant_enabled) "true" else "false",
        if (snapshot.degraded) "true" else "false",
    });
    if (snapshot.degraded and snapshot.degraded_reason.len > 0) {
        try w.print("Runtime Err: {s}\n", .{snapshot.degraded_reason});
    }
    if (snapshot.context_incomplete) {
        try w.print("Runtime:     context incomplete (fallback mode)\n", .{});
    }
    if (snapshot.telegram_configured != null or snapshot.telegram_connected != null) {
        try w.print("Runtime TG:  configured={s}, connected={s}", .{
            if (snapshot.telegram_configured != null and snapshot.telegram_configured.?) "true" else if (snapshot.telegram_configured == null) "unknown" else "false",
            if (snapshot.telegram_connected != null and snapshot.telegram_connected.?) "true" else if (snapshot.telegram_connected == null) "unknown" else "false",
        });
        if (snapshot.telegram_chat_id) |chat_id| {
            try w.print(", chat_id={d}", .{chat_id});
        }
        if (snapshot.telegram_data_source) |source| {
            try w.print(", source={s}", .{source});
        }
        try w.print("\n", .{});
    }

    // Cost tracking
    try w.print("Cost:        {s}\n", .{
        if (cfg.cost.enabled) "tracking enabled" else "disabled",
    });

    // Hardware
    try w.print("Hardware:    {s}\n", .{
        if (cfg.hardware.enabled) "enabled" else "disabled",
    });

    // Peripherals
    try w.print("Peripherals: {s} ({d} boards)\n", .{
        if (cfg.peripherals.enabled) "enabled" else "disabled",
        cfg.peripherals.boards.len,
    });

    // Sandbox
    try w.print("Sandbox:     {s}\n", .{
        if (cfg.security.sandbox.enabled orelse false) "enabled" else "disabled",
    });

    // Audit
    try w.print("Audit:       {s}\n", .{
        if (cfg.security.audit.enabled) "enabled" else "disabled",
    });

    try w.print("\n", .{});

    // Channels
    try w.print("Channels:\n", .{});
    for (channel_catalog.known_channels) |meta| {
        var status_buf: [64]u8 = undefined;
        const status_text = if (meta.id == .cli)
            "always"
        else if (meta.id == .telegram and snapshot.telegram_connected != null)
            if (snapshot.telegram_connected.?) "connected (runtime)" else "not connected (runtime)"
        else
            channel_catalog.statusText(&cfg, meta, &status_buf);
        try w.print("  {s}: {s}\n", .{ meta.label, status_text });
    }

    try w.flush();
}
