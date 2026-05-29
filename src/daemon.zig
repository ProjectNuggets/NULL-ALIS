//! Daemon — main event loop with component supervision.
//!
//! Mirrors ZeroClaw's daemon module:
//!   - Spawns gateway, channels, heartbeat, scheduler
//!   - Exponential backoff on component failure
//!   - Periodic state file writing (daemon_state.json)
//!   - Ctrl+C graceful shutdown
//!
//! `daemon_state.json` is an operational diagnostics artifact. It is intended
//! for health/debug visibility and should not be treated as canonical user or
//! product state.

const builtin = @import("builtin");
const std = @import("std");
const health = @import("health.zig");
const Config = @import("config.zig").Config;
const CronScheduler = @import("cron.zig").CronScheduler;
const cron = @import("cron.zig");
const bus_mod = @import("bus.zig");
const zaki_session = @import("session/root.zig");
const dispatch = @import("channels/dispatch.zig");
const channel_loop = @import("channel_loop.zig");
const channel_manager = @import("channel_manager.zig");
const agent_routing = @import("agent_routing.zig");
const channel_catalog = @import("channel_catalog.zig");
const channel_adapters = @import("channel_adapters.zig");
const onboard = @import("onboard.zig");
const tenant_lock = @import("tenant_lock.zig");
const zaki_state = @import("zaki_state.zig");
const ops_guard = @import("ops_guard.zig");
const heartbeat_wake = @import("heartbeat_wake.zig");
const json_util = @import("json_util.zig");
const providers = @import("providers/root.zig");
const embeddings = @import("memory/vector/embeddings.zig");
const entity_pipeline = @import("agent/entity_pipeline.zig");
const tools_mod = @import("tools/root.zig");
const tool_sandbox_v1 = @import("tools/tool_sandbox_v1.zig");
const entitlement_mod = @import("entitlement.zig");
const runtime_resolver = @import("delivery/runtime_resolver.zig");
const inbound_canonicalizer = @import("inbound_canonicalizer.zig");
const channel_identity_key = @import("channel_identity_key.zig");
const lane_metrics = @import("lane_metrics.zig");
const ConversationContext = @import("agent/prompt.zig").ConversationContext;

const log = std.log.scoped(.daemon);

/// How often the daemon state file is flushed (seconds).
const STATUS_FLUSH_SECONDS: u64 = 5;

/// Maximum number of supervised components.
const MAX_COMPONENTS: usize = 8;
const MAX_DISPATCHER_WORKERS: u32 = 64;
const HEARTBEAT_WAKE_COMMAND = "__wake_heartbeat";

/// Component status for state file serialization.
pub const ComponentStatus = struct {
    name: []const u8,
    running: bool = false,
    restart_count: u64 = 0,
    last_error: ?[]const u8 = null,
};

/// Daemon state written to daemon_state.json periodically.
pub const DaemonState = struct {
    started: bool = false,
    gateway_host: []const u8 = "127.0.0.1",
    gateway_port: u16 = 3000,
    components: [MAX_COMPONENTS]?ComponentStatus = .{null} ** MAX_COMPONENTS,
    component_count: usize = 0,
    /// **S14.5 MED-1 fix (2026-04-26)** — `components` and
    /// `component_count` are read by `writeStateFile` (heartbeat
    /// thread) while gateway/delivery/heartbeat/scheduler threads call
    /// `markError` / `markRunning` concurrently. Pre-fix: data race on
    /// the array + count. Today's symptoms minimal because each thread
    /// usually owns one component (gateway → "gateway",
    /// scheduler → "scheduler", etc.) so writes don't collide on the
    /// same slot — but the read side could see torn writes if a marker
    /// fires mid-flush. This mutex closes the race; cost is one
    /// uncontended lock acquire per read/write since contention is
    /// near-zero in practice.
    mutex: std.Thread.Mutex = .{},

    pub fn addComponent(self: *DaemonState, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.component_count < MAX_COMPONENTS) {
            self.components[self.component_count] = .{ .name = name, .running = true };
            self.component_count += 1;
        }
    }

    pub fn markError(self: *DaemonState, name: []const u8, err_msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.components[0..self.component_count]) |*comp_opt| {
            if (comp_opt.*) |*comp| {
                if (std.mem.eql(u8, comp.name, name)) {
                    comp.running = false;
                    comp.last_error = err_msg;
                    comp.restart_count += 1;
                    return;
                }
            }
        }
    }

    pub fn markRunning(self: *DaemonState, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.components[0..self.component_count]) |*comp_opt| {
            if (comp_opt.*) |*comp| {
                if (std.mem.eql(u8, comp.name, name)) {
                    comp.running = true;
                    comp.last_error = null;
                    return;
                }
            }
        }
    }
};

/// Compute the path to daemon_state.json from config.
pub fn stateFilePath(allocator: std.mem.Allocator, config: *const Config) ![]u8 {
    // Use config directory (parent of config_path)
    if (std.fs.path.dirname(config.config_path)) |dir| {
        return std.fs.path.join(allocator, &.{ dir, "daemon_state.json" });
    }
    return allocator.dupe(u8, "daemon_state.json");
}

/// Write daemon state to disk as JSON.
///
/// **S14.5 MED-1 fix (2026-04-26)** — receiver is now `*DaemonState`
/// (not `*const`) so we can acquire the state's mutex while reading
/// `components` + `component_count`. Without the lock, this read could
/// see torn writes from concurrent `markError` / `markRunning` calls
/// on other threads. The serialization happens under-lock to a local
/// buffer; the file write happens after lock release to keep the
/// critical section minimal.
pub fn writeStateFile(allocator: std.mem.Allocator, path: []const u8, state: *DaemonState) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try buf.appendSlice(allocator, "  \"status\": \"running\",\n");
    try std.fmt.format(buf.writer(allocator), "  \"gateway\": \"{s}:{d}\",\n", .{ state.gateway_host, state.gateway_port });

    // Components array — acquire mutex for the duration of the read
    // so concurrent markers don't tear the array under us.
    state.mutex.lock();
    defer state.mutex.unlock();

    try buf.appendSlice(allocator, "  \"components\": [\n");
    var first = true;
    for (state.components[0..state.component_count]) |comp_opt| {
        if (comp_opt) |comp| {
            if (!first) try buf.appendSlice(allocator, ",\n");
            first = false;
            try std.fmt.format(buf.writer(allocator),
                \\    {{"name": "{s}", "running": {}, "restart_count": {d}}}
            , .{ comp.name, comp.running, comp.restart_count });
        }
    }
    try buf.appendSlice(allocator, "\n  ]\n}\n");

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Compute exponential backoff duration.
pub fn computeBackoff(current_backoff: u64, max_backoff: u64) u64 {
    const doubled = current_backoff *| 2;
    return @min(doubled, max_backoff);
}

/// Check if any real-time channels are configured.
pub fn hasSupervisedChannels(config: *const Config) bool {
    return channel_catalog.hasSupervisedChannels(config);
}

/// Shutdown signal — set to true to stop the daemon.
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Request a graceful shutdown of the daemon.
pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

/// Check if shutdown has been requested.
pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

/// Gateway thread entry point.
///
/// S5 (2026-05-29) — Production fail-loud. The gateway thread cannot
/// propagate an error back to main (Zig threads return void), so we exit the
/// process directly on fatal-class startup errors. The gateway already emitted
/// `log.err` with the named reason before returning the error; we emit a
/// daemon-level breadcrumb so operators see both perspectives in the log.
///
/// To verify manually: set `state.backend=postgres` with an unreachable host
/// + `gateway.allow_public_bind=true`; start the gateway; expect non-zero
/// exit within a few seconds with a `daemon.gateway_thread: production
/// fail-loud` log line on stderr.
fn gatewayThread(allocator: std.mem.Allocator, config: *const Config, host: []const u8, port: u16, state: *DaemonState, event_bus: *bus_mod.Bus) void {
    const gateway = @import("gateway.zig");
    const sentry_runtime = @import("sentry_runtime.zig");
    gateway.run(allocator, host, port, config, event_bus) catch |err| {
        // Fail-loud on the production readiness gate: thread `return` cannot
        // surface this to main, and other supervisor threads would happily
        // keep running with file-backed state — exactly the silent-degraded
        // behavior S5 was meant to eliminate.
        //
        // F15 (S5 code-review pass): membership is tested via
        // `gateway.isFatalStartupError`, which iterates the StartupSelfCheckError
        // set at comptime. Any variant added to that set is covered
        // automatically — no `@errorName` string literal to drift out of sync.
        if (gateway.isFatalStartupError(err)) {
            // F7 (S5 code-review pass): std.process.exit() runs NO deferred
            // cleanup on any thread, so the Sentry breadcrumb that main would
            // emit on an error return (main.zig captureError+flush) is lost on
            // this path. Capture + flush HERE so the crash-class signal still
            // reaches the alerting pipeline before we exit. `globalOrFallback`
            // is a no-op runtime when Sentry is unconfigured, so this is safe
            // unconditionally. (gateway.run's own `defer state.deinit()` has
            // already run during unwind — observers detached, registry freed;
            // a postgres lease, if any, cannot be released because PG is
            // unreachable by definition on this path and expires on its TTL.)
            const rt = sentry_runtime.globalOrFallback();
            rt.captureError("daemon.gateway_thread", @errorName(err));
            rt.flush(2000);
            log.err("daemon.gateway_thread: production fail-loud — exiting non-zero (reason: {s})", .{@errorName(err)});
            std.process.exit(1);
        }
        state.markError("gateway", @errorName(err));
        health.markComponentError("gateway", @errorName(err));
        return;
    };
}

fn normalizeGatewayControlHost(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "0.0.0.0")) return "127.0.0.1";
    if (std.mem.eql(u8, host, "::")) return "::1";
    return host;
}

fn sendGatewayControlCommand(host: []const u8, port: u16, path: []const u8, internal_token: ?[]const u8) void {
    const dial_host = normalizeGatewayControlHost(host);
    const addr = std.net.Address.resolveIp(dial_host, port) catch return;
    var stream = std.net.tcpConnectToAddress(addr) catch return;
    defer stream.close();

    var req_buf: [1024]u8 = undefined;
    const request = if (internal_token) |token|
        std.fmt.bufPrint(
            &req_buf,
            "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nX-Internal-Token: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ path, dial_host, port, token },
        ) catch return
    else
        std.fmt.bufPrint(
            &req_buf,
            "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ path, dial_host, port },
        ) catch return;

    stream.writeAll(request) catch return;
    var read_buf: [256]u8 = undefined;
    _ = stream.read(&read_buf) catch {};
}

const HEARTBEAT_PROMPT_DEFAULT =
    "Read HEARTBEAT.md if it exists (workspace context) and treat it as wake policy only, not as proof that jobs already exist. " ++
    "If AUTOMATIONS.json exists, treat it as desired durable automation state for canonical scheduled jobs, not as the execution truth for all jobs. " ++
    "Heartbeat is a wake trigger, not the exact-time scheduler. Scheduler state is execution truth: if a job exists in schedule, it is valid and should run even if not declared in AUTOMATIONS.json. Use runtime_info first, then inspect durable jobs with schedule. " ++
    "Wake turns may reconcile only canonical jobs declared in AUTOMATIONS.json by using schedule ensure. " ++
    "Do not report scheduler-only jobs as drift. Drift means a job declared in AUTOMATIONS.json is missing, broken, unexpectedly paused, or in error. " ++
    "Do not create durable scheduled jobs from free-form prose. Resume is not a repair action for jobs in error state. " ++
    "Do not use heartbeat polling itself as exact-time scheduling. " ++
    "Do not use cron_* for user-facing automation. Do not use shell or message. Do not use composio in heartbeat or wake turns. Use web_search or web_fetch only when directly needed to verify a claim, not for exploratory discovery. " ++
    "Reply in exactly one of these forms only: HEARTBEAT_OK or HEARTBEAT_SEND: <single concise user-facing sentence>. Do not output lists, markdown, diagnostics, or explanatory narration.";
const HEARTBEAT_RUNTIME_FILENAME = "heartbeat_runtime.json";
const CRON_WAKE_REASON_NEXT_HEARTBEAT_PREFIX = "cron.next_heartbeat:";
const HEARTBEAT_SWEEP_INTERVAL_SECS: i64 = 30;
const HEARTBEAT_WAKE_MAX_DRAIN_PER_TICK: usize = 4;

fn ignoreSigpipe() void {
    switch (builtin.os.tag) {
        .windows, .wasi => return,
        else => {},
    }

    const sigact = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &sigact, null);
}

const UserHeartbeatConfig = struct {
    enabled: bool,
    interval_minutes: u32,
    prompt: []const u8,
    prompt_owned: bool = false,

    fn deinit(self: *UserHeartbeatConfig, allocator: std.mem.Allocator) void {
        if (self.prompt_owned) allocator.free(self.prompt);
    }
};

fn parseHeartbeatEveryToMinutes(raw: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const secs = cron.parseDuration(trimmed) catch return null;
    if (secs <= 0) return null;
    const mins_i64 = @max(@as(i64, 1), @divFloor(secs + 59, 60));
    const clamped = @min(mins_i64, @as(i64, std.math.maxInt(u32)));
    return @intCast(clamped);
}

fn parseHeartbeatSecondsToMinutes(value: i64) ?u32 {
    if (value <= 0) return null;
    const mins_i64 = @max(@as(i64, 1), @divFloor(value + 59, 60));
    const clamped = @min(mins_i64, @as(i64, std.math.maxInt(u32)));
    return @intCast(clamped);
}

fn applyHeartbeatConfigObject(cfg: *UserHeartbeatConfig, allocator: std.mem.Allocator, object: std.json.ObjectMap) void {
    if (object.get("enabled")) |v| {
        if (v == .bool) cfg.enabled = v.bool;
    }
    if (object.get("interval_minutes")) |v| {
        if (v == .integer and v.integer > 0) {
            const clamped = @min(v.integer, @as(i64, std.math.maxInt(u32)));
            cfg.interval_minutes = @intCast(clamped);
        }
    }
    // v1.14.23 WARN 3.C: canonical key is `interval_secs`;
    // `intervalSec`, `interval_sec`, and `interval_seconds` are kept as
    // legacy aliases for back-compat with existing schedule fixtures.
    if (object.get("interval_secs")) |v| {
        if (v == .integer) {
            if (parseHeartbeatSecondsToMinutes(v.integer)) |mins| cfg.interval_minutes = mins;
        }
    }
    if (object.get("intervalSec")) |v| {
        if (v == .integer) {
            if (parseHeartbeatSecondsToMinutes(v.integer)) |mins| cfg.interval_minutes = mins;
        }
    }
    if (object.get("interval_seconds")) |v| {
        if (v == .integer) {
            if (parseHeartbeatSecondsToMinutes(v.integer)) |mins| cfg.interval_minutes = mins;
        }
    }
    if (object.get("interval_sec")) |v| {
        if (v == .integer) {
            if (parseHeartbeatSecondsToMinutes(v.integer)) |mins| cfg.interval_minutes = mins;
        }
    }
    if (object.get("every")) |v| {
        if (v == .string) {
            if (parseHeartbeatEveryToMinutes(v.string)) |mins| cfg.interval_minutes = mins;
        }
    }
    if (object.get("prompt")) |v| {
        if (v == .string) {
            const trimmed = std.mem.trim(u8, v.string, " \t\r\n");
            if (trimmed.len > 0) {
                const owned = allocator.dupe(u8, trimmed) catch return;
                if (cfg.prompt_owned) allocator.free(cfg.prompt);
                cfg.prompt = owned;
                cfg.prompt_owned = true;
            }
        }
    }
}

fn applyHeartbeatConfigJson(cfg: *UserHeartbeatConfig, allocator: std.mem.Allocator, raw: []const u8) !bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}")) return false;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidConfigJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfigJson;

    applyHeartbeatConfigObject(cfg, allocator, parsed.value.object);
    if (parsed.value.object.get("heartbeat")) |nested| {
        if (nested == .object) {
            applyHeartbeatConfigObject(cfg, allocator, nested.object);
        }
    }
    return true;
}

fn loadUserHeartbeatConfig(
    allocator: std.mem.Allocator,
    user_root: []const u8,
    default_enabled: bool,
    default_interval_minutes: u32,
    state_json: ?[]const u8,
) UserHeartbeatConfig {
    var cfg = UserHeartbeatConfig{
        .enabled = default_enabled,
        .interval_minutes = @max(@as(u32, 1), default_interval_minutes),
        .prompt = HEARTBEAT_PROMPT_DEFAULT,
    };

    if (state_json) |raw| {
        const applied = applyHeartbeatConfigJson(&cfg, allocator, raw) catch |err| blk: {
            log.warn("heartbeat state config parse failed: {}", .{err});
            break :blk false;
        };
        if (applied) {
            cfg.interval_minutes = @max(@as(u32, 1), cfg.interval_minutes);
            return cfg;
        }
    }

    const path = std.fmt.allocPrint(allocator, "{s}/heartbeat.json", .{user_root}) catch return cfg;
    defer allocator.free(path);
    const file = std.fs.openFileAbsolute(path, .{}) catch return cfg;
    defer file.close();
    const raw = file.readToEndAlloc(allocator, 128 * 1024) catch return cfg;
    defer allocator.free(raw);

    _ = applyHeartbeatConfigJson(&cfg, allocator, raw) catch |err| {
        log.warn("heartbeat file config parse failed: {}", .{err});
    };
    cfg.interval_minutes = @max(@as(u32, 1), cfg.interval_minutes);
    return cfg;
}

fn loadHeartbeatStateJson(
    allocator: std.mem.Allocator,
    user_id_opt: ?i64,
    state_mgr_opt: ?*zaki_state.Manager,
) ?[]u8 {
    const state_mgr = state_mgr_opt orelse return null;
    const user_id = user_id_opt orelse return null;
    return state_mgr.getHeartbeatJson(allocator, user_id) catch |err| {
        log.warn("heartbeat state read failed for user={d}: {}", .{ user_id, err });
        return null;
    };
}

fn parseNumericUserIdFromDirName(name: []const u8) ?i64 {
    return std.fmt.parseInt(i64, name, 10) catch null;
}

fn countEnabledUserHeartbeatConfigsByFile(
    allocator: std.mem.Allocator,
    tenant_data_root: []const u8,
) usize {
    var users_dir = std.fs.openDirAbsolute(tenant_data_root, .{ .iterate = true }) catch return 0;
    defer users_dir.close();

    var enabled_count: usize = 0;
    var iter = users_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0) continue;
        const user_root = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tenant_data_root, entry.name }) catch continue;
        defer allocator.free(user_root);

        var hb_cfg = loadUserHeartbeatConfig(allocator, user_root, false, 30, null);
        defer hb_cfg.deinit(allocator);
        if (hb_cfg.enabled) enabled_count += 1;
    }
    return enabled_count;
}

fn heartbeatRuntimePath(allocator: std.mem.Allocator, user_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ user_root, HEARTBEAT_RUNTIME_FILENAME });
}

fn loadHeartbeatLastRunS(allocator: std.mem.Allocator, user_root: []const u8) i64 {
    const path = heartbeatRuntimePath(allocator, user_root) catch return 0;
    defer allocator.free(path);
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();
    const raw = file.readToEndAlloc(allocator, 64 * 1024) catch return 0;
    defer allocator.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const last = parsed.value.object.get("last_run_s") orelse return 0;
    if (last != .integer) return 0;
    return last.integer;
}

fn saveHeartbeatRuntimeState(
    allocator: std.mem.Allocator,
    user_root: []const u8,
    last_run_s: i64,
    status: []const u8,
    reason: []const u8,
) void {
    const path = heartbeatRuntimePath(allocator, user_root) catch return;
    defer allocator.free(path);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    body.append(allocator, '{') catch return;
    json_util.appendJsonInt(&body, allocator, "last_run_s", last_run_s) catch return;
    body.append(allocator, ',') catch return;
    json_util.appendJsonKeyValue(&body, allocator, "last_status", status) catch return;
    body.append(allocator, ',') catch return;
    json_util.appendJsonKeyValue(&body, allocator, "last_reason", reason) catch return;
    body.append(allocator, '}') catch return;
    body.append(allocator, '\n') catch return;

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(body.items) catch {};
}

const HeartbeatOutcomeState = struct {
    status: []const u8,
    reason: []const u8,
};

fn mapHeartbeatOutcomeState(action: []const u8, reason: []const u8) HeartbeatOutcomeState {
    if (std.mem.eql(u8, action, "sent")) {
        return .{ .status = "sent", .reason = if (reason.len > 0) reason else "sent" };
    }
    if (std.mem.eql(u8, action, "blocked_rate")) {
        return .{ .status = "blocked_rate", .reason = if (reason.len > 0) reason else "rate_limit" };
    }
    if (std.mem.eql(u8, action, "blocked_dedupe")) {
        return .{ .status = "blocked_dedupe", .reason = if (reason.len > 0) reason else "dedupe_window" };
    }
    return .{ .status = "send_failed", .reason = if (reason.len > 0) reason else "delivery_error" };
}

fn completionEventIdFromSource(source: []const u8) ?[]const u8 {
    const prefix = "subagent_completion:";
    if (!std.mem.startsWith(u8, source, prefix)) return null;
    const event_id = source[prefix.len..];
    if (event_id.len == 0) return null;
    return event_id;
}

fn deliveryOutcomeThread(allocator: std.mem.Allocator, config: *const Config, state: *DaemonState, event_bus: *bus_mod.Bus, state_mgr_opt: ?*zaki_state.Manager) void {
    _ = state;
    while (event_bus.consumeDeliveryOutcome()) |outcome| {
        defer outcome.deinit(allocator);
        const source = outcome.source orelse continue;

        if (std.mem.eql(u8, outcome.action, "sent")) {
            if (completionEventIdFromSource(source)) |event_id| {
                const user_id = outcome.user_id orelse continue;
                const numeric_user_id = std.fmt.parseInt(i64, user_id, 10) catch continue;
                if (state_mgr_opt) |mgr| {
                    // S4.6 — durable-write silent catch closed. Missing to delete
                    // a delivered completion_event row causes duplicate delivery
                    // on reconnect AND unbounded growth of the completion_events
                    // table. Log + counter so operators see the pattern without
                    // relying on error-level log filters.
                    mgr.deleteCompletionEvent(numeric_user_id, event_id) catch |err| {
                        lane_metrics.recordCompletionEventDeleteFailure();
                        log.warn("completion_event.delete_failed user_id={d} event_id={s} err={s}", .{ numeric_user_id, event_id, @errorName(err) });
                    };
                }
                continue;
            }
        }

        if (!config.tenant.enabled) continue;
        if (!std.mem.eql(u8, source, "heartbeat")) continue;
        const user_id = outcome.user_id orelse continue;
        const user_root = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tenant.data_root, user_id }) catch continue;
        defer allocator.free(user_root);
        const mapped = mapHeartbeatOutcomeState(outcome.action, outcome.reason);
        saveHeartbeatRuntimeState(allocator, user_root, outcome.ts_s, mapped.status, mapped.reason);
    }
}

fn readTrimmedFileOwned(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 256 * 1024);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

fn isHeartbeatContentEffectivelyEmpty(content: []const u8) bool {
    if (isDefaultHeartbeatTemplate(content)) return true;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (std.mem.startsWith(u8, trimmed, "<!--")) continue;
        if (std.mem.eql(u8, trimmed, "- [ ]") or
            std.mem.eql(u8, trimmed, "* [ ]") or
            std.mem.eql(u8, trimmed, "- [x]") or
            std.mem.eql(u8, trimmed, "* [x]"))
        {
            continue;
        }
        return false;
    }
    return true;
}

fn isDefaultHeartbeatTemplate(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return true;

    if (std.mem.indexOf(u8, trimmed, "# Keep this file empty (or with only comments) to skip heartbeat API calls.") != null) {
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "# HEARTBEAT.md - ") and
        std.mem.indexOf(u8, trimmed, "Use this file to define recurring, proactive work.") != null and
        std.mem.indexOf(u8, trimmed, "Suggested categories:") != null and
        std.mem.indexOf(u8, trimmed, "Keep only tasks the user actually wants automated.") != null)
    {
        return true;
    }

    return false;
}

fn asciiStartsWithIgnoreCaseAt(haystack: []const u8, start: usize, needle: []const u8) bool {
    if (start + needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (std.ascii.toUpper(haystack[start + i]) != std.ascii.toUpper(needle[i])) return false;
    }
    return true;
}

fn isHeartbeatAck(reply: []const u8) bool {
    const trimmed = std.mem.trim(u8, reply, " \t\r\n");
    if (trimmed.len == 0) return false;

    var found_token = false;
    var inside_tag = false;
    var i: usize = 0;
    while (i < trimmed.len) {
        if (!inside_tag) {
            if (asciiStartsWithIgnoreCaseAt(trimmed, i, "HEARTBEAT_OK")) {
                found_token = true;
                i += "HEARTBEAT_OK".len;
                continue;
            }
            if (asciiStartsWithIgnoreCaseAt(trimmed, i, "HEARTBEATOK")) {
                found_token = true;
                i += "HEARTBEATOK".len;
                continue;
            }
        }

        const c = trimmed[i];
        if (inside_tag) {
            if (c == '>') inside_tag = false;
            i += 1;
            continue;
        }
        if (c == '<') {
            inside_tag = true;
            i += 1;
            continue;
        }

        if (c < 128 and std.ascii.isAlphanumeric(c)) {
            return false;
        }
        i += 1;
    }
    return found_token;
}

const HeartbeatReplyDirective = union(enum) {
    ok,
    send: []const u8,
    invalid: []const u8,
};

fn parseHeartbeatReplyDirective(reply: []const u8) HeartbeatReplyDirective {
    const trimmed = std.mem.trim(u8, reply, " \t\r\n");
    if (trimmed.len == 0) return .{ .invalid = "invalid_heartbeat_reply_format" };
    if (isHeartbeatAck(trimmed)) return .ok;

    const send_prefix = "HEARTBEAT_SEND:";
    if (!asciiStartsWithIgnoreCaseAt(trimmed, 0, send_prefix)) {
        return .{ .invalid = "invalid_heartbeat_reply_format" };
    }

    const payload = std.mem.trim(u8, trimmed[send_prefix.len..], " \t\r\n");
    if (payload.len == 0) return .{ .invalid = "invalid_heartbeat_reply_format" };
    if (std.mem.indexOfScalar(u8, payload, '\n') != null or std.mem.indexOfScalar(u8, payload, '\r') != null) {
        return .{ .invalid = "invalid_heartbeat_reply_format" };
    }
    if (payload.len > 280) return .{ .invalid = "invalid_heartbeat_reply_format" };
    return .{ .send = payload };
}

fn heartbeatDedupeBucket(content: []const u8) ?[]const u8 {
    var lowered: [512]u8 = undefined;
    const clipped_len = @min(content.len, lowered.len);
    _ = std.ascii.lowerString(lowered[0..clipped_len], content[0..clipped_len]);
    const norm = lowered[0..clipped_len];

    const has_morning_brief = std.mem.indexOf(u8, norm, "morning-brief") != null or std.mem.indexOf(u8, norm, "morning brief") != null;
    if (has_morning_brief) {
        if (std.mem.indexOf(u8, norm, "created") != null or std.mem.indexOf(u8, norm, "scheduled") != null) {
            return "morning_brief_configured";
        }
        if (std.mem.indexOf(u8, norm, "delivered") != null or std.mem.indexOf(u8, norm, "sent") != null) {
            return "morning_brief_delivered";
        }
    }
    if (std.mem.indexOf(u8, norm, "max tasks reached") != null or std.mem.indexOf(u8, norm, "max capacity") != null) {
        return "scheduler_capacity";
    }
    if (std.mem.indexOf(u8, norm, "external tools disabled") != null or
        std.mem.indexOf(u8, norm, "tools disabled during heartbeat") != null)
    {
        return "background_tools_disabled";
    }
    return null;
}

fn makeHeartbeatDedupeKey(
    allocator: std.mem.Allocator,
    user_id: []const u8,
    chat_id: []const u8,
    content: []const u8,
) ![]u8 {
    if (heartbeatDedupeBucket(content)) |bucket| {
        return std.fmt.allocPrint(allocator, "heartbeat:{s}:{s}:{s}", .{ user_id, chat_id, bucket });
    }
    const hash = std.hash.Wyhash.hash(0, content);
    return std.fmt.allocPrint(allocator, "heartbeat:{s}:{s}:{x}", .{ user_id, chat_id, hash });
}

fn enqueueHeartbeatOutboundMessage(
    allocator: std.mem.Allocator,
    event_bus: *bus_mod.Bus,
    user_id: []const u8,
    account_id_opt: ?[]const u8,
    chat_id: []const u8,
    content: []const u8,
    dedupe_key: ?[]const u8,
) !void {
    const msg = if (account_id_opt) |account_id|
        try bus_mod.makeOutboundWithAccountAnnotated(
            allocator,
            "telegram",
            account_id,
            chat_id,
            content,
            "heartbeat",
            user_id,
            dedupe_key,
        )
    else
        try bus_mod.makeOutboundAnnotated(
            allocator,
            "telegram",
            chat_id,
            content,
            "heartbeat",
            user_id,
            dedupe_key,
        );

    event_bus.publishOutbound(msg) catch |err| {
        msg.deinit(allocator);
        return err;
    };
}

fn runHeartbeatAgentTurn(
    allocator: std.mem.Allocator,
    config: *const Config,
    user_id: []const u8,
    user_root: []const u8,
    workspace_path: []const u8,
    event_bus: *bus_mod.Bus,
    prompt: []const u8,
    turn_origin: tools_mod.TurnOrigin,
) ![]const u8 {
    var scheduler = CronScheduler.init(allocator, 1, true);
    defer scheduler.deinit();
    try scheduler.setExecutionContext(user_id, user_root, workspace_path);

    var heartbeat_job = cron.CronJob{
        .id = "heartbeat",
        .expression = "* * * * *",
        .command = if (turn_origin == .wake) HEARTBEAT_WAKE_COMMAND else "heartbeat",
        .session_target = .isolated,
    };
    return runCronAgentTurnWithBus(
        @ptrCast(@constCast(config)),
        allocator,
        &scheduler,
        &heartbeat_job,
        prompt,
        event_bus,
    );
}

fn runTenantHeartbeatForUser(
    allocator: std.mem.Allocator,
    config: *const Config,
    event_bus: *bus_mod.Bus,
    user_id: []const u8,
    user_id_numeric: ?i64,
    user_root: []const u8,
    workspace_path: []const u8,
    forced: bool,
    reason: []const u8,
    state_mgr: ?*zaki_state.Manager,
) void {
    const now_s = std.time.timestamp();
    const state_json = loadHeartbeatStateJson(allocator, user_id_numeric, state_mgr);
    defer if (state_json) |raw| allocator.free(raw);
    var hb_cfg = loadUserHeartbeatConfig(
        allocator,
        user_root,
        false,
        config.heartbeat.interval_minutes,
        state_json,
    );
    defer hb_cfg.deinit(allocator);

    if (!forced and !hb_cfg.enabled) return;

    const last_run_s = loadHeartbeatLastRunS(allocator, user_root);
    const interval_s = @as(i64, hb_cfg.interval_minutes) * 60;
    if (!forced and last_run_s > 0 and now_s - last_run_s < interval_s and now_s >= last_run_s) {
        return;
    }

    const heartbeat_md_path = std.fmt.allocPrint(allocator, "{s}/HEARTBEAT.md", .{workspace_path}) catch return;
    defer allocator.free(heartbeat_md_path);
    const heartbeat_content = readTrimmedFileOwned(allocator, heartbeat_md_path) catch null;
    defer if (heartbeat_content) |content| allocator.free(content);
    if (heartbeat_content) |content| {
        if (isHeartbeatContentEffectivelyEmpty(content)) {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "idle", "heartbeat_template_empty");
            return;
        }
    }

    // Interval lane only triggers wake work; the wake lane performs the model turn.
    if (!forced) {
        heartbeat_wake.enqueue(user_id, "heartbeat.interval_due") catch |err| {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", @errorName(err));
            return;
        };
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "triggered", reason);
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "enqueued", "wake_enqueued");
        return;
    }

    const turn_origin: tools_mod.TurnOrigin = .wake;

    const reply = runHeartbeatAgentTurn(allocator, config, user_id, user_root, workspace_path, event_bus, hb_cfg.prompt, turn_origin) catch |err| {
        log.warn("heartbeat agent turn failed for user={s}: {}", .{ user_id, err });
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "turn_error");
        return;
    };
    defer allocator.free(reply);

    const actionable_reply = switch (parseHeartbeatReplyDirective(reply)) {
        .ok => {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "idle", "no_actionable_output");
            return;
        },
        .invalid => |invalid_reason| {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", invalid_reason);
            return;
        },
        .send => |payload| payload,
    };
    saveHeartbeatRuntimeState(allocator, user_root, now_s, "triggered", reason);

    var delivery_ctx = runtime_resolver.resolveRuntimeDeliveryContext(allocator, .{
        .channel = "telegram",
        .tenant_ctx = .{
            .state_mgr = state_mgr,
            .numeric_user_id = user_id_numeric,
            .expect_postgres_state = config.tenant.enabled and std.mem.eql(u8, config.state.backend, "postgres"),
        },
        .user_root = user_root,
    }) catch |err| switch (err) {
        error.MissingTenantContext => {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "context_incomplete");
            return;
        },
        error.NotConnected, error.InvalidTarget => {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "no_target");
            return;
        },
        error.MissingCredential => {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "no_token");
            return;
        },
        error.UnsupportedChannel => {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", @errorName(err));
            return;
        },
        else => {
            saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", @errorName(err));
            return;
        },
    };
    defer delivery_ctx.deinit(allocator);

    if (delivery_ctx.context_incomplete) {
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "context_incomplete");
        return;
    }

    runtime_resolver.requireConnectedTarget(&delivery_ctx) catch {
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "no_target");
        return;
    };

    _ = runtime_resolver.requireCredential(&delivery_ctx) catch {
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "no_token");
        return;
    };

    const chat_id_text = delivery_ctx.target_id orelse {
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", "no_target");
        return;
    };

    const dedupe_key = makeHeartbeatDedupeKey(allocator, user_id, chat_id_text, actionable_reply) catch null;
    defer if (dedupe_key) |key| allocator.free(key);
    enqueueHeartbeatOutboundMessage(
        allocator,
        event_bus,
        user_id,
        delivery_ctx.account_id,
        chat_id_text,
        actionable_reply,
        dedupe_key,
    ) catch |err| {
        saveHeartbeatRuntimeState(allocator, user_root, now_s, "send_failed", @errorName(err));
        return;
    };
    saveHeartbeatRuntimeState(allocator, user_root, now_s, "enqueued", "delivery_enqueued");
}

fn runTenantHeartbeatSweep(
    allocator: std.mem.Allocator,
    config: *const Config,
    event_bus: *bus_mod.Bus,
    owner_instance_id: []const u8,
    forced_user_id: ?[]const u8,
    reason: []const u8,
    forced: bool,
    state_mgr: ?*zaki_state.Manager,
) void {
    var users_dir = std.fs.openDirAbsolute(config.tenant.data_root, .{ .iterate = true }) catch return;
    defer users_dir.close();

    var iter = users_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0) continue;
        if (forced_user_id) |wanted| {
            if (!std.mem.eql(u8, wanted, entry.name)) continue;
        }

        const user_root = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tenant.data_root, entry.name }) catch continue;
        defer allocator.free(user_root);
        const workspace_path = std.fmt.allocPrint(allocator, "{s}/workspace", .{user_root}) catch continue;
        defer allocator.free(workspace_path);
        const numeric_user_id = parseNumericUserIdFromDirName(entry.name);

        var ownership_lock = tenant_lock.acquireUserOwnershipLock(
            allocator,
            user_root,
            owner_instance_id,
            TENANT_OWNERSHIP_LOCK_LEASE_SECS,
        ) catch |err| switch (err) {
            error.LockHeld => continue,
            else => {
                log.warn("heartbeat ownership lock failed for user={s}: {}", .{ entry.name, err });
                continue;
            },
        };
        defer ownership_lock.deinit();

        runTenantHeartbeatForUser(
            allocator,
            config,
            event_bus,
            entry.name,
            numeric_user_id,
            user_root,
            workspace_path,
            forced,
            reason,
            state_mgr,
        );
    }
}

/// Heartbeat thread — writes state file, runs periodic heartbeat checks, and handles wake-now requests.
fn heartbeatThread(allocator: std.mem.Allocator, config: *const Config, state: *DaemonState, event_bus: *bus_mod.Bus) void {
    const state_path = stateFilePath(allocator, config) catch return;
    defer allocator.free(state_path);

    const owner_instance_id = if (config.tenant.enabled)
        tenant_lock.resolveOwnerId(allocator) catch null
    else
        null;
    defer if (owner_instance_id) |oid| allocator.free(oid);
    var pg_mgr: ?*zaki_state.Manager = null;
    defer if (pg_mgr) |state_mgr| {
        state_mgr.deinit();
        allocator.destroy(state_mgr);
    };
    if (config.tenant.enabled and std.mem.eql(u8, config.state.backend, "postgres")) init_pg: {
        const mgr = allocator.create(zaki_state.Manager) catch |err| {
            log.warn("heartbeat postgres state disabled: manager alloc failed: {}", .{err});
            break :init_pg;
        };
        errdefer allocator.destroy(mgr);
        mgr.* = zaki_state.Manager.init(allocator, config.state) catch |err| {
            allocator.destroy(mgr);
            log.warn("heartbeat postgres state disabled: state init failed: {}", .{err});
            break :init_pg;
        };
        pg_mgr = mgr;
    }

    // V1.13 Day 2.2 — extraction queue worker primitives. Initialized
    // once at heartbeat thread startup, reused for the lifetime of the
    // daemon. Both are optional — if init fails (no API key, missing
    // model), the worker tick is a no-op and trigger sites continue
    // running inline (V1.12 fallback).
    //
    // Provider: same RuntimeProviderBundle the agent path uses (Kimi
    // K2.6 via Together by default). The bundle is heap-allocated so
    // we can pass a stable Provider interface to processOneExtractionJob.
    //
    // Embedder: created via the same factory memory_runtimes use
    // (createEmbeddingProvider). Together-hosted bge-large by default.
    var worker_provider_bundle: ?*providers.runtime_bundle.RuntimeProviderBundle = null;
    defer if (worker_provider_bundle) |b| {
        b.deinit();
        allocator.destroy(b);
    };
    // HI-02 fix: collapsed redundant inner check. EmbeddingProvider.deinit
    // consumes self by value via the vtable; one captured deinit suffices.
    var worker_embedder: ?embeddings.EmbeddingProvider = null;
    defer if (worker_embedder) |e| e.deinit();
    if (pg_mgr != null) init_worker: {
        const bundle_ptr = allocator.create(providers.runtime_bundle.RuntimeProviderBundle) catch |err| {
            log.warn("extraction_queue.worker.bundle_alloc_failed err={s}", .{@errorName(err)});
            break :init_worker;
        };
        errdefer allocator.destroy(bundle_ptr);
        bundle_ptr.* = providers.runtime_bundle.RuntimeProviderBundle.init(allocator, config) catch |err| {
            log.warn("extraction_queue.worker.bundle_init_failed err={s}", .{@errorName(err)});
            allocator.destroy(bundle_ptr);
            break :init_worker;
        };
        worker_provider_bundle = bundle_ptr;

        // Resolve embedding provider api_key from config.providers list
        // OR env var fallback (same logic memory/root.zig::resolveEmbeddingApiKey
        // uses, copy-locally since that helper isn't exported).
        const embed_provider_name = config.memory.search.provider;
        if (!std.mem.eql(u8, embed_provider_name, "none")) {
            const api_key_lookup = providerNameForEmbeddingApiKey(embed_provider_name);
            // HI-03 fix: when config.providers has a matching entry but
            // the dupe OOMs, fall through to the env-var resolver
            // instead of giving up. Prior code did `break :blk null`
            // which left embedder dead even when TOGETHER_API_KEY was
            // set in the environment.
            const api_key_owned: ?[]u8 = blk: {
                if (config.providers.len > 0) {
                    for (config.providers) |entry| {
                        if (entry.api_key) |k| {
                            if (std.mem.eql(u8, providerNameForEmbeddingApiKey(entry.name), api_key_lookup)) {
                                if (allocator.dupe(u8, k)) |duped| break :blk duped else |_| {}
                                // Dupe failed; fall through to env-var fallback.
                            }
                        }
                    }
                }
                break :blk providers.resolveApiKey(allocator, api_key_lookup, null) catch null;
            };
            defer if (api_key_owned) |k| allocator.free(k);

            const ep = embeddings.createEmbeddingProvider(
                allocator,
                embed_provider_name,
                api_key_owned,
                config.memory.search.model,
                config.memory.search.dimensions,
            ) catch |err| blk: {
                log.warn("extraction_queue.worker.embedder_init_failed err={s}", .{@errorName(err)});
                break :blk null;
            };
            if (ep) |e| {
                worker_embedder = e;
                log.info(
                    "extraction_queue.worker.ready embed_provider={s} embed_model={s}",
                    .{ embed_provider_name, config.memory.search.model },
                );
            }
        }
    }

    var last_flush_s: i64 = 0;
    var last_sweep_s: i64 = 0;
    while (!isShutdownRequested()) {
        const now_s = std.time.timestamp();
        if (now_s - last_flush_s >= STATUS_FLUSH_SECONDS or now_s < last_flush_s) {
            last_flush_s = now_s;
            // S4.7 — heartbeat state-file silent catch closed. Parity with
            // the startup-path log at :2034. Before: a failing write left
            // the component marked healthy when it wasn't. After: mark as
            // error + log on failure, skip the ok-mark; next successful
            // flush re-marks healthy via the markComponentOk branch.
            if (writeStateFile(allocator, state_path, state)) |_| {
                health.markComponentOk("heartbeat");
            } else |err| {
                health.markComponentError("heartbeat", @errorName(err));
                log.warn("heartbeat.state_flush_failed path={s} err={s}", .{ state_path, @errorName(err) });
            }
        }

        var wake_processed: usize = 0;
        while (wake_processed < HEARTBEAT_WAKE_MAX_DRAIN_PER_TICK) : (wake_processed += 1) {
            const req = heartbeat_wake.dequeue() orelse break;
            defer {
                var mut_req = req;
                mut_req.deinit();
            }
            if (!config.tenant.enabled) continue;
            const owner_id = owner_instance_id orelse continue;
            runTenantHeartbeatSweep(allocator, config, event_bus, owner_id, req.user_id, req.reason, true, pg_mgr);
        }
        const wake_pending = heartbeat_wake.pendingCount();
        if (wake_pending > 0) {
            log.debug("heartbeat wake backlog pending={d} processed_this_tick={d}", .{ wake_pending, wake_processed });
        }

        if (config.tenant.enabled and owner_instance_id != null) {
            if (now_s - last_sweep_s >= HEARTBEAT_SWEEP_INTERVAL_SECS or now_s < last_sweep_s) {
                last_sweep_s = now_s;
                runTenantHeartbeatSweep(allocator, config, event_bus, owner_instance_id.?, null, "interval", false, pg_mgr);
            }
        }

        // V1.13 Day 2.2 — Extraction queue worker tick.
        //
        // Drains pending jobs (max 5 per tick = max 5 LLM calls/sec
        // worst-case) into entity_pipeline.runOnTurn out-of-band. Agent
        // turn loop already returned in <5ms (enqueue-only on producer
        // side once the trigger sites are cut over).
        if (pg_mgr) |worker_mgr| {
            if (worker_provider_bundle) |bundle| {
                if (worker_embedder) |embedder| {
                    var jobs_processed: usize = 0;
                    // HI-04 fix: dropped 5 → 2. Worst-case worker tick
                    // = MAX_JOBS_PER_TICK × per-job-timeout. With 5 × 10s
                    // = 50s the heartbeat thread could stall state-flush
                    // / channel-watch / idle-sweep for ~50s (still long).
                    // 2 × 10s = 20s is acceptable. Drains 2 jobs/sec
                    // sustained = 7200/hr = headroom for any realistic
                    // load on a single user; multi-tenant scale uses
                    // per-cell pods anyway (each gets its own daemon).
                    const MAX_JOBS_PER_TICK: usize = 2;
                    while (jobs_processed < MAX_JOBS_PER_TICK) : (jobs_processed += 1) {
                        const had_job = processOneExtractionJob(
                            allocator,
                            config,
                            worker_mgr,
                            bundle.provider(),
                            embedder,
                        ) catch |err| blk: {
                            log.warn("extraction_queue.worker_tick_err err={s}", .{@errorName(err)});
                            break :blk false;
                        };
                        if (!had_job) break;
                    }
                    if (jobs_processed > 0) {
                        log.info("extraction_queue.tick processed={d}", .{jobs_processed});
                    }
                    // HI-01 fix: periodic backlog warn so silent
                    // worker-init failure (HI-01 from review) doesn't
                    // let queue grow forever without an alert. Check
                    // every 60 ticks (~60s) and warn if backlog > 50.
                    if (last_flush_s != 0 and @mod(now_s, 60) == 0) {
                        const backlog = worker_mgr.countPendingExtractionJobs() catch 0;
                        if (backlog > 50) {
                            log.warn("extraction_queue.backlog_high pending={d} — worker may not be processing", .{backlog});
                        }
                    }
                }
            }
        }

        std.Thread.sleep(std.time.ns_per_s);
    }
}

/// V1.13 Day 2.2 — process one extraction job from the queue. Returns
/// true when a job was processed (drain loop continues), false when
/// queue empty (drain loop stops). All errors are failure-soft.
fn processOneExtractionJob(
    allocator: std.mem.Allocator,
    config: *const Config,
    state_mgr: *zaki_state.Manager,
    provider: providers.Provider,
    embedder: embeddings.EmbeddingProvider,
) !bool {
    const job = (try state_mgr.claimNextExtractionJob(allocator)) orelse return false;
    defer job.deinit(allocator);

    const t_start = std.time.milliTimestamp();
    log.info("extraction_queue.processing job_id={d} type={s} user={d} attempts={d}", .{
        job.id, job.job_type, job.user_id, job.attempts,
    });

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, job.payload_json, .{}) catch |err| {
        log.warn("extraction_queue.payload_parse_failed job_id={d} err={s}", .{ job.id, @errorName(err) });
        state_mgr.markExtractionJobFailed(job.id, "parse_failed") catch {};
        return true;
    };
    defer parsed.deinit();

    const text_field: []const u8 = blk: {
        if (parsed.value != .object) break :blk "";
        if (std.mem.eql(u8, job.job_type, "wiki_link")) {
            if (parsed.value.object.get("turn_text")) |v| {
                if (v == .string) break :blk v.string;
            }
        } else if (std.mem.eql(u8, job.job_type, "session_end")) {
            if (parsed.value.object.get("transcript_text")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        break :blk "";
    };

    if (text_field.len < 8) {
        log.warn("extraction_queue.payload_text_missing job_id={d} type={s}", .{ job.id, job.job_type });
        state_mgr.markExtractionJobDone(job.id) catch {};
        return true;
    }

    const model_name = config.default_model orelse "moonshotai/Kimi-K2.6";
    // V1.14.3 (G-03 closure) — Pass the job's session_id as the episode
    // anchor for all edges emitted from this job. The daemon already
    // holds `job.session_id` per the ExtractionJob struct (V1.13 schema).
    // Empty string → null so upsertMemoryEdgeRich's empty-string guard
    // (MD-02 fix) treats it correctly. Same `episode_key` is appended
    // (deduped) to every edge emitted from this job, so re-running the
    // same job (retry path) doesn't double-write into `episodes[]`.
    const episode_key_for_run: ?[]const u8 = if (job.session_id.len == 0) null else job.session_id;
    const stats = entity_pipeline.runOnTurn(
        allocator,
        provider,
        model_name,
        state_mgr,
        embedder,
        job.user_id,
        text_field,
        // V1.13 watch-finding N-02 fix: 10s → 30s. Watch session
        // (2026-05-08) revealed chat path's `message_timeout_secs=300`
        // tolerates Together response times of 13-120s observed in
        // production. My HI-04 fix from earlier this branch
        // (30s → 10s) was below Together's actual latency floor on
        // slow days, so EVERY extraction call timed out while chat
        // calls (same provider, same model) succeeded.
        //
        // 30s per-job × MAX_JOBS_PER_TICK=2 = 60s max heartbeat
        // stall. Better than HI-04's original concern (150s) without
        // starving real Together latency. provider_reliable's inner
        // retry behavior amplifies the stall but only on actual
        // transient failures; on success it returns at first success.
        30, // per-job timeout — matches Together's typical latency floor
        episode_key_for_run, // V1.14.3 (G-03): edge provenance anchor
    );
    const elapsed = std.time.milliTimestamp() - t_start;
    log.info(
        "extraction_queue.processed job_id={d} type={s} outcome={s} mentions={d} edges={d} elapsed_ms={d}",
        .{ job.id, job.job_type, @tagName(stats.outcome), stats.mentions_extracted, stats.edges_emitted, elapsed },
    );
    if (stats.outcome == .ok) {
        state_mgr.markExtractionJobDone(job.id) catch {};
    } else {
        state_mgr.markExtractionJobFailed(job.id, @tagName(stats.outcome)) catch {};
    }
    return true;
}

/// V1.13 Day 2.2 — embedding provider name normalizer (mirrors
/// memory/root.zig::providerNameForEmbeddingApiKey, copied locally
/// because that helper is private).
fn providerNameForEmbeddingApiKey(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "together-ai")) return "together";
    return name;
}

/// How often the channel watcher checks health (seconds).
const CHANNEL_WATCH_INTERVAL_SECS: u64 = 60;

/// Initial backoff for scheduler restarts (seconds).
/// Kept for compatibility with existing tests and supervision semantics.
const SCHEDULER_INITIAL_BACKOFF_SECS: u64 = 1;

/// Maximum backoff for scheduler restarts (seconds).
/// Kept for compatibility with existing tests and supervision semantics.
const SCHEDULER_MAX_BACKOFF_SECS: u64 = 60;

/// Ownership lock TTL for per-user writer fencing in tenant mode.
const TENANT_OWNERSHIP_LOCK_LEASE_SECS: u64 = 300;

const SchedulerJobSnapshot = struct {
    next_run_secs: i64,
    last_run_secs: ?i64,
    last_status: ?[]const u8,
    paused: bool,
    one_shot: bool,
};

fn schedulerStatusEquals(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn schedulerJobChanged(job: *const cron.CronJob, snapshot: SchedulerJobSnapshot) bool {
    if (job.next_run_secs != snapshot.next_run_secs) return true;
    if (job.last_run_secs != snapshot.last_run_secs) return true;
    if (job.paused != snapshot.paused) return true;
    if (job.one_shot != snapshot.one_shot) return true;
    if (!schedulerStatusEquals(job.last_status, snapshot.last_status)) return true;
    return false;
}

fn runCronAgentTurnWithBus(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    scheduler: *const CronScheduler,
    job: *const cron.CronJob,
    prompt: []const u8,
    out_bus: ?*bus_mod.Bus,
) ![]const u8 {
    const cfg_ptr = ctx orelse return error.InvalidArgument;
    const cfg: *const Config = @ptrCast(@alignCast(cfg_ptr));

    // V1.13 Day 5.2 — dream-as-cron sentinel. When cron.json has
    // `command: "dream"` (a 5-character sentinel; clean for users to
    // type), substitute the full dream_system_prompt before running
    // the agent turn. This way users get a one-word cron entry while
    // the agent sees the full reflection contract. Avoids requiring
    // users to paste 800-char prompts into cron.json.
    //
    // Cron entry shape:
    //   { "id": "dream_3am_user_1", "user_id": 1,
    //     "schedule": "0 3 * * *", "kind": "agent",
    //     "command": "dream", "session_target": "isolated" }
    const dream_mod = @import("agent/dream.zig");
    const effective_prompt: []const u8 = if (std.mem.eql(u8, prompt, "dream"))
        dream_mod.dream_system_prompt
    else
        prompt;

    if (job.session_target == .main and job.wake_mode == .next_heartbeat) {
        if (scheduler.context_user_id) |user_id| {
            const reason = try std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ CRON_WAKE_REASON_NEXT_HEARTBEAT_PREFIX, job.id },
            );
            defer allocator.free(reason);
            try heartbeat_wake.enqueue(user_id, reason);
            return allocator.dupe(u8, "");
        }
    }

    var runtime_cfg = cfg.*;
    if (scheduler.context_workspace) |workspace| {
        runtime_cfg.workspace_dir = workspace;
    }
    // Ensure prompt/bootstrap files exist for first-run tenant workspaces.
    const project_ctx = if (scheduler.context_user_id != null)
        onboard.zakiBotProjectContext()
    else
        onboard.projectContextForConfig(&runtime_cfg);
    onboard.scaffoldWorkspace(allocator, runtime_cfg.workspace_dir, &project_ctx) catch {};

    var runtime = try channel_loop.ChannelRuntime.init(allocator, &runtime_cfg, out_bus);
    defer runtime.deinit();

    const turn_origin: tools_mod.TurnOrigin = resolveCronTurnOrigin(job);

    // S2.5: Enforcement chokepoint 3 — scheduler job dispatch.
    // A canceled/expired user or a free-tier user with proactive disabled
    // must not have background turns burning compute. Resolved via the
    // pluggable entitlement resolver (S2.1 will populate it; until then
    // null means "use default pro/active" and this gate is a no-op).
    {
        const entitlement = if (scheduler.context_user_id) |uid|
            entitlement_mod.resolveUserEntitlement(uid) orelse entitlement_mod.Entitlement{}
        else
            entitlement_mod.Entitlement{};
        const now_unix = std.time.timestamp();
        if (!entitlement.canAct(now_unix)) {
            log.info("cron.skipped reason=entitlement_inactive user={s} status={s} job_id={s}", .{
                scheduler.context_user_id orelse "-",
                entitlement.status.toSlice(),
                job.id,
            });
            return allocator.dupe(u8, "");
        }
        const effective_tier = entitlement.effectiveTier(now_unix);
        const limits = entitlement_mod.Entitlement.limitsFor(effective_tier);
        const is_proactive = switch (turn_origin) {
            .heartbeat, .scheduler, .proactive, .wake => true,
            .user, .mcp => false, // mcp = external foreground caller, never proactive
        };
        if (is_proactive and !limits.proactive_enabled) {
            log.info("cron.skipped reason=entitlement_proactive_disabled user={s} tier={s} job_id={s}", .{
                scheduler.context_user_id orelse "-",
                effective_tier.toSlice(),
                job.id,
            });
            return allocator.dupe(u8, "");
        }
        // Full propagation of entitlement onto RuntimeTurnContext for the
        // downstream tool-preflight gate (S2.4) is tracked as part of S2.1
        // — session.processMessageWithContext sets the RuntimeTurnContext
        // and that's where the entitlement field needs to flow in. Until
        // then, cron-originated turns skip S2.4's per-tool entitlement
        // check and rely on this dispatch-level gate plus the existing
        // background-origin policy.
    }

    const lane_resolution = resolveCronSessionLaneWithMetrics(job, turn_origin);

    var session_buf: [256]u8 = undefined;
    const session_key = blk: {
        if (scheduler.context_user_id) |user_id| {
            if (lane_resolution.effective_target == .main) {
                break :blk zaki_session.userMainSessionKey(&session_buf, user_id);
            }
            break :blk zaki_session.userCronSessionKey(&session_buf, user_id, job.id);
        }
        if (lane_resolution.effective_target == .main) break :blk zaki_session.fallbackMainSessionKey();
        break :blk zaki_session.fallbackCronSessionKey();
    };

    const numeric_user_id = if (scheduler.context_user_id) |user_id|
        std.fmt.parseInt(i64, user_id, 10) catch null
    else
        null;
    var tenant_state_mgr: ?zaki_state.Manager = null;
    if (runtime_cfg.tenant.enabled and
        std.mem.eql(u8, runtime_cfg.state.backend, "postgres") and
        numeric_user_id != null)
    {
        tenant_state_mgr = zaki_state.Manager.init(allocator, runtime_cfg.state) catch null;
    }
    defer if (tenant_state_mgr) |*mgr| mgr.deinit();
    tools_mod.setTenantContext(.{
        .user_id = scheduler.context_user_id,
        .numeric_user_id = numeric_user_id,
        .session_key = session_key,
        .state_mgr = if (tenant_state_mgr) |*mgr| mgr else null,
        .expect_postgres_state = runtime_cfg.tenant.enabled and std.mem.eql(u8, runtime_cfg.state.backend, "postgres"),
    });
    defer tools_mod.clearTenantContext();

    return runtime.session_mgr.processMessageWithContext(session_key, effective_prompt, null, .{
        .turn_origin = turn_origin,
    });
}

fn runCronAgentTurn(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    scheduler: *const CronScheduler,
    job: *const cron.CronJob,
    prompt: []const u8,
) ![]const u8 {
    return runCronAgentTurnWithBus(
        ctx,
        allocator,
        scheduler,
        job,
        prompt,
        scheduler.tick_out_bus,
    );
}

fn resolveCronTurnOrigin(job: *const cron.CronJob) tools_mod.TurnOrigin {
    if (std.mem.eql(u8, job.command, HEARTBEAT_WAKE_COMMAND)) return .wake;
    if (std.mem.eql(u8, job.id, "heartbeat")) return .heartbeat;
    return switch (job.delivery.mode) {
        .none => .scheduler,
        else => .proactive,
    };
}

const CronSessionLaneResolution = struct {
    effective_target: cron.SessionTarget,
    rerouted_from_main: bool = false,
};

fn resolveCronSessionTarget(
    job: *const cron.CronJob,
    turn_origin: tools_mod.TurnOrigin,
) CronSessionLaneResolution {
    if (job.session_target == .main and turn_origin != .user) {
        return .{
            .effective_target = .isolated,
            .rerouted_from_main = true,
        };
    }
    return .{
        .effective_target = job.session_target,
        .rerouted_from_main = false,
    };
}

fn resolveCronSessionLaneWithMetrics(
    job: *const cron.CronJob,
    turn_origin: tools_mod.TurnOrigin,
) CronSessionLaneResolution {
    const resolution = resolveCronSessionTarget(job, turn_origin);
    if (resolution.rerouted_from_main) {
        lane_metrics.recordBackgroundMainReroute(job.id);
        log.info("cron.main_reroute job_id={s} origin={s} effective_target={s}", .{
            job.id,
            turn_origin.toSlice(),
            resolution.effective_target.asStr(),
        });
    }
    return resolution;
}

fn clearSchedulerSnapshot(
    allocator: std.mem.Allocator,
    snapshot: *std.StringHashMapUnmanaged(SchedulerJobSnapshot),
) void {
    var it = snapshot.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    snapshot.clearRetainingCapacity();
}

fn buildSchedulerSnapshot(
    allocator: std.mem.Allocator,
    scheduler: *const CronScheduler,
    snapshot: *std.StringHashMapUnmanaged(SchedulerJobSnapshot),
) !void {
    clearSchedulerSnapshot(allocator, snapshot);
    for (scheduler.listJobs()) |job| {
        const key = try allocator.dupe(u8, job.id);
        snapshot.put(allocator, key, .{
            .next_run_secs = job.next_run_secs,
            .last_run_secs = job.last_run_secs,
            .last_status = job.last_status,
            .paused = job.paused,
            .one_shot = job.one_shot,
        }) catch |err| {
            allocator.free(key);
            return err;
        };
    }
}

fn upsertSchedulerRuntimeJob(
    allocator: std.mem.Allocator,
    latest: *CronScheduler,
    runtime_job: *const cron.CronJob,
) !void {
    if (latest.getMutableJob(runtime_job.id)) |dst| {
        dst.next_run_secs = runtime_job.next_run_secs;
        dst.last_run_secs = runtime_job.last_run_secs;
        dst.last_status = runtime_job.last_status;
        dst.paused = runtime_job.paused;
        dst.one_shot = runtime_job.one_shot;
        return;
    }

    try latest.jobs.append(allocator, .{
        .id = try allocator.dupe(u8, runtime_job.id),
        .expression = try allocator.dupe(u8, runtime_job.expression),
        .command = try allocator.dupe(u8, runtime_job.command),
        .next_run_secs = runtime_job.next_run_secs,
        .last_run_secs = runtime_job.last_run_secs,
        .last_status = runtime_job.last_status,
        .paused = runtime_job.paused,
        .one_shot = runtime_job.one_shot,
    });
}

fn mergeSchedulerTickChangesAndSave(
    allocator: std.mem.Allocator,
    runtime: *const CronScheduler,
    before_tick: *const std.StringHashMapUnmanaged(SchedulerJobSnapshot),
) !void {
    var latest = CronScheduler.init(allocator, runtime.max_tasks, runtime.enabled);
    defer latest.deinit();
    try cron.loadJobsStrict(&latest);

    var runtime_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer runtime_ids.deinit(allocator);

    for (runtime.listJobs()) |job| {
        try runtime_ids.put(allocator, job.id, {});
        if (before_tick.get(job.id)) |snapshot| {
            if (!schedulerJobChanged(&job, snapshot)) continue;
        }
        try upsertSchedulerRuntimeJob(allocator, &latest, &job);
    }

    var removed_it = before_tick.iterator();
    while (removed_it.next()) |entry| {
        const job_id = entry.key_ptr.*;
        if (!runtime_ids.contains(job_id)) {
            _ = latest.removeJob(job_id);
        }
    }

    try cron.saveJobs(&latest);
}

fn runTenantSchedulerTick(
    allocator: std.mem.Allocator,
    config: *const Config,
    event_bus: *bus_mod.Bus,
    owner_instance_id: []const u8,
) !void {
    var users_dir = std.fs.openDirAbsolute(config.tenant.data_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer users_dir.close();

    var iter = users_dir.iterate();
    const now = std.time.timestamp();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0) continue;

        const user_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tenant.data_root, entry.name });
        defer allocator.free(user_root);
        const cron_path = try std.fmt.allocPrint(allocator, "{s}/cron.json", .{user_root});
        defer allocator.free(cron_path);
        const workspace_path = try std.fmt.allocPrint(allocator, "{s}/workspace", .{user_root});
        defer allocator.free(workspace_path);
        var ownership_lock = tenant_lock.acquireUserOwnershipLock(
            allocator,
            user_root,
            owner_instance_id,
            TENANT_OWNERSHIP_LOCK_LEASE_SECS,
        ) catch |err| switch (err) {
            error.LockHeld => {
                log.debug("tenant scheduler ownership lock held for user={s}", .{entry.name});
                continue;
            },
            else => {
                log.warn("tenant scheduler ownership lock failed for user={s}: {}", .{ entry.name, err });
                continue;
            },
        };
        defer ownership_lock.deinit();

        var scheduler = CronScheduler.init(allocator, config.scheduler.max_tasks, config.scheduler.enabled);
        defer scheduler.deinit();
        scheduler.setAgentRunner(runCronAgentTurn, @ptrCast(@constCast(config)));
        scheduler.setExecutionContext(entry.name, user_root, workspace_path) catch continue;
        scheduler.setTenantStateContext(null, null, false);
        cron.loadJobsFromPath(&scheduler, cron_path) catch |err| {
            log.warn("tenant scheduler load failed for user={s}: {}", .{ entry.name, err });
            continue;
        };

        const changed = scheduler.tick(now, event_bus);
        if (changed) {
            cron.saveJobsToPath(&scheduler, cron_path) catch |err| {
                log.warn("tenant scheduler save failed for user={s}: {}", .{ entry.name, err });
            };
        }
    }
}

fn runTenantSchedulerTickPostgres(
    allocator: std.mem.Allocator,
    config: *const Config,
    event_bus: *bus_mod.Bus,
    owner_instance_id: []const u8,
    mgr: *zaki_state.Manager,
) !void {
    const now = std.time.timestamp();
    const claimed = mgr.claimDueJobs(allocator, owner_instance_id, now, TENANT_OWNERSHIP_LOCK_LEASE_SECS, config.scheduler.max_tasks) catch |err| {
        log.warn("postgres tenant scheduler claim failed owner={s} now={d}: {}", .{ owner_instance_id, now, err });
        return err;
    };
    defer {
        for (claimed) |*job| job.deinit(allocator);
        allocator.free(claimed);
    }

    if (claimed.len == 0) return;

    for (claimed) |job| {
        var scheduler = CronScheduler.init(allocator, 1, config.scheduler.enabled);
        defer scheduler.deinit();
        scheduler.setAgentRunner(runCronAgentTurn, @ptrCast(@constCast(config)));

        var user_buf: [32]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_buf, "{d}", .{job.user_id});
        const user_root = std.fs.path.dirname(job.workspace_path) orelse "";
        try scheduler.setExecutionContext(user_id_text, user_root, job.workspace_path);
        scheduler.setTenantStateContext(job.user_id, mgr, true);

        const started_at_s = std.time.timestamp();
        var finish_status: []const u8 = "error";
        var finish_output: ?[]const u8 = null;
        var next_run_secs: ?i64 = null;
        var raw_job_json: ?[]u8 = null;
        defer if (raw_job_json) |json| allocator.free(json);

        cron.loadJobFromJsonSlice(&scheduler, job.raw_job_json) catch |err| {
            log.warn("postgres tenant scheduler parse failed for user={d} job={s}: {}", .{ job.user_id, job.id, err });
            finish_output = "invalid cron job payload";
            next_run_secs = started_at_s + 60;
            raw_job_json = allocator.dupe(u8, job.raw_job_json) catch null;
            const finished_at_s = std.time.timestamp();
            mgr.completeClaimedJob(job.user_id, job.id, owner_instance_id, raw_job_json, next_run_secs, finish_status, finish_output, started_at_s, finished_at_s) catch |complete_err| {
                log.warn("postgres tenant scheduler finalize failed for invalid job={s}: {}", .{ job.id, complete_err });
            };
            continue;
        };
        _ = scheduler.tick(std.time.timestamp(), event_bus);
        if (scheduler.listJobs().len == 0) {
            finish_status = "ok";
        } else {
            const updated_job = scheduler.listJobs()[0];
            finish_status = updated_job.last_status orelse "unknown";
            finish_output = updated_job.last_output;
            next_run_secs = if (updated_job.one_shot or updated_job.delete_after_run) null else updated_job.next_run_secs;
            raw_job_json = try cron.jobToJson(allocator, &updated_job);
        }
        const finished_at_s = std.time.timestamp();
        mgr.completeClaimedJob(job.user_id, job.id, owner_instance_id, raw_job_json, next_run_secs, finish_status, finish_output, started_at_s, finished_at_s) catch |err| {
            log.warn("postgres tenant scheduler finalize failed user={d} job={s}: {}", .{ job.user_id, job.id, err });
            return err;
        };
    }
}

/// Scheduler thread — executes due cron jobs and periodically reloads cron.json
/// so tasks created/updated after daemon startup are picked up without restart.
fn schedulerThread(allocator: std.mem.Allocator, config: *const Config, state: *DaemonState, event_bus: *bus_mod.Bus) void {
    const poll_secs: u64 = @max(@as(u64, 1), config.reliability.scheduler_poll_secs);

    if (config.tenant.enabled) {
        const owner_instance_id = tenant_lock.resolveOwnerId(allocator) catch null;
        defer if (owner_instance_id) |oid| allocator.free(oid);
        if (owner_instance_id == null) {
            log.warn("tenant scheduler disabled: failed to resolve owner id", .{});
            state.markError("scheduler", "owner_id_failed");
            health.markComponentError("scheduler", "owner_id_failed");
            return;
        }
        var pg_mgr: ?*zaki_state.Manager = null;
        defer if (pg_mgr) |state_mgr| {
            state_mgr.deinit();
            allocator.destroy(state_mgr);
        };
        if (std.mem.eql(u8, config.state.backend, "postgres")) init_pg: {
            const mgr = allocator.create(zaki_state.Manager) catch |err| {
                log.warn("tenant postgres scheduler disabled: manager alloc failed: {}", .{err});
                state.markError("scheduler", "postgres_state_alloc_failed");
                health.markComponentError("scheduler", "postgres_state_alloc_failed");
                break :init_pg;
            };
            errdefer allocator.destroy(mgr);
            mgr.* = zaki_state.Manager.init(allocator, config.state) catch |err| {
                allocator.destroy(mgr);
                log.warn("tenant postgres scheduler disabled: state init failed: {}", .{err});
                state.markError("scheduler", "postgres_state_init_failed");
                health.markComponentError("scheduler", "postgres_state_init_failed");
                break :init_pg;
            };
            pg_mgr = mgr;
        }
        state.markRunning("scheduler");
        health.markComponentOk("scheduler");
        while (!isShutdownRequested()) {
            const tick_result = if (pg_mgr) |mgr|
                runTenantSchedulerTickPostgres(allocator, config, event_bus, owner_instance_id.?, mgr)
            else
                runTenantSchedulerTick(allocator, config, event_bus, owner_instance_id.?);
            tick_result catch |err| {
                log.warn("tenant scheduler tick failed: {}", .{err});
                state.markError("scheduler", @errorName(err));
                health.markComponentError("scheduler", @errorName(err));
            };
            state.markRunning("scheduler");
            health.markComponentOk("scheduler");

            var slept_tenant: u64 = 0;
            while (slept_tenant < poll_secs and !isShutdownRequested()) : (slept_tenant += 1) {
                std.Thread.sleep(std.time.ns_per_s);
            }
        }
        return;
    }

    var scheduler = CronScheduler.init(allocator, config.scheduler.max_tasks, config.scheduler.enabled);
    defer scheduler.deinit();
    scheduler.setAgentRunner(runCronAgentTurn, @ptrCast(@constCast(config)));
    var before_tick: std.StringHashMapUnmanaged(SchedulerJobSnapshot) = .empty;
    defer {
        clearSchedulerSnapshot(allocator, &before_tick);
        before_tick.deinit(allocator);
    }

    // Initial load from disk. Use the strict policy so a transient boot-time
    // read/parse error is surfaced loudly rather than silently starting with
    // an empty scheduler that would then let the reload self-heal path
    // overwrite cron.json with the empty state (permanent data loss).
    // FileNotFound is legitimate (fresh install) and is swallowed inside
    // loadJobsStrict. Any other error leaves loaded_from_disk=false, which
    // the reload-self-heal branch in cron.zig refuses to overwrite.
    cron.loadJobsStrict(&scheduler) catch |err| {
        log.err("scheduler boot-load failed; starting with empty in-memory jobs and refusing to overwrite cron.json until a successful load: {s}", .{@errorName(err)});
        state.markError("scheduler", @errorName(err));
        health.markComponentError("scheduler", @errorName(err));
    };

    state.markRunning("scheduler");
    health.markComponentOk("scheduler");

    while (!isShutdownRequested()) {
        // Refresh scheduler view from store so jobs created/updated after daemon startup are picked up.
        cron.reloadJobs(&scheduler) catch |err| {
            log.warn("scheduler reload failed: {}", .{err});
            state.markError("scheduler", @errorName(err));
            health.markComponentError("scheduler", @errorName(err));
        };

        buildSchedulerSnapshot(allocator, &scheduler, &before_tick) catch |err| {
            log.warn("scheduler snapshot failed: {}", .{err});
            state.markError("scheduler", @errorName(err));
            health.markComponentError("scheduler", @errorName(err));
            var snapshot_sleep: u64 = 0;
            while (snapshot_sleep < poll_secs and !isShutdownRequested()) : (snapshot_sleep += 1) {
                std.Thread.sleep(std.time.ns_per_s);
            }
            continue;
        };

        const changed = scheduler.tick(std.time.timestamp(), event_bus);
        if (changed) {
            mergeSchedulerTickChangesAndSave(allocator, &scheduler, &before_tick) catch |err| {
                log.warn("scheduler merge-save failed: {}", .{err});
                state.markError("scheduler", @errorName(err));
                health.markComponentError("scheduler", @errorName(err));
            };
        }

        state.markRunning("scheduler");
        health.markComponentOk("scheduler");

        var slept: u64 = 0;
        while (slept < poll_secs and !isShutdownRequested()) : (slept += 1) {
            std.Thread.sleep(std.time.ns_per_s);
        }
    }
}

/// Stale detection threshold: 3x the Telegram long-poll timeout (30s).
const STALE_THRESHOLD_SECS: i64 = 90;

/// Channel supervisor thread — spawns polling threads for configured channels,
/// monitors their health, and restarts on failure using SupervisedChannel.
fn channelSupervisorThread(
    allocator: std.mem.Allocator,
    config: *const Config,
    state: *DaemonState,
    channel_registry: *dispatch.ChannelRegistry,
    channel_rt: ?*channel_loop.ChannelRuntime,
    event_bus: *bus_mod.Bus,
) void {
    var mgr = channel_manager.ChannelManager.init(allocator, config, channel_registry) catch {
        state.markError("channels", "init_failed");
        health.markComponentError("channels", "init_failed");
        return;
    };
    defer mgr.deinit();

    if (channel_rt) |rt| mgr.setRuntime(rt);
    mgr.setEventBus(event_bus);

    mgr.collectConfiguredChannels() catch |err| {
        state.markError("channels", @errorName(err));
        health.markComponentError("channels", @errorName(err));
        return;
    };

    const started = mgr.startAll() catch |err| {
        state.markError("channels", @errorName(err));
        health.markComponentError("channels", @errorName(err));
        return;
    };

    if (started > 0) {
        state.markRunning("channels");
        health.markComponentOk("channels");
        mgr.supervisionLoop(state); // blocks until shutdown
    } else {
        health.markComponentOk("channels");
    }
}

/// Inbound dispatcher thread:
/// consumes inbound events from channels, runs SessionManager, publishes outbound replies.
const ParsedInboundMetadata = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    fields: channel_adapters.InboundMetadata = .{},

    fn deinit(self: *ParsedInboundMetadata) void {
        if (self.parsed) |*pm| pm.deinit();
    }
};

fn parseInboundMetadata(allocator: std.mem.Allocator, metadata_json: ?[]const u8) ParsedInboundMetadata {
    var parsed = ParsedInboundMetadata{};
    const meta_json = metadata_json orelse return parsed;

    parsed.parsed = std.json.parseFromSlice(std.json.Value, allocator, meta_json, .{}) catch null;
    if (parsed.parsed) |*pm| {
        if (pm.value != .object) return parsed;

        if (pm.value.object.get("account_id")) |v| {
            if (v == .string) parsed.fields.account_id = v.string;
        }
        if (pm.value.object.get("peer_kind")) |v| {
            if (v == .string) parsed.fields.peer_kind = channel_adapters.parsePeerKind(v.string);
        }
        if (pm.value.object.get("peer_id")) |v| {
            if (v == .string and v.string.len > 0) parsed.fields.peer_id = v.string;
        }
        if (pm.value.object.get("message_id")) |v| {
            if (v == .string and v.string.len > 0) parsed.fields.message_id = v.string;
        }
        if (pm.value.object.get("guild_id")) |v| {
            if (v == .string) parsed.fields.guild_id = v.string;
        }
        if (pm.value.object.get("team_id")) |v| {
            if (v == .string) parsed.fields.team_id = v.string;
        }
        if (pm.value.object.get("channel_id")) |v| {
            if (v == .string) parsed.fields.channel_id = v.string;
        }
        if (pm.value.object.get("thread_id")) |v| {
            if (v == .string and v.string.len > 0) parsed.fields.thread_id = v.string;
        }
        if (pm.value.object.get("is_dm")) |v| {
            if (v == .bool) parsed.fields.is_dm = v.bool;
        }
        if (pm.value.object.get("is_group")) |v| {
            if (v == .bool) parsed.fields.is_group = v.bool;
        }
        if (pm.value.object.get("sender_number")) |v| {
            if (v == .string and v.string.len > 0) parsed.fields.sender_number = v.string;
        }
        if (pm.value.object.get("sender_uuid")) |v| {
            if (v == .string and v.string.len > 0) parsed.fields.sender_uuid = v.string;
        }
        if (pm.value.object.get("group_id")) |v| {
            if (v == .string and v.string.len > 0) parsed.fields.group_id = v.string;
        }
    }
    return parsed;
}

fn resolveInboundRouteSessionKeyWithMetadata(
    allocator: std.mem.Allocator,
    config: *const Config,
    msg: *const bus_mod.InboundMessage,
    meta: channel_adapters.InboundMetadata,
) ?[]const u8 {
    const route_desc = channel_adapters.findInboundRouteDescriptor(config, msg.channel);

    const account_id = meta.account_id orelse if (route_desc) |desc|
        desc.default_account_id(config, msg.channel) orelse "default"
    else
        "default";

    const peer = if (meta.peer_kind != null and meta.peer_id != null)
        agent_routing.PeerRef{ .kind = meta.peer_kind.?, .id = meta.peer_id.? }
    else if (route_desc) |desc|
        desc.derive_peer(.{
            .channel_name = msg.channel,
            .sender_id = msg.sender_id,
            .chat_id = msg.chat_id,
        }, meta) orelse return null
    else
        return null;
    const route = agent_routing.resolveRouteWithSession(allocator, .{
        .channel = msg.channel,
        .account_id = account_id,
        .peer = peer,
        .guild_id = meta.guild_id,
        .team_id = meta.team_id,
    }, config.agent_bindings, config.agents, config.session) catch return null;
    allocator.free(route.main_session_key);

    if (meta.thread_id) |thread_id| {
        // S8.2 — channel-routed family is correct here. `route.session_key`
        // is `agent:{agent_id}:{channel}:{kind}:{id}` from resolveRoute();
        // we append `:thread:{id}` so reply-path resolution can decode it.
        // Do NOT swap to `session/root.userThreadSessionKey` — that emits
        // the user-cell family, which loses the channel/account/peer
        // context the Telegram/Discord/etc. listeners use to route back.
        const threaded = agent_routing.buildChannelRoutedThreadSessionKey(allocator, route.session_key, thread_id) catch return route.session_key;
        allocator.free(route.session_key);
        return threaded;
    }
    return route.session_key;
}

fn resolveInboundRouteSessionKey(
    allocator: std.mem.Allocator,
    config: *const Config,
    msg: *const bus_mod.InboundMessage,
) ?[]const u8 {
    var parsed_meta = parseInboundMetadata(allocator, msg.metadata_json);
    defer parsed_meta.deinit();
    return resolveInboundRouteSessionKeyWithMetadata(allocator, config, msg, parsed_meta.fields);
}

const InboundCanonicalResult = struct {
    session_key: ?[]u8 = null,
    strict_reject_reason: ?[]const u8 = null,

    fn deinit(self: *InboundCanonicalResult, allocator: std.mem.Allocator) void {
        if (self.session_key) |value| allocator.free(value);
    }
};

fn resolveInboundAccountId(config: *const Config, msg: *const bus_mod.InboundMessage, meta: channel_adapters.InboundMetadata) []const u8 {
    if (meta.account_id) |account_id| return account_id;
    if (channel_adapters.findInboundRouteDescriptor(config, msg.channel)) |desc| {
        if (desc.default_account_id(config, msg.channel)) |account_id| return account_id;
    }
    return "default";
}

fn resolveInboundCanonicalSessionKey(
    allocator: std.mem.Allocator,
    config: *const Config,
    state_mgr_opt: ?*zaki_state.Manager,
    msg: *const bus_mod.InboundMessage,
    meta: channel_adapters.InboundMetadata,
    fallback_session_key: []const u8,
) !InboundCanonicalResult {
    var result = InboundCanonicalResult{};
    const account_id = resolveInboundAccountId(config, msg, meta);
    var identity_keys_opt: ?channel_identity_key.IdentityKeys = null;
    if (channel_identity_key.build(
        allocator,
        msg.channel,
        msg.sender_id,
        msg.chat_id,
        meta.thread_id,
    )) |identity_keys| {
        identity_keys_opt = identity_keys;
    } else |_| {}
    defer if (identity_keys_opt) |*identity_keys| identity_keys.deinit(allocator);

    var decision = inbound_canonicalizer.canonicalizeInboundTurn(
        allocator,
        state_mgr_opt,
        config,
        .{
            .channel = msg.channel,
            .account_id = account_id,
            .principal_key = if (identity_keys_opt) |identity_keys| identity_keys.principal_key else "",
            .scope_key = if (identity_keys_opt) |identity_keys| identity_keys.scope_key else "",
            .thread_key = if (identity_keys_opt) |identity_keys| identity_keys.thread_key else null,
            .message_id = meta.message_id,
            .fallback_session_key = fallback_session_key,
            .lane = if (meta.thread_id != null) .thread else .main,
        },
    ) catch |err| {
        log.warn("inbound canonicalization failed channel={s}: {}", .{ msg.channel, err });
        return result;
    };
    defer decision.deinit(allocator);

    switch (decision.kind) {
        .strict_reject => {
            result.strict_reject_reason = decision.reason_code;
            return result;
        },
        .canonical, .degraded_compat => {
            if (decision.session_key) |session_key| {
                result.session_key = session_key;
                decision.session_key = null;
            }
            return result;
        },
    }
}

const SlackStatusTarget = struct {
    channel_id: []const u8,
    thread_ts: []const u8,
};

fn resolveSlackStatusTarget(meta: channel_adapters.InboundMetadata, chat_id: []const u8) ?SlackStatusTarget {
    var channel_id = meta.channel_id orelse chat_id;
    if (std.mem.indexOfScalar(u8, channel_id, ':')) |idx| {
        if (idx > 0) channel_id = channel_id[0..idx];
    }
    if (channel_id.len == 0) return null;

    const thread_ts = meta.thread_id orelse meta.message_id orelse return null;
    if (thread_ts.len == 0) return null;

    return .{
        .channel_id = channel_id,
        .thread_ts = thread_ts,
    };
}

fn resolveTypingRecipient(
    allocator: std.mem.Allocator,
    channel_name: []const u8,
    chat_id: []const u8,
    meta: channel_adapters.InboundMetadata,
) ?[]u8 {
    if (std.mem.eql(u8, channel_name, "slack")) {
        const slack_target = resolveSlackStatusTarget(meta, chat_id) orelse return null;
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ slack_target.channel_id, slack_target.thread_ts }) catch null;
    }

    const supports_default_typing_target = std.mem.eql(u8, channel_name, "discord") or
        std.mem.eql(u8, channel_name, "mattermost") or
        std.mem.eql(u8, channel_name, "telegram") or
        std.mem.eql(u8, channel_name, "signal") or
        std.mem.eql(u8, channel_name, "matrix");
    if (!supports_default_typing_target) {
        return null;
    }
    if (chat_id.len == 0) return null;
    return allocator.dupe(u8, chat_id) catch null;
}

fn inboundConversationContext(msg: *const bus_mod.InboundMessage, meta: channel_adapters.InboundMetadata) ?ConversationContext {
    if (!std.mem.eql(u8, msg.channel, "signal")) return null;

    const sender_number = if (meta.sender_number) |value|
        value
    else if (msg.sender_id.len > 0 and msg.sender_id[0] == '+')
        msg.sender_id
    else
        null;

    return .{
        .channel = "signal",
        .sender_number = sender_number,
        .sender_uuid = meta.sender_uuid,
        .group_id = meta.group_id,
        .is_group = meta.is_group,
    };
}

fn sendInboundProcessingIndicator(
    allocator: std.mem.Allocator,
    registry: *const dispatch.ChannelRegistry,
    channel_name: []const u8,
    account_id: ?[]const u8,
    chat_id: []const u8,
    meta: channel_adapters.InboundMetadata,
) ?[]u8 {
    const channel_opt = if (account_id) |aid|
        registry.findByNameAccount(channel_name, aid)
    else
        registry.findByName(channel_name);
    const ch = channel_opt orelse return null;

    const recipient = resolveTypingRecipient(allocator, channel_name, chat_id, meta) orelse return null;
    ch.startTyping(recipient) catch {
        allocator.free(recipient);
        return null;
    };
    return recipient;
}

fn clearInboundProcessingIndicator(
    allocator: std.mem.Allocator,
    registry: *const dispatch.ChannelRegistry,
    channel_name: []const u8,
    account_id: ?[]const u8,
    recipient: ?[]u8,
) void {
    const target = recipient orelse return;
    defer allocator.free(target);
    const channel_opt = if (account_id) |aid|
        registry.findByNameAccount(channel_name, aid)
    else
        registry.findByName(channel_name);
    const ch = channel_opt orelse return;
    ch.stopTyping(target) catch {};
}

fn inboundDispatcherThread(
    allocator: std.mem.Allocator,
    event_bus: *bus_mod.Bus,
    registry: *const dispatch.ChannelRegistry,
    runtime: *channel_loop.ChannelRuntime,
    state: *DaemonState,
) void {
    var inbound_state_mgr: ?zaki_state.Manager = null;
    if (runtime.config.tenant.enabled and std.mem.eql(u8, runtime.config.state.backend, "postgres")) {
        inbound_state_mgr = zaki_state.Manager.init(allocator, runtime.config.state) catch |err| blk: {
            log.warn("inbound dispatcher postgres state init failed: {}", .{err});
            break :blk null;
        };
    }
    defer if (inbound_state_mgr) |*mgr| mgr.deinit();
    const inbound_state_mgr_ptr: ?*zaki_state.Manager = if (inbound_state_mgr) |*mgr| mgr else null;

    var evict_counter: u32 = 0;

    while (event_bus.consumeInbound()) |msg| {
        defer msg.deinit(allocator);

        var parsed_meta = parseInboundMetadata(allocator, msg.metadata_json);
        defer parsed_meta.deinit();

        const outbound_account_id = parsed_meta.fields.account_id;
        const routed_session_key = resolveInboundRouteSessionKeyWithMetadata(
            allocator,
            runtime.config,
            &msg,
            parsed_meta.fields,
        );
        defer if (routed_session_key) |key| allocator.free(key);
        const fallback_session_key = routed_session_key orelse msg.session_key;
        var canonical = resolveInboundCanonicalSessionKey(
            allocator,
            runtime.config,
            inbound_state_mgr_ptr,
            &msg,
            parsed_meta.fields,
            fallback_session_key,
        ) catch |err| {
            log.warn("inbound canonical session resolve failed: {}", .{err});
            .{};
        };
        defer canonical.deinit(allocator);
        if (canonical.strict_reject_reason) |reason_code| {
            const reject_text = "This channel is not mapped to a tenant user yet. Reconnect in app and retry.";
            const reject_out = if (outbound_account_id) |aid|
                bus_mod.makeOutboundWithAccount(allocator, msg.channel, aid, msg.chat_id, reject_text) catch continue
            else
                bus_mod.makeOutbound(allocator, msg.channel, msg.chat_id, reject_text) catch continue;
            event_bus.publishOutbound(reject_out) catch {
                reject_out.deinit(allocator);
            };
            log.warn("inbound strict identity reject channel={s} reason={s}", .{ msg.channel, reason_code });
            continue;
        }
        const session_key = canonical.session_key orelse fallback_session_key;
        const tenant_user_id = zaki_session.parseUserIdFromSessionKey(session_key);
        const numeric_tenant_user_id = if (tenant_user_id) |user_id|
            std.fmt.parseInt(i64, user_id, 10) catch null
        else
            null;
        const expect_postgres_state = runtime.config.tenant.enabled and std.mem.eql(u8, runtime.config.state.backend, "postgres");
        tools_mod.setTenantContext(.{
            .user_id = tenant_user_id,
            .numeric_user_id = numeric_tenant_user_id,
            .session_key = session_key,
            .state_mgr = inbound_state_mgr_ptr,
            .expect_postgres_state = expect_postgres_state and tenant_user_id != null,
        });
        defer tools_mod.clearTenantContext();

        const typing_recipient = sendInboundProcessingIndicator(
            allocator,
            registry,
            msg.channel,
            outbound_account_id,
            msg.chat_id,
            parsed_meta.fields,
        );
        defer clearInboundProcessingIndicator(
            allocator,
            registry,
            msg.channel,
            outbound_account_id,
            typing_recipient,
        );

        const conversation_context = inboundConversationContext(&msg, parsed_meta.fields);
        const reply = runtime.session_mgr.processMessageWithToolContext(session_key, msg.content, conversation_context, .{
            .channel = msg.channel,
            .account_id = outbound_account_id,
            .chat_id = msg.chat_id,
        }) catch |err| {
            log.warn("inbound dispatch process failed: {}", .{err});

            // Send user-visible error reply back to the originating channel
            const err_msg: []const u8 = switch (err) {
                error.CurlFailed, error.CurlReadError, error.CurlWaitError => "Network error. Please try again.",
                error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
                error.NoResponseContent => "Model returned an empty response. Please try again.",
                error.OutOfMemory => "Out of memory.",
                else => "An error occurred. Try again.",
            };
            const err_out = if (outbound_account_id) |aid|
                bus_mod.makeOutboundWithAccount(allocator, msg.channel, aid, msg.chat_id, err_msg) catch continue
            else
                bus_mod.makeOutbound(allocator, msg.channel, msg.chat_id, err_msg) catch continue;
            event_bus.publishOutbound(err_out) catch {
                err_out.deinit(allocator);
            };
            continue;
        };
        defer allocator.free(reply);

        const out = (if (outbound_account_id) |aid|
            bus_mod.makeOutboundWithAccount(allocator, msg.channel, aid, msg.chat_id, reply)
        else
            bus_mod.makeOutbound(allocator, msg.channel, msg.chat_id, reply)) catch |err| {
            log.err("inbound dispatch makeOutbound failed: {}", .{err});
            continue;
        };

        event_bus.publishOutbound(out) catch |err| {
            out.deinit(allocator);
            if (err == error.Closed) break;
            log.err("inbound dispatch publishOutbound failed: {}", .{err});
            continue;
        };

        state.markRunning("inbound_dispatcher");
        health.markComponentOk("inbound_dispatcher");

        // Periodic session eviction for bus-based channels
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(runtime.config.agent.session_idle_timeout_secs);
        }
    }
}

/// Run the long-lived runtime. This is the main entry point for `nullalis gateway`.
/// Spawns threads for gateway, heartbeat, and channels, then loops until
/// shutdown is requested (Ctrl+C signal or explicit request).
/// `host` and `port` are CLI-parsed values that override `config.gateway`.
pub fn run(allocator: std.mem.Allocator, config: *const Config, host: []const u8, port: u16) !void {
    ignoreSigpipe();

    // V8 (v1.14.13 Step 0): if the operator launched with
    // NULLALIS_ALLOW_UNSANDBOXED_DEV=1 they consented to a development-only
    // bypass of the tool sandbox when no real backend is installed.
    // Surface that loudly at boot so it never hides in stdout noise.
    tool_sandbox_v1.logUnsandboxedDevBannerIfEnabled();

    // Ensure lifecycle parity: workspace bootstrap files must exist
    // even when users skip onboard and start runtime directly.
    const project_ctx = onboard.projectContextForConfig(config);
    try onboard.scaffoldWorkspace(allocator, config.workspace_dir, &project_ctx);

    health.markComponentOk("daemon");
    shutdown_requested.store(false, .release);
    const has_supervised_channels = hasSupervisedChannels(config);
    const has_runtime_dependent_channels = channel_catalog.hasRuntimeDependentChannels(config);

    var state = DaemonState{
        .started = true,
        .gateway_host = host,
        .gateway_port = port,
    };
    state.addComponent("gateway");

    if (has_supervised_channels) {
        state.addComponent("channels");
    } else {
        health.markComponentOk("channels");
    }

    if (config.heartbeat.enabled) {
        state.addComponent("heartbeat");
    } else if (config.tenant.enabled) {
        const enabled_user_heartbeat_configs = countEnabledUserHeartbeatConfigsByFile(allocator, config.tenant.data_root);
        if (enabled_user_heartbeat_configs > 0) {
            log.warn(
                "heartbeat disabled globally (agents.defaults.heartbeat.enabled=false); detected {d} user heartbeat configs enabled; no heartbeat polling will run until global heartbeat is enabled",
                .{enabled_user_heartbeat_configs},
            );
        }
    }

    state.addComponent("scheduler");
    state.addComponent("delivery_outcome");

    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &bw.interface;
    try stdout.print("nullalis gateway runtime started\n", .{});
    try stdout.print("  Gateway:  http://{s}:{d}\n", .{ state.gateway_host, state.gateway_port });
    try stdout.print("  Components: {d} active\n", .{state.component_count});
    try stdout.flush();
    config.printModelConfig();
    try stdout.print("  Ctrl+C to stop\n\n", .{});
    try stdout.flush();

    // Write initial state file
    const state_path = try stateFilePath(allocator, config);
    defer allocator.free(state_path);
    writeStateFile(allocator, state_path, &state) catch |err| {
        try stdout.print("Warning: could not write state file: {}\n", .{err});
    };

    // Proactive guardrails are operator-configurable via tenant.* with
    // bounded clamps enforced inside ops_guard.
    ops_guard.configureProactivePolicy(
        config.tenant.proactive_dedupe_window_secs,
        config.tenant.proactive_rate_window_secs,
        config.tenant.proactive_rate_limit_per_window,
    );

    // Event bus (created before gateway+scheduler so all threads can publish)
    var event_bus = bus_mod.Bus.init();
    var delivery_state_mgr: ?*zaki_state.Manager = null;
    defer if (delivery_state_mgr) |mgr| {
        mgr.deinit();
        allocator.destroy(mgr);
    };
    if (config.tenant.enabled and std.mem.eql(u8, config.state.backend, "postgres")) {
        const mgr = allocator.create(zaki_state.Manager) catch null;
        if (mgr) |state_mgr| {
            if (zaki_state.Manager.init(allocator, config.state)) |initialized| {
                state_mgr.* = initialized;
                delivery_state_mgr = state_mgr;
            } else |_| {
                allocator.destroy(state_mgr);
            }
        }
    }

    var delivery_outcome_thread: ?std.Thread = null;
    state.markRunning("delivery_outcome");
    if (std.Thread.spawn(.{ .stack_size = 256 * 1024 }, deliveryOutcomeThread, .{ allocator, config, &state, &event_bus, delivery_state_mgr })) |thread| {
        delivery_outcome_thread = thread;
    } else |err| {
        state.markError("delivery_outcome", @errorName(err));
        event_bus.closeDeliveryOutcomes();
        stdout.print("Warning: delivery outcome thread failed: {}\n", .{err}) catch {};
    }

    // Spawn gateway thread
    state.markRunning("gateway");
    const gw_thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, gatewayThread, .{ allocator, config, host, port, &state, &event_bus }) catch |err| {
        state.markError("gateway", @errorName(err));
        try stdout.print("Failed to spawn gateway: {}\n", .{err});
        return err;
    };

    // Spawn heartbeat thread
    var hb_thread: ?std.Thread = null;
    if (config.heartbeat.enabled) {
        state.markRunning("heartbeat");
        if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, heartbeatThread, .{ allocator, config, &state, &event_bus })) |thread| {
            hb_thread = thread;
        } else |err| {
            state.markError("heartbeat", @errorName(err));
            stdout.print("Warning: heartbeat thread failed: {}\n", .{err}) catch {};
        }
    }

    // Spawn scheduler thread
    //
    // STACK SIZE: 2 MB. This thread runs the FULL agent turn synchronously via
    // `runCronAgentTurnWithBus → SessionManager.processMessageWithContext →
    // Agent.turnOutcome`, which then descends into provider calls, memory
    // writes, and (critically) SQLite expression-code generation when the
    // semantic_cache evicts. SQLite's recursive parser + codegen for the
    // evictLru `LIMIT MAX(0, (SELECT COUNT(*) ...) - ?1)` form alone adds
    // ~15 nested frames on top of an already-deep Zig call chain.
    //
    // History: this thread was originally 256 KB (sized for dispatch-only
    // work). After we wired in-thread agent turn execution in v1.13, the
    // 256 KB budget became unsafe. The symptom: SIGILL on byte-write
    // translation fault (macOS reports stack-guard hits as SIGILL on arm64)
    // deterministically inside `sqlite3ExprCodeTarget → memset`, observed
    // ~2 min after gateway boot once cron first fires a cached agent turn.
    // Four IPS crash dumps on 2026-05-28 all matched this exact site.
    //
    // Sizing: 2 MB matches the realistic peak (Agent.turnOutcome locals +
    // provider call buffers + memory writes + SQLite codegen) with ~8× the
    // historic budget and ~4× the comparable 512 KB threads. Cost is
    // 1.75 MB extra RAM, single-process.
    var sched_thread: ?std.Thread = null;
    if (config.scheduler.enabled) {
        state.markRunning("scheduler");
        if (std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, schedulerThread, .{ allocator, config, &state, &event_bus })) |thread| {
            sched_thread = thread;
        } else |err| {
            state.markError("scheduler", @errorName(err));
            stdout.print("Warning: scheduler thread failed: {}\n", .{err}) catch {};
        }
    }

    // Outbound dispatcher (created before supervisor so channels can register)
    var channel_registry = dispatch.ChannelRegistry.init(allocator);
    defer channel_registry.deinit();

    // Channel runtime for supervised polling (provider, tools, sessions)
    var channel_rt: ?*channel_loop.ChannelRuntime = null;
    if (has_runtime_dependent_channels) {
        channel_rt = channel_loop.ChannelRuntime.init(allocator, config, &event_bus) catch |err| blk: {
            state.markError("channels", @errorName(err));
            health.markComponentError("channels", "runtime init failed");
            stdout.print(
                "Warning: channel runtime init failed ({s}); runtime-dependent channels disabled.\n",
                .{@errorName(err)},
            ) catch {};
            break :blk null;
        };
    }
    defer if (channel_rt) |rt| rt.deinit();

    // Spawn channel supervisor thread (only if channels are configured)
    var chan_thread: ?std.Thread = null;
    if (has_supervised_channels) {
        if (std.Thread.spawn(.{ .stack_size = 256 * 1024 }, channelSupervisorThread, .{
            allocator, config, &state, &channel_registry, channel_rt, &event_bus,
        })) |thread| {
            chan_thread = thread;
        } else |err| {
            state.markError("channels", @errorName(err));
            stdout.print("Warning: channel supervisor thread failed: {}\n", .{err}) catch {};
        }
    }

    var inbound_threads: std.ArrayListUnmanaged(std.Thread) = .empty;
    defer inbound_threads.deinit(allocator);
    if (channel_rt) |rt| {
        state.addComponent("inbound_dispatcher");
        const requested_inbound_workers: u32 = if (config.gateway.inbound_workers == 0) 1 else config.gateway.inbound_workers;
        const bounded_inbound_workers: u32 = @min(requested_inbound_workers, MAX_DISPATCHER_WORKERS);
        if (requested_inbound_workers > MAX_DISPATCHER_WORKERS) {
            log.warn("gateway.inbound_workers={d} exceeds cap={d}; using {d}", .{
                requested_inbound_workers,
                MAX_DISPATCHER_WORKERS,
                bounded_inbound_workers,
            });
        }

        var worker_idx: u32 = 0;
        while (worker_idx < bounded_inbound_workers) : (worker_idx += 1) {
            if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, inboundDispatcherThread, .{
                allocator, &event_bus, &channel_registry, rt, &state,
            })) |thread| {
                inbound_threads.append(allocator, thread) catch {
                    thread.join();
                };
            } else |err| {
                log.warn("inbound dispatcher worker spawn failed index={d}: {}", .{ worker_idx, err });
            }
        }
        if (inbound_threads.items.len > 0) {
            state.markRunning("inbound_dispatcher");
            health.markComponentOk("inbound_dispatcher");
        } else {
            state.markError("inbound_dispatcher", "spawn_failed");
            stdout.print("Warning: inbound dispatcher workers failed to start.\n", .{}) catch {};
        }
    }

    var dispatch_stats = dispatch.DispatchStats{};
    var tenant_dispatch_ctx = dispatch.TenantDispatchContext{
        .enabled = config.tenant.enabled,
        .data_root = config.tenant.data_root,
        .allow_telegram_fallback = config.tenant.enabled,
    };

    state.addComponent("outbound_dispatcher");

    var outbound_threads: std.ArrayListUnmanaged(std.Thread) = .empty;
    defer outbound_threads.deinit(allocator);
    const requested_outbound_workers: u32 = if (config.gateway.outbound_workers == 0) 1 else config.gateway.outbound_workers;
    const bounded_outbound_workers: u32 = @min(requested_outbound_workers, MAX_DISPATCHER_WORKERS);
    if (requested_outbound_workers > MAX_DISPATCHER_WORKERS) {
        log.warn("gateway.outbound_workers={d} exceeds cap={d}; using {d}", .{
            requested_outbound_workers,
            MAX_DISPATCHER_WORKERS,
            bounded_outbound_workers,
        });
    }
    var outbound_idx: u32 = 0;
    while (outbound_idx < bounded_outbound_workers) : (outbound_idx += 1) {
        if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, dispatch.runOutboundDispatcherWithTenantContext, .{
            allocator, &event_bus, &channel_registry, &dispatch_stats, &tenant_dispatch_ctx,
        })) |thread| {
            outbound_threads.append(allocator, thread) catch {
                thread.join();
            };
        } else |err| {
            log.warn("outbound dispatcher worker spawn failed index={d}: {}", .{ outbound_idx, err });
        }
    }
    if (outbound_threads.items.len > 0) {
        state.markRunning("outbound_dispatcher");
        health.markComponentOk("outbound_dispatcher");
    } else {
        state.markError("outbound_dispatcher", "spawn_failed");
        stdout.print("Warning: outbound dispatcher workers failed to start.\n", .{}) catch {};
    }

    // Main thread: wait for shutdown signal (poll-based)
    while (!isShutdownRequested()) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }

    try stdout.print("\nShutting down...\n", .{});

    // Ask gateway to enter drain mode and stop accepting requests, then exit.
    const internal_token = if (config.gateway.internal_service_tokens.len > 0)
        config.gateway.internal_service_tokens[0]
    else
        null;
    sendGatewayControlCommand(host, port, "/internal/shutdown", internal_token);

    // Close bus to signal dispatcher to exit
    event_bus.close();

    // Write final state
    state.markError("gateway", "shutting down");
    writeStateFile(allocator, state_path, &state) catch {};

    // Wait for threads
    for (inbound_threads.items) |t| t.join();
    for (outbound_threads.items) |t| t.join();
    if (delivery_outcome_thread) |t| t.join();
    if (chan_thread) |t| t.join();
    if (sched_thread) |t| t.join();
    if (hb_thread) |t| t.join();
    gw_thread.join();

    try stdout.print("nullalis gateway runtime stopped.\n", .{});
}

// ── Tests ────────────────────────────────────────────────────────

test "DaemonState addComponent" {
    var state = DaemonState{};
    state.addComponent("gateway");
    state.addComponent("channels");
    try std.testing.expectEqual(@as(usize, 2), state.component_count);
    try std.testing.expectEqualStrings("gateway", state.components[0].?.name);
    try std.testing.expectEqualStrings("channels", state.components[1].?.name);
}

test "DaemonState markError and markRunning" {
    var state = DaemonState{};
    state.addComponent("gateway");
    state.markError("gateway", "connection refused");
    try std.testing.expect(!state.components[0].?.running);
    try std.testing.expectEqual(@as(u64, 1), state.components[0].?.restart_count);
    try std.testing.expectEqualStrings("connection refused", state.components[0].?.last_error.?);

    state.markRunning("gateway");
    try std.testing.expect(state.components[0].?.running);
    try std.testing.expect(state.components[0].?.last_error == null);
}

test "computeBackoff doubles up to max" {
    try std.testing.expectEqual(@as(u64, 4), computeBackoff(2, 60));
    try std.testing.expectEqual(@as(u64, 60), computeBackoff(32, 60));
    try std.testing.expectEqual(@as(u64, 60), computeBackoff(60, 60));
}

test "computeBackoff saturating" {
    try std.testing.expectEqual(std.math.maxInt(u64), computeBackoff(std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "hasSupervisedChannels false for defaults" {
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(!hasSupervisedChannels(&config));
}

test "resolveInboundRouteSessionKey falls back to configured account_id" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "onebot-agent",
            .match = .{
                .channel = "onebot",
                .account_id = "onebot-main",
                .peer = .{ .kind = .direct, .id = "12345" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .onebot = &[_]@import("config_types.zig").OneBotConfig{.{
                .account_id = "onebot-main",
            }},
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "onebot",
        .sender_id = "12345",
        .chat_id = "12345",
        .content = "hello",
        .session_key = "onebot:12345",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:onebot-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey routes onebot group messages by group id" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "onebot-group-agent",
            .match = .{
                .channel = "onebot",
                .account_id = "onebot-main",
                .peer = .{ .kind = .group, .id = "777" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .onebot = &[_]@import("config_types.zig").OneBotConfig{.{
                .account_id = "onebot-main",
            }},
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "onebot",
        .sender_id = "12345",
        .chat_id = "group:777",
        .content = "hello group",
        .session_key = "onebot:group:777",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:onebot-group-agent:onebot:group:777", routed.?);
}

test "resolveInboundRouteSessionKey prefers metadata account_id override" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "onebot-main-agent",
            .match = .{
                .channel = "onebot",
                .account_id = "main",
                .peer = .{ .kind = .direct, .id = "12345" },
            },
        },
        .{
            .agent_id = "onebot-backup-agent",
            .match = .{
                .channel = "onebot",
                .account_id = "backup",
                .peer = .{ .kind = .direct, .id = "12345" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .onebot = &[_]@import("config_types.zig").OneBotConfig{
                .{ .account_id = "main" },
                .{ .account_id = "backup" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "onebot",
        .sender_id = "12345",
        .chat_id = "12345",
        .content = "hello",
        .session_key = "onebot:12345",
        .metadata_json = "{\"account_id\":\"backup\"}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:onebot-backup-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey supports custom maixcam channel name" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "camera-agent",
            .match = .{
                .channel = "vision-cam",
                .account_id = "cam-main",
                .peer = .{ .kind = .direct, .id = "device-1" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .maixcam = &[_]@import("config_types.zig").MaixCamConfig{.{
                .name = "vision-cam",
                .account_id = "cam-main",
            }},
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "vision-cam",
        .sender_id = "device-1",
        .chat_id = "device-1",
        .content = "person detected",
        .session_key = "vision-cam:device-1",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:camera-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey matches non-primary maixcam account by channel name" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "lab-camera-agent",
            .match = .{
                .channel = "vision-lab",
                .account_id = "cam-lab",
                .peer = .{ .kind = .direct, .id = "device-2" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .maixcam = &[_]@import("config_types.zig").MaixCamConfig{
                .{ .name = "vision-main", .account_id = "cam-main" },
                .{ .name = "vision-lab", .account_id = "cam-lab" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "vision-lab",
        .sender_id = "device-2",
        .chat_id = "device-2",
        .content = "movement",
        .session_key = "vision-lab:device-2",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:lab-camera-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey routes discord channel messages by chat_id" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "discord-channel-agent",
            .match = .{
                .channel = "discord",
                .account_id = "discord-main",
                .peer = .{ .kind = .channel, .id = "778899" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .discord = &[_]@import("config_types.zig").DiscordConfig{
                .{ .account_id = "discord-main", .token = "token" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "discord",
        .sender_id = "user-1",
        .chat_id = "778899",
        .content = "hello",
        .session_key = "discord:778899",
        .metadata_json = "{\"guild_id\":\"guild-1\"}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:discord-channel-agent:discord:channel:778899", routed.?);
}

test "resolveInboundRouteSessionKey routes discord direct messages by sender" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "discord-dm-agent",
            .match = .{
                .channel = "discord",
                .account_id = "discord-main",
                .peer = .{ .kind = .direct, .id = "user-42" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .discord = &[_]@import("config_types.zig").DiscordConfig{
                .{ .account_id = "discord-main", .token = "token" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "discord",
        .sender_id = "user-42",
        .chat_id = "some-channel",
        .content = "ping",
        .session_key = "discord:dm:user-42",
        .metadata_json = "{\"is_dm\":true}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:discord-dm-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey applies session dm_scope for direct messages" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "discord-dm-agent",
            .match = .{
                .channel = "discord",
                .account_id = "discord-main",
                .peer = .{ .kind = .direct, .id = "user-42" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .discord = &[_]@import("config_types.zig").DiscordConfig{
                .{ .account_id = "discord-main", .token = "token" },
            },
        },
        .session = .{
            .dm_scope = .per_peer,
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "discord",
        .sender_id = "user-42",
        .chat_id = "some-channel",
        .content = "ping",
        .session_key = "discord:dm:user-42",
        .metadata_json = "{\"is_dm\":true}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:discord-dm-agent:direct:user-42", routed.?);
}

test "resolveInboundRouteSessionKey normalizes qq channel prefix for routed peer id" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "qq-channel-agent",
            .match = .{
                .channel = "qq",
                .account_id = "qq-main",
                .peer = .{ .kind = .channel, .id = "998877" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .qq = &[_]@import("config_types.zig").QQConfig{
                .{ .account_id = "qq-main" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "qq",
        .sender_id = "qq-user",
        .chat_id = "channel:998877",
        .content = "hello",
        .session_key = "qq:channel:998877",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:qq-channel-agent:qq:channel:998877", routed.?);
}

test "resolveInboundRouteSessionKey routes slack channel messages by chat_id" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "slack-channel-agent",
            .match = .{
                .channel = "slack",
                .account_id = "sl-main",
                .peer = .{ .kind = .channel, .id = "C12345" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .slack = &[_]@import("config_types.zig").SlackConfig{
                .{ .account_id = "sl-main", .bot_token = "xoxb-token", .channel_id = "C12345" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "slack",
        .sender_id = "U777",
        .chat_id = "C12345",
        .content = "hello",
        .session_key = "slack:sl-main:channel:C12345",
        .metadata_json = "{\"account_id\":\"sl-main\",\"is_dm\":false}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:slack-channel-agent:slack:channel:C12345", routed.?);
}

test "resolveInboundRouteSessionKey routes slack direct messages by sender" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "slack-dm-agent",
            .match = .{
                .channel = "slack",
                .account_id = "sl-main",
                .peer = .{ .kind = .direct, .id = "U777" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .slack = &[_]@import("config_types.zig").SlackConfig{
                .{ .account_id = "sl-main", .bot_token = "xoxb-token", .channel_id = "D22222" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "slack",
        .sender_id = "U777",
        .chat_id = "D22222",
        .content = "hi dm",
        .session_key = "slack:sl-main:direct:U777",
        .metadata_json = "{\"account_id\":\"sl-main\",\"is_dm\":true}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:slack-dm-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey routes qq dm messages by sender id" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "qq-dm-agent",
            .match = .{
                .channel = "qq",
                .account_id = "qq-main",
                .peer = .{ .kind = .direct, .id = "qq-user-1" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .qq = &[_]@import("config_types.zig").QQConfig{
                .{ .account_id = "qq-main" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "qq",
        .sender_id = "qq-user-1",
        .chat_id = "dm:session-abc",
        .content = "hello",
        .session_key = "qq:dm:session-abc",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:qq-dm-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey routes irc channel messages by chat id" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "irc-group-agent",
            .match = .{
                .channel = "irc",
                .account_id = "irc-main",
                .peer = .{ .kind = .group, .id = "#dev" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .irc = &[_]@import("config_types.zig").IrcConfig{
                .{ .account_id = "irc-main", .host = "irc.example.org", .nick = "bot" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "irc",
        .sender_id = "alice",
        .chat_id = "#dev",
        .content = "hello",
        .session_key = "irc:irc-main:group:#dev",
        .metadata_json = "{\"account_id\":\"irc-main\",\"is_group\":true}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:irc-group-agent:irc:group:#dev", routed.?);
}

test "resolveInboundRouteSessionKey routes irc direct messages by sender" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "irc-dm-agent",
            .match = .{
                .channel = "irc",
                .account_id = "irc-main",
                .peer = .{ .kind = .direct, .id = "alice" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .irc = &[_]@import("config_types.zig").IrcConfig{
                .{ .account_id = "irc-main", .host = "irc.example.org", .nick = "bot" },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "irc",
        .sender_id = "alice",
        .chat_id = "alice",
        .content = "hello dm",
        .session_key = "irc:irc-main:direct:alice",
        .metadata_json = "{\"account_id\":\"irc-main\",\"is_dm\":true}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:irc-dm-agent:main", routed.?);
}

test "resolveInboundRouteSessionKey routes mattermost by channel id and team" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "mm-group-agent",
            .match = .{
                .channel = "mattermost",
                .account_id = "mm-main",
                .team_id = "team-1",
                .peer = .{ .kind = .group, .id = "chan-g1" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .mattermost = &[_]@import("config_types.zig").MattermostConfig{
                .{
                    .account_id = "mm-main",
                    .bot_token = "token",
                    .base_url = "https://chat.example.com",
                },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "mattermost",
        .sender_id = "user-42",
        .chat_id = "channel:chan-g1",
        .content = "hello",
        .session_key = "mattermost:mm-main:group:chan-g1",
        .metadata_json = "{\"account_id\":\"mm-main\",\"is_group\":true,\"channel_id\":\"chan-g1\",\"team_id\":\"team-1\"}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:mm-group-agent:mattermost:group:chan-g1", routed.?);
}

test "resolveInboundRouteSessionKey appends mattermost thread suffix" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "mm-thread-agent",
            .match = .{
                .channel = "mattermost",
                .account_id = "mm-main",
                .peer = .{ .kind = .channel, .id = "chan-c1" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
        .channels = .{
            .mattermost = &[_]@import("config_types.zig").MattermostConfig{
                .{
                    .account_id = "mm-main",
                    .bot_token = "token",
                    .base_url = "https://chat.example.com",
                },
            },
        },
    };
    const msg = bus_mod.InboundMessage{
        .channel = "mattermost",
        .sender_id = "user-11",
        .chat_id = "channel:chan-c1:thread:root-99",
        .content = "threaded",
        .session_key = "mattermost:mm-main:channel:chan-c1:thread:root-99",
        .metadata_json = "{\"account_id\":\"mm-main\",\"channel_id\":\"chan-c1\",\"thread_id\":\"root-99\"}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:mm-thread-agent:mattermost:channel:chan-c1:thread:root-99", routed.?);
}

test "resolveInboundRouteSessionKey supports standardized peer metadata for unknown channel" {
    const allocator = std.testing.allocator;
    const bindings = [_]agent_routing.AgentBinding{
        .{
            .agent_id = "custom-agent",
            .match = .{
                .channel = "custom",
                .account_id = "custom-main",
                .peer = .{ .kind = .direct, .id = "user-7" },
            },
        },
    };
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &bindings,
    };
    const msg = bus_mod.InboundMessage{
        .channel = "custom",
        .sender_id = "ignored-sender",
        .chat_id = "ignored-chat",
        .content = "hello",
        .session_key = "custom:legacy",
        .metadata_json = "{\"account_id\":\"custom-main\",\"peer_kind\":\"direct\",\"peer_id\":\"user-7\"}",
    };

    const routed = resolveInboundRouteSessionKey(allocator, &config, &msg);
    try std.testing.expect(routed != null);
    defer allocator.free(routed.?);
    try std.testing.expectEqualStrings("agent:custom-agent:main", routed.?);
}

test "parseInboundMetadata extracts message_id and thread_id" {
    var parsed = parseInboundMetadata(
        std.testing.allocator,
        "{\"account_id\":\"sl-main\",\"channel_id\":\"C1\",\"message_id\":\"1700.1\",\"thread_id\":\"1700.0\"}",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sl-main", parsed.fields.account_id.?);
    try std.testing.expectEqualStrings("C1", parsed.fields.channel_id.?);
    try std.testing.expectEqualStrings("1700.1", parsed.fields.message_id.?);
    try std.testing.expectEqualStrings("1700.0", parsed.fields.thread_id.?);
}

test "parseInboundMetadata extracts signal context fields" {
    var parsed = parseInboundMetadata(
        std.testing.allocator,
        "{\"account_id\":\"sig-main\",\"sender_number\":\"+491234\",\"sender_uuid\":\"uuid-1\",\"group_id\":\"group-1\",\"is_group\":true}",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sig-main", parsed.fields.account_id.?);
    try std.testing.expectEqualStrings("+491234", parsed.fields.sender_number.?);
    try std.testing.expectEqualStrings("uuid-1", parsed.fields.sender_uuid.?);
    try std.testing.expectEqualStrings("group-1", parsed.fields.group_id.?);
    try std.testing.expect(parsed.fields.is_group.?);
}

test "inboundConversationContext builds signal context" {
    const msg = bus_mod.InboundMessage{
        .channel = "signal",
        .sender_id = "+491111",
        .chat_id = "+491111",
        .content = "ping",
        .session_key = "signal:test",
    };
    const meta = channel_adapters.InboundMetadata{
        .sender_uuid = "uuid-2",
        .group_id = "group-2",
        .is_group = true,
    };
    const cc = inboundConversationContext(&msg, meta);
    try std.testing.expect(cc != null);
    try std.testing.expectEqualStrings("signal", cc.?.channel.?);
    try std.testing.expectEqualStrings("+491111", cc.?.sender_number.?);
    try std.testing.expectEqualStrings("uuid-2", cc.?.sender_uuid.?);
    try std.testing.expectEqualStrings("group-2", cc.?.group_id.?);
    try std.testing.expect(cc.?.is_group.?);
}

test "resolveSlackStatusTarget prefers thread_id then falls back to message_id" {
    const with_thread = resolveSlackStatusTarget(.{
        .channel_id = "C123",
        .message_id = "1700.1",
        .thread_id = "1700.0",
    }, "C123");
    try std.testing.expect(with_thread != null);
    try std.testing.expectEqualStrings("C123", with_thread.?.channel_id);
    try std.testing.expectEqualStrings("1700.0", with_thread.?.thread_ts);

    const with_message_only = resolveSlackStatusTarget(.{
        .channel_id = "C123",
        .message_id = "1700.1",
    }, "C123");
    try std.testing.expect(with_message_only != null);
    try std.testing.expectEqualStrings("1700.1", with_message_only.?.thread_ts);
}

test "stateFilePath derives from config_path" {
    const config = Config{
        .workspace_dir = "/tmp/workspace",
        .config_path = "/home/user/.nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    const path = try stateFilePath(std.testing.allocator, &config);
    defer std.testing.allocator.free(path);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "/home/user/.nullalis", "daemon_state.json" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "scheduler backoff constants" {
    try std.testing.expectEqual(@as(u64, 1), SCHEDULER_INITIAL_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 60), SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 60), CHANNEL_WATCH_INTERVAL_SECS);
}

test "scheduler backoff progression" {
    var backoff: u64 = SCHEDULER_INITIAL_BACKOFF_SECS;
    backoff = computeBackoff(backoff, SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 2), backoff);
    backoff = computeBackoff(backoff, SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 4), backoff);
    backoff = computeBackoff(backoff, SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 8), backoff);
    backoff = computeBackoff(backoff, SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 16), backoff);
    backoff = computeBackoff(backoff, SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 32), backoff);
    backoff = computeBackoff(backoff, SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 60), backoff); // capped at max
    backoff = computeBackoff(backoff, SCHEDULER_MAX_BACKOFF_SECS);
    try std.testing.expectEqual(@as(u64, 60), backoff); // stays at max
}

test "mergeSchedulerTickChangesAndSave preserves externally added jobs" {
    const allocator = std.testing.allocator;
    const cmd_runtime = "echo merge_runtime_keep_7d1c";
    const cmd_external = "echo merge_external_add_9a42";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    const cron_path = try std.fmt.allocPrint(allocator, "{s}/cron.json", .{tmp_root});
    defer allocator.free(cron_path);

    var runtime = CronScheduler.init(allocator, 32, true);
    defer runtime.deinit();
    try runtime.setStorePath(cron_path);
    _ = try runtime.addJob("* * * * *", cmd_runtime);
    runtime.jobs.items[runtime.jobs.items.len - 1].next_run_secs = 0;
    try cron.saveJobs(&runtime);

    var loaded = CronScheduler.init(allocator, 32, true);
    defer loaded.deinit();
    try loaded.setStorePath(cron_path);
    try cron.loadJobs(&loaded);

    var before_tick: std.StringHashMapUnmanaged(SchedulerJobSnapshot) = .empty;
    defer {
        clearSchedulerSnapshot(allocator, &before_tick);
        before_tick.deinit(allocator);
    }
    try buildSchedulerSnapshot(allocator, &loaded, &before_tick);

    // Simulate concurrent writer adding a new job after scheduler reload.
    var external = CronScheduler.init(allocator, 32, true);
    defer external.deinit();
    try external.setStorePath(cron_path);
    try cron.loadJobs(&external);
    _ = try external.addJob("*/5 * * * *", cmd_external);
    try cron.saveJobs(&external);

    _ = loaded.tick(std.time.timestamp(), null);
    try mergeSchedulerTickChangesAndSave(allocator, &loaded, &before_tick);

    var merged = CronScheduler.init(allocator, 64, true);
    defer merged.deinit();
    try merged.setStorePath(cron_path);
    try cron.loadJobs(&merged);

    var found_runtime = false;
    var found_external = false;
    for (merged.listJobs()) |job| {
        if (std.mem.eql(u8, job.command, cmd_runtime)) found_runtime = true;
        if (std.mem.eql(u8, job.command, cmd_external)) found_external = true;
    }
    try std.testing.expect(found_runtime);
    try std.testing.expect(found_external);
}

test "parseHeartbeatEveryToMinutes parses common units" {
    try std.testing.expectEqual(@as(?u32, 30), parseHeartbeatEveryToMinutes("30m"));
    try std.testing.expectEqual(@as(?u32, 120), parseHeartbeatEveryToMinutes("2h"));
    try std.testing.expectEqual(@as(?u32, 1), parseHeartbeatEveryToMinutes("45s"));
    try std.testing.expectEqual(@as(?u32, null), parseHeartbeatEveryToMinutes("invalid"));
}

test "countEnabledUserHeartbeatConfigsByFile counts enabled per-user heartbeat files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("1");
    try tmp.dir.makePath("2");
    try tmp.dir.makePath("3");

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const user1_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/1/heartbeat.json", .{root});
    defer std.testing.allocator.free(user1_path);
    const user1_file = try std.fs.createFileAbsolute(user1_path, .{});
    defer user1_file.close();
    try user1_file.writeAll("{\"enabled\":true,\"every\":\"30m\"}\n");

    const user2_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/2/heartbeat.json", .{root});
    defer std.testing.allocator.free(user2_path);
    const user2_file = try std.fs.createFileAbsolute(user2_path, .{});
    defer user2_file.close();
    try user2_file.writeAll("{\"enabled\":false,\"every\":\"30m\"}\n");

    const user3_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/3/heartbeat.json", .{root});
    defer std.testing.allocator.free(user3_path);
    const user3_file = try std.fs.createFileAbsolute(user3_path, .{});
    defer user3_file.close();
    try user3_file.writeAll("{}\n");

    const enabled_count = countEnabledUserHeartbeatConfigsByFile(std.testing.allocator, root);
    try std.testing.expectEqual(@as(usize, 1), enabled_count);
}

test "loadUserHeartbeatConfig state json overrides file config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const hb_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{root});
    defer std.testing.allocator.free(hb_path);

    const file = try std.fs.createFileAbsolute(hb_path, .{});
    defer file.close();
    try file.writeAll("{\"enabled\":false,\"interval_minutes\":5,\"prompt\":\"file prompt\"}\n");

    var cfg = loadUserHeartbeatConfig(
        std.testing.allocator,
        root,
        false,
        30,
        "{\"enabled\":true,\"interval_minutes\":45,\"prompt\":\"state prompt\"}",
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqual(@as(u32, 45), cfg.interval_minutes);
    try std.testing.expectEqualStrings("state prompt", cfg.prompt);
}

test "loadUserHeartbeatConfig falls back to file when state json is empty object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const hb_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{root});
    defer std.testing.allocator.free(hb_path);

    const file = try std.fs.createFileAbsolute(hb_path, .{});
    defer file.close();
    try file.writeAll("{\"enabled\":true,\"interval_minutes\":7,\"prompt\":\"file prompt\"}\n");

    var cfg = loadUserHeartbeatConfig(
        std.testing.allocator,
        root,
        false,
        30,
        "{}",
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqual(@as(u32, 7), cfg.interval_minutes);
    try std.testing.expectEqualStrings("file prompt", cfg.prompt);
}

test "loadUserHeartbeatConfig supports intervalSec compatibility key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const hb_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{root});
    defer std.testing.allocator.free(hb_path);

    const file = try std.fs.createFileAbsolute(hb_path, .{});
    defer file.close();
    try file.writeAll("{\"enabled\":true,\"intervalSec\":300,\"prompt\":\"legacy seconds key\"}\n");

    var cfg = loadUserHeartbeatConfig(
        std.testing.allocator,
        root,
        false,
        30,
        "{}",
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqual(@as(u32, 5), cfg.interval_minutes);
    try std.testing.expectEqualStrings("legacy seconds key", cfg.prompt);
}

test "runTenantHeartbeatForUser requires explicit tenant heartbeat enablement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const user_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{root});
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    const workspace = try std.fmt.allocPrint(std.testing.allocator, "{s}/workspace", .{user_root});
    defer std.testing.allocator.free(workspace);
    try std.fs.makeDirAbsolute(workspace);

    var cfg = Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.heartbeat.enabled = true;
    cfg.heartbeat.interval_minutes = 30;
    cfg.tenant.enabled = true;
    cfg.tenant.data_root = root;

    var event_bus = bus_mod.Bus.init();

    runTenantHeartbeatForUser(
        std.testing.allocator,
        &cfg,
        &event_bus,
        "1",
        1,
        user_root,
        workspace,
        false,
        "heartbeat.interval_due",
        null,
    );

    const runtime_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat_runtime.json", .{user_root});
    defer std.testing.allocator.free(runtime_path);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(runtime_path, .{}));
}

test "isHeartbeatContentEffectivelyEmpty handles comments and placeholders" {
    try std.testing.expect(isHeartbeatContentEffectivelyEmpty("# header\n\n<!-- note -->\n- [ ]\n"));
    try std.testing.expect(!isHeartbeatContentEffectivelyEmpty("# header\n- Send morning brief\n"));
}

test "isHeartbeatAck recognizes ack-only variants" {
    try std.testing.expect(isHeartbeatAck("HEARTBEAT_OK"));
    try std.testing.expect(isHeartbeatAck("<b>HEARTBEAT_OK</b> 🦞"));
    try std.testing.expect(!isHeartbeatAck("HEARTBEAT_OK send a detailed report"));
    try std.testing.expect(!isHeartbeatAck("Morning brief delivered"));
}

test "runCronAgentTurn defers main session next_heartbeat jobs" {
    heartbeat_wake.clearForTest();

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };

    var scheduler = CronScheduler.init(std.testing.allocator, 4, true);
    defer scheduler.deinit();
    try scheduler.setExecutionContext("77", null, "/tmp");

    const job = cron.CronJob{
        .id = "job-heartbeat",
        .expression = "* * * * *",
        .command = "noop",
        .job_type = .agent,
        .session_target = .main,
        .wake_mode = .next_heartbeat,
    };

    const output = try runCronAgentTurn(@ptrCast(@constCast(&cfg)), std.testing.allocator, &scheduler, &job, "ignored");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("", output);
    try std.testing.expectEqual(@as(usize, 1), heartbeat_wake.pendingCount());

    var req = heartbeat_wake.dequeue() orelse return error.TestUnexpectedResult;
    defer req.deinit();
    try std.testing.expect(req.user_id != null);
    try std.testing.expectEqualStrings("77", req.user_id.?);
    try std.testing.expect(std.mem.startsWith(u8, req.reason, CRON_WAKE_REASON_NEXT_HEARTBEAT_PREFIX));
}

test "resolveCronTurnOrigin maps wake heartbeat command to wake origin" {
    const job = cron.CronJob{
        .id = "heartbeat",
        .expression = "* * * * *",
        .command = HEARTBEAT_WAKE_COMMAND,
    };
    try std.testing.expectEqual(tools_mod.TurnOrigin.wake, resolveCronTurnOrigin(&job));
}

test "resolveCronTurnOrigin maps delivery jobs to proactive origin" {
    const job = cron.CronJob{
        .id = "daily-brief",
        .expression = "0 8 * * *",
        .command = "daily_morning_brief",
        .job_type = .agent,
        .session_target = .main,
        .delivery = .{
            .mode = .always,
            .channel = "telegram",
            .to = "chat-1",
        },
    };
    try std.testing.expectEqual(tools_mod.TurnOrigin.proactive, resolveCronTurnOrigin(&job));
}

test "resolveCronTurnOrigin keeps scheduler origin for non-delivery jobs" {
    const job = cron.CronJob{
        .id = "sync-task",
        .expression = "*/5 * * * *",
        .command = "sync",
        .delivery = .{ .mode = .none },
    };
    try std.testing.expectEqual(tools_mod.TurnOrigin.scheduler, resolveCronTurnOrigin(&job));
}

test "resolveCronSessionTarget reroutes non-user main target to isolated" {
    const job = cron.CronJob{
        .id = "daily-brief",
        .expression = "0 8 * * *",
        .command = "daily_morning_brief",
        .session_target = .main,
        .delivery = .{
            .mode = .always,
            .channel = "telegram",
            .to = "chat-1",
        },
    };
    const resolution = resolveCronSessionTarget(&job, .proactive);
    try std.testing.expectEqual(cron.SessionTarget.isolated, resolution.effective_target);
    try std.testing.expect(resolution.rerouted_from_main);
}

test "resolveCronSessionTarget keeps user main target" {
    const job = cron.CronJob{
        .id = "interactive",
        .expression = "* * * * *",
        .command = "noop",
        .session_target = .main,
    };
    const resolution = resolveCronSessionTarget(&job, .user);
    try std.testing.expectEqual(cron.SessionTarget.main, resolution.effective_target);
    try std.testing.expect(!resolution.rerouted_from_main);
}

test "resolveCronSessionLaneWithMetrics records reroute counter" {
    lane_metrics.resetForTest();
    const job = cron.CronJob{
        .id = "metric-probe",
        .expression = "* * * * *",
        .command = "noop",
        .session_target = .main,
        .delivery = .{
            .mode = .always,
            .channel = "telegram",
            .to = "chat-1",
        },
    };
    const resolution = resolveCronSessionLaneWithMetrics(&job, .proactive);
    try std.testing.expectEqual(cron.SessionTarget.isolated, resolution.effective_target);

    var snap = try lane_metrics.snapshotBackgroundMainReroutes(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), snap.total);
    try std.testing.expect(snap.last_job_id != null);
    try std.testing.expectEqualStrings("metric-probe", snap.last_job_id.?);
}

test "parseHeartbeatReplyDirective accepts HEARTBEAT_OK variants" {
    try std.testing.expectEqual(HeartbeatReplyDirective.ok, parseHeartbeatReplyDirective("HEARTBEAT_OK"));
    try std.testing.expectEqual(HeartbeatReplyDirective.ok, parseHeartbeatReplyDirective("<b>HEARTBEAT_OK</b> ✅"));
}

test "parseHeartbeatReplyDirective accepts HEARTBEAT_SEND payload" {
    const parsed = parseHeartbeatReplyDirective("HEARTBEAT_SEND: Morning brief delivered.");
    switch (parsed) {
        .send => |payload| try std.testing.expectEqualStrings("Morning brief delivered.", payload),
        else => return error.TestUnexpectedResult,
    }
}

test "parseHeartbeatReplyDirective rejects narrative output" {
    const parsed = parseHeartbeatReplyDirective("Morning brief is pending but blocked.");
    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings("invalid_heartbeat_reply_format", reason),
        else => return error.TestUnexpectedResult,
    }
}

test "parseHeartbeatReplyDirective rejects empty send payload" {
    const parsed = parseHeartbeatReplyDirective("HEARTBEAT_SEND:   ");
    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings("invalid_heartbeat_reply_format", reason),
        else => return error.TestUnexpectedResult,
    }
}

test "parseHeartbeatReplyDirective rejects multi-line payload" {
    const parsed = parseHeartbeatReplyDirective(
        \\HEARTBEAT_SEND: line one
        \\line two
    );
    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings("invalid_heartbeat_reply_format", reason),
        else => return error.TestUnexpectedResult,
    }
}

test "mapHeartbeatOutcomeState maps terminal actions" {
    const sent = mapHeartbeatOutcomeState("sent", "sent");
    try std.testing.expectEqualStrings("sent", sent.status);

    const blocked_rate = mapHeartbeatOutcomeState("blocked_rate", "rate_limit");
    try std.testing.expectEqualStrings("blocked_rate", blocked_rate.status);

    const blocked_dedupe = mapHeartbeatOutcomeState("blocked_dedupe", "dedupe_window");
    try std.testing.expectEqualStrings("blocked_dedupe", blocked_dedupe.status);

    const failed = mapHeartbeatOutcomeState("channel_not_found", "channel_not_found");
    try std.testing.expectEqualStrings("send_failed", failed.status);
}

test "deliveryOutcomeThread writes heartbeat runtime terminal state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(data_root);
    try tmp.dir.makePath("1");

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .tenant = .{
            .enabled = true,
            .data_root = data_root,
        },
    };
    var state = DaemonState{};
    var event_bus = bus_mod.Bus.init();
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, deliveryOutcomeThread, .{
        std.testing.allocator,
        &cfg,
        &state,
        &event_bus,
        null,
    });

    const outcome = try bus_mod.makeDeliveryOutcome(
        std.testing.allocator,
        "heartbeat",
        "1",
        "telegram",
        "1110331014",
        "sent",
        "sent",
        99,
    );
    try event_bus.publishDeliveryOutcome(outcome);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    event_bus.close();
    thread.join();

    const runtime_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/1/heartbeat_runtime.json", .{data_root});
    defer std.testing.allocator.free(runtime_path);
    const runtime_file = try std.fs.openFileAbsolute(runtime_path, .{});
    defer runtime_file.close();
    const content = try runtime_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"last_status\":\"sent\"") != null);
}

test "default heartbeat templates are treated as effectively empty" {
    try std.testing.expect(isHeartbeatContentEffectivelyEmpty(
        \\# HEARTBEAT.md
        \\
        \\# Keep this file empty (or with only comments) to skip heartbeat API calls.
        \\
        \\# Add tasks below when you want the agent to check something periodically.
    ));

    // v1.14.18-B G19 (DAEMON-PROMPT-HONESTY) — the legacy ZAKI BOT
    // HEARTBEAT.md template suggested a category that promised features
    // the agent does not deliver today (deferred to v1.14.19 sleep-cycle
    // SC4 territory). §14.6 honest-config: prompts and shipped templates
    // MUST NOT advertise features the agent does not actually deliver.
    // The unsupported "nightly summaries" suggestion line was stripped
    // from this fixture; the surrounding template content remains because
    // `isDefaultHeartbeatTemplate` keys off the "# HEARTBEAT.md - " prefix
    // + "Suggested categories:" + "Keep only tasks the user actually
    // wants automated." markers (daemon.zig:577-583), none of which is
    // the stripped line. When v1.14.19 sleep-cycle ships actual nightly
    // summary support, re-introducing the suggestion is fine — it will
    // then describe a real capability.
    try std.testing.expect(isHeartbeatContentEffectivelyEmpty(
        \\# HEARTBEAT.md - ZAKI BOT
        \\
        \\Use this file to define recurring, proactive work.
        \\
        \\Default operating rules:
        \\- be useful, not noisy
        \\- respect quiet hours and notification limits
        \\- prefer summaries, drafts, and preparation over interruption
        \\- if a recurring task can wait, batch it
        \\
        \\Suggested categories:
        \\- morning brief
        \\- inbox or message triage after integrations are connected
        \\- project status follow-ups
        \\- reminders before deadlines
        \\
        \\Keep only tasks the user actually wants automated.
    ));
}

test "heartbeat prompt treats scheduler as execution truth" {
    try std.testing.expect(std.mem.indexOf(u8, HEARTBEAT_PROMPT_DEFAULT, "Scheduler state is execution truth") != null);
    try std.testing.expect(std.mem.indexOf(u8, HEARTBEAT_PROMPT_DEFAULT, "Do not report scheduler-only jobs as drift") != null);
}

test "makeHeartbeatDedupeKey stable for same payload" {
    const key_a = try makeHeartbeatDedupeKey(std.testing.allocator, "1", "1110331014", "Morning brief delivered");
    defer std.testing.allocator.free(key_a);
    const key_b = try makeHeartbeatDedupeKey(std.testing.allocator, "1", "1110331014", "Morning brief delivered");
    defer std.testing.allocator.free(key_b);
    try std.testing.expectEqualStrings(key_a, key_b);
}

test "makeHeartbeatDedupeKey normalizes morning brief schedule variants" {
    const key_a = try makeHeartbeatDedupeKey(std.testing.allocator, "1", "1110331014", "Created the daily morning brief job at 08:00 CET.");
    defer std.testing.allocator.free(key_a);
    const key_b = try makeHeartbeatDedupeKey(std.testing.allocator, "1", "1110331014", "Created morning-brief cron job (08:00 CET daily).");
    defer std.testing.allocator.free(key_b);
    try std.testing.expectEqualStrings(key_a, key_b);
}

test "resolveInboundCanonicalSessionKey returns fallback in non-tenant mode" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = false;

    var msg = try bus_mod.makeInboundFull(
        std.testing.allocator,
        "telegram",
        "sender-1",
        "1110331014",
        "hello",
        "telegram:legacy",
        &.{},
        "{\"account_id\":\"default\"}",
    );
    defer msg.deinit(std.testing.allocator);

    const canonical = try resolveInboundCanonicalSessionKey(
        std.testing.allocator,
        &cfg,
        null,
        &msg,
        .{ .account_id = "default" },
        msg.session_key,
    );
    var canonical_mut = canonical;
    defer canonical_mut.deinit(std.testing.allocator);

    try std.testing.expect(canonical_mut.strict_reject_reason == null);
    try std.testing.expect(canonical_mut.session_key != null);
    try std.testing.expectEqualStrings("telegram:legacy", canonical_mut.session_key.?);
}

test "resolveInboundCanonicalSessionKey strict rejects unmapped telegram when manager missing" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";
    cfg.tenant.identity_mapping_enforcement = "staged_strict";
    cfg.tenant.identity_mapping_strict_channels = &[_][]const u8{"telegram"};

    var msg = try bus_mod.makeInboundFull(
        std.testing.allocator,
        "telegram",
        "sender-1",
        "1110331014",
        "hello",
        "telegram:legacy",
        &.{},
        "{\"account_id\":\"default\"}",
    );
    defer msg.deinit(std.testing.allocator);

    const canonical = try resolveInboundCanonicalSessionKey(
        std.testing.allocator,
        &cfg,
        null,
        &msg,
        .{ .account_id = "default" },
        msg.session_key,
    );
    var canonical_mut = canonical;
    defer canonical_mut.deinit(std.testing.allocator);

    try std.testing.expect(canonical_mut.session_key == null);
    try std.testing.expect(canonical_mut.strict_reject_reason != null);
    try std.testing.expectEqualStrings("state_manager_missing", canonical_mut.strict_reject_reason.?);
}

test "channelSupervisorThread respects shutdown" {
    // Pre-request shutdown so the supervisor exits immediately
    shutdown_requested.store(true, .release);
    defer shutdown_requested.store(false, .release);

    // Config with no telegram → supervisor goes straight to idle loop → exits on shutdown
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };

    var state = DaemonState{};
    state.addComponent("channels");

    var channel_registry = dispatch.ChannelRegistry.init(std.testing.allocator);
    defer channel_registry.deinit();
    var event_bus = bus_mod.Bus.init();

    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, channelSupervisorThread, .{
        std.testing.allocator, &config, &state, &channel_registry, null, &event_bus,
    });
    thread.join();

    // Channel component should have been marked running before the loop
    try std.testing.expect(state.components[0].?.running);
}

test "DaemonState supports all supervised components" {
    var state = DaemonState{};
    state.addComponent("gateway");
    state.addComponent("channels");
    state.addComponent("heartbeat");
    state.addComponent("scheduler");
    try std.testing.expectEqual(@as(usize, 4), state.component_count);
    try std.testing.expectEqualStrings("scheduler", state.components[3].?.name);
    try std.testing.expect(state.components[3].?.running);
}

test "writeStateFile produces valid content" {
    var state = DaemonState{
        .started = true,
        .gateway_host = "127.0.0.1",
        .gateway_port = 8080,
    };
    state.addComponent("test-comp");

    // Write to a temp path
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "daemon_state.json" });
    defer std.testing.allocator.free(path);

    try writeStateFile(std.testing.allocator, path, &state);

    // Read back and verify
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"status\": \"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "test-comp") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "127.0.0.1:8080") != null);
}
