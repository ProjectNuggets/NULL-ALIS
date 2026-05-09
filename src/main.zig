const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const yc = @import("nullalis");
const log_fmt = @import("log_fmt.zig");

// Install custom log formatter — picks text or JSON based on NULLALIS_LOG_FORMAT.
// Must be declared at the root module so Zig's std.log picks it up.
pub const std_options: std.Options = .{
    .logFn = log_fmt.logFn,
};

var sentry_runtime: ?*yc.sentry_runtime.Runtime = null;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (sentry_runtime) |runtime| {
        runtime.capturePanic(msg);
        runtime.flush(1500);
    }
    if (ret_addr) |addr| {
        std.debug.print("panic ret_addr=0x{x}\n", .{addr});
    }
    if (error_return_trace) |trace| {
        std.debug.print("panic error return trace:\n", .{});
        std.debug.dumpStackTrace(trace.*);
    }
    std.debug.defaultPanic(msg, ret_addr);
}

const log = std.log.scoped(.main);

const Command = enum {
    agent,
    gateway,
    controller,
    service,
    status,
    version,
    onboard,
    doctor,
    arzt,
    cron,
    channel,
    skills,
    migrate,
    memory,
    capabilities,
    models,
    auth,
    update,
    help,
};

fn parseCommand(arg: []const u8) ?Command {
    const command_map = std.StaticStringMap(Command).initComptime(.{
        .{ "agent", .agent },
        .{ "gateway", .gateway },
        .{ "controller", .controller },
        .{ "service", .service },
        .{ "status", .status },
        .{ "version", .version },
        .{ "--version", .version },
        .{ "-V", .version },
        .{ "onboard", .onboard },
        .{ "doctor", .doctor },
        .{ "arzt", .arzt },
        .{ "cron", .cron },
        .{ "channel", .channel },
        .{ "skills", .skills },
        .{ "migrate", .migrate },
        .{ "memory", .memory },
        .{ "capabilities", .capabilities },
        .{ "models", .models },
        .{ "auth", .auth },
        .{ "update", .update },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
    });
    return command_map.get(arg);
}

const GatewayRole = yc.gateway.GatewayRole;

const GatewayRoleLaunchOptions = struct {
    role: GatewayRole = .shared,
    user_id: ?[]const u8 = null,
    controller_url: ?[]const u8 = null,
    advertise_url: ?[]const u8 = null,
};

const GatewayRoleArgParseResult = union(enum) {
    ok: GatewayRoleLaunchOptions,
    invalid_role: []const u8,
    missing_value: []const u8,
    unsupported_option: []const u8,
    unknown_option: []const u8,
    option_requires_role: struct {
        option: []const u8,
        role: GatewayRole,
    },
    missing_option_for_role: struct {
        option: []const u8,
        role: GatewayRole,
    },
    missing_user_id_for_role: GatewayRole,
};

fn parseGatewayRole(raw: []const u8) ?GatewayRole {
    if (std.mem.eql(u8, raw, "shared")) return .shared;
    if (std.mem.eql(u8, raw, "broker")) return .broker;
    if (std.mem.eql(u8, raw, "user_cell")) return .user_cell;
    return null;
}

fn parseGatewayRoleLaunchOptions(sub_args: []const []const u8) GatewayRoleArgParseResult {
    var out = GatewayRoleLaunchOptions{};

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--host")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--role")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            out.role = parseGatewayRole(sub_args[i]) orelse return .{ .invalid_role = sub_args[i] };
            continue;
        }
        if (std.mem.eql(u8, arg, "--user-id")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            out.user_id = sub_args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--workspace")) {
            return .{ .unsupported_option = arg };
        }
        if (std.mem.eql(u8, arg, "--idle-ttl-secs")) {
            return .{ .unsupported_option = arg };
        }
        if (std.mem.eql(u8, arg, "--controller-url")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            out.controller_url = sub_args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--advertise-url")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            out.advertise_url = sub_args[i];
            continue;
        }
        return .{ .unknown_option = arg };
    }

    if (out.controller_url != null and out.role == .shared) {
        return .{
            .option_requires_role = .{
                .option = "--controller-url",
                .role = .broker,
            },
        };
    }
    if (out.advertise_url != null and out.role != .user_cell) {
        return .{
            .option_requires_role = .{
                .option = "--advertise-url",
                .role = .user_cell,
            },
        };
    }
    if (out.role == .user_cell and out.controller_url != null and out.advertise_url == null) {
        return .{
            .missing_option_for_role = .{
                .option = "--advertise-url",
                .role = .user_cell,
            },
        };
    }
    if (out.role == .user_cell and out.user_id == null) {
        return .{ .missing_user_id_for_role = .user_cell };
    }
    return .{ .ok = out };
}

const ControllerBindOptions = struct {
    host: []const u8,
    port: u16,
    cell_namespace: []const u8,
};

const ControllerBindParseResult = union(enum) {
    ok: ControllerBindOptions,
    invalid_port: []const u8,
    missing_value: []const u8,
    unknown_option: []const u8,
};

fn defaultControllerPort(gateway_port: u16) u16 {
    if (gateway_port == std.math.maxInt(u16)) return gateway_port;
    return gateway_port + 1;
}

fn parseControllerBindOptions(default_host: []const u8, default_port: u16, sub_args: []const []const u8) ControllerBindParseResult {
    var out = ControllerBindOptions{
        .host = default_host,
        .port = default_port,
        .cell_namespace = "default",
    };

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            out.port = std.fmt.parseInt(u16, sub_args[i], 10) catch return .{ .invalid_port = sub_args[i] };
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            out.host = sub_args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--cell-namespace")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            out.cell_namespace = sub_args[i];
            continue;
        }
        return .{ .unknown_option = arg };
    }

    return .{ .ok = out };
}

fn parseOptionalUserIdFlag(command_name: []const u8, sub_args: []const []const u8) ?[]const u8 {
    var user_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--user-id")) {
            if (i + 1 >= sub_args.len) {
                std.debug.print("Usage: nullalis {s} [--user-id <id>]\n", .{command_name});
                std.process.exit(1);
            }
            i += 1;
            if (sub_args[i].len == 0) {
                std.debug.print("Invalid --user-id value: empty\n", .{});
                std.process.exit(1);
            }
            user_id = sub_args[i];
            continue;
        }
        std.debug.print("Unknown option for {s}: {s}\n", .{ command_name, arg });
        std.debug.print("Usage: nullalis {s} [--user-id <id>]\n", .{command_name});
        std.process.exit(1);
    }
    return user_id;
}

fn printMaxTasksReached(max_tasks: usize) void {
    std.debug.print(
        "Scheduler at max capacity ({d} jobs). Remove old jobs or increase scheduler.max_tasks.\n",
        .{max_tasks},
    );
}

fn gatewayLoopbackHost(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "0.0.0.0")) return "127.0.0.1";
    if (std.mem.eql(u8, host, "::")) return "127.0.0.1";
    return host;
}

/// V1.14.4 review F-1 closure — Standalone CLI subagent delivery.
///
/// Signature matches `yc.subagent.SubagentManager.CompletionDeliveryFn`.
/// The standalone CLI (`nullalis run`, `nullalis service`) creates a
/// SubagentManager with bus=null. Without a completion_delivery wired,
/// every subagent result hit the `path=none` branch in subagent.zig:709
/// and got silently discarded — the original symptom of
/// `project_subagent_received_bug` for CLI users.
///
/// This callback prints the subagent content directly to stderr so the
/// user sees the result in real-time as the subagent finishes. We don't
/// route into the parent agent's history because:
///   - The parent's turn loop has typically already returned by the
///     time the async subagent completes; pushing into history mid-
///     reply is racy and CLI doesn't have the gateway's session-pin
///     infrastructure.
///   - stderr is the user's terminal in CLI mode, exactly the right
///     surface for "here's what your delegate produced."
///
/// session_key is logged for traceability (CLI typically has one
/// session at a time so it's not strictly load-bearing, but matches
/// gateway tenant logging shape for future debugging).
///
/// Errors are non-fatal — we log to stderr regardless. Returning !void
/// keeps the signature contract; we never actually fail.
fn cliSubagentCompletionDelivery(
    _: ?*anyopaque,
    session_key: []const u8,
    content: []const u8,
) anyerror!void {
    std.debug.print(
        "\n[subagent → {s}]\n{s}\n\n",
        .{ session_key, content },
    );
}

fn isLoopbackBindHost(host_raw: []const u8) bool {
    const host = std.mem.trim(u8, host_raw, " \t\r\n");
    if (host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;
    return false;
}

fn invalidateTenantRuntimeCaches(
    allocator: std.mem.Allocator,
    cfg: *const yc.config.Config,
    user_ids: []const i64,
) !void {
    if (user_ids.len == 0) return;
    if (cfg.gateway.internal_service_tokens.len == 0) return error.MissingGatewayInternalToken;

    const url = try std.fmt.allocPrint(
        allocator,
        "http://{s}:{d}/internal/tenant-runtime-cache/invalidate",
        .{ gatewayLoopbackHost(cfg.gateway.host), cfg.gateway.port },
    );
    defer allocator.free(url);

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    const w = payload.writer(allocator);
    try w.writeAll("{\"user_ids\":[");
    for (user_ids, 0..) |user_id, index| {
        if (index > 0) try w.writeAll(",");
        try w.print("{d}", .{user_id});
    }
    try w.writeAll("]}");

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload.items,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "nullalis/1.0" },
            .{ .name = "X-Internal-Token", .value = cfg.gateway.internal_service_tokens[0] },
        },
        .response_writer = &response_writer.writer,
    }) catch return error.CacheInvalidationRequestFailed;

    if (result.status != .ok) return error.CacheInvalidationRejected;
}

pub fn main() !void {
    // Enable UTF-8 output on Windows console (fixes Cyrillic/Unicode garbling)
    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }

    // Resolve log format before any log call so everything (including Sentry
    // bootstrap) honors the chosen format.
    log_fmt.init();

    const allocator = std.heap.smp_allocator;
    var runtime = yc.sentry_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    sentry_runtime = &runtime;
    defer sentry_runtime = null;

    // Register globally so gateway/session observer chains can attach a
    // SentryObserver without threading the runtime through every init call.
    yc.sentry_runtime.setGlobal(&runtime);
    defer yc.sentry_runtime.clearGlobal();

    runMain(allocator) catch |err| {
        runtime.captureError("main", @errorName(err));
        runtime.flush(2000);
        return err;
    };
}

fn runMain(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = parseCommand(args[1]) orelse {
        std.debug.print("Unknown command: {s}\n\n", .{args[1]});
        printUsage();
        std.process.exit(1);
    };

    const sub_args = args[2..];

    switch (cmd) {
        .version => printVersion(),
        .status => {
            const user_id = parseOptionalUserIdFlag("status", sub_args);
            try yc.status.runWithUser(allocator, user_id);
        },
        .agent => try yc.agent.run(allocator, sub_args),
        .onboard => try runOnboard(allocator, sub_args),
        .doctor => {
            const user_id = parseOptionalUserIdFlag("doctor", sub_args);
            try yc.doctor.runWithUser(allocator, user_id);
        },
        .arzt => {
            const user_id = parseOptionalUserIdFlag("arzt", sub_args);
            try yc.doctor.runWithUser(allocator, user_id);
        },
        .help => printUsage(),
        .gateway => try runGateway(allocator, sub_args),
        .controller => try runController(allocator, sub_args),
        .service => try runService(allocator, sub_args),
        .cron => try runCron(allocator, sub_args),
        .channel => try runChannel(allocator, sub_args),
        .skills => try runSkills(allocator, sub_args),
        .migrate => try runMigrate(allocator, sub_args),
        .memory => try runMemory(allocator, sub_args),
        .capabilities => try runCapabilities(allocator, sub_args),
        .models => try runModels(allocator, sub_args),
        .auth => try runAuth(allocator, sub_args),
        .update => try runUpdate(allocator, sub_args),
    }
}

fn printVersion() void {
    var buf: [256]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    bw.interface.print("nullalis {s}\n", .{yc.version.string}) catch return;
    bw.interface.flush() catch return;
}

const GatewayDaemonOverrideError = error{InvalidPort};

fn applyGatewayDaemonOverrides(cfg: *yc.config.Config, sub_args: []const []const u8) GatewayDaemonOverrideError!void {
    var port: u16 = cfg.gateway.port;
    var host: []const u8 = cfg.gateway.host;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if ((std.mem.eql(u8, sub_args[i], "--port") or std.mem.eql(u8, sub_args[i], "-p")) and i + 1 < sub_args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, sub_args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, sub_args[i], "--host") and i + 1 < sub_args.len) {
            i += 1;
            host = sub_args[i];
        }
    }

    cfg.gateway.port = port;
    cfg.gateway.host = host;
}

// ── Gateway ──────────────────────────────────────────────────────

fn runGateway(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
        std.process.exit(1);
    };
    defer cfg.deinit();

    const role_options = switch (parseGatewayRoleLaunchOptions(sub_args)) {
        .ok => |options| options,
        .invalid_role => |value| {
            std.debug.print("Invalid gateway role: {s}\n", .{value});
            std.debug.print("Usage: nullalis gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]\n", .{});
            std.process.exit(1);
        },
        .missing_value => |flag| {
            std.debug.print("Missing value for {s}\n", .{flag});
            std.debug.print("Usage: nullalis gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]\n", .{});
            std.process.exit(1);
        },
        .unsupported_option => |flag| {
            std.debug.print("Gateway option not implemented yet: {s}\n", .{flag});
            std.debug.print("Usage: nullalis gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]\n", .{});
            std.process.exit(1);
        },
        .unknown_option => |flag| {
            std.debug.print("Unknown gateway option: {s}\n", .{flag});
            std.debug.print("Usage: nullalis gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]\n", .{});
            std.process.exit(1);
        },
        .option_requires_role => |info| {
            if (std.mem.eql(u8, info.option, "--controller-url")) {
                std.debug.print("Gateway option {s} requires --role broker or user_cell\n", .{info.option});
            } else if (std.mem.eql(u8, info.option, "--advertise-url")) {
                std.debug.print("Gateway option {s} requires --role user_cell\n", .{info.option});
            } else {
                std.debug.print("Gateway option {s} requires --role {s}\n", .{ info.option, @tagName(info.role) });
            }
            std.debug.print("Usage: nullalis gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]\n", .{});
            std.process.exit(1);
        },
        .missing_option_for_role => |info| {
            std.debug.print("Gateway role '{s}' requires {s}\n", .{ @tagName(info.role), info.option });
            std.debug.print("Usage: nullalis gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]\n", .{});
            std.process.exit(1);
        },
        .missing_user_id_for_role => |role| {
            std.debug.print("Gateway role '{s}' requires --user-id\n", .{@tagName(role)});
            std.debug.print("Usage: nullalis gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]\n", .{});
            std.process.exit(1);
        },
    };

    applyGatewayDaemonOverrides(&cfg, sub_args) catch {
        std.debug.print("Invalid port in CLI args.\n", .{});
        std.process.exit(1);
    };

    cfg.validate() catch |err| {
        yc.config.Config.printValidationError(err);
        std.process.exit(1);
    };

    switch (role_options.role) {
        .shared => try yc.daemon.run(allocator, &cfg, cfg.gateway.host, cfg.gateway.port),
        .broker => {
            const derived_controller_url = if (role_options.controller_url) |value|
                value
            else
                try std.fmt.allocPrint(
                    allocator,
                    "http://{s}:{d}",
                    .{ gatewayLoopbackHost(cfg.gateway.host), defaultControllerPort(cfg.gateway.port) },
                );
            defer if (role_options.controller_url == null) allocator.free(derived_controller_url);
            try yc.gateway.runWithRole(allocator, cfg.gateway.host, cfg.gateway.port, &cfg, null, .broker, derived_controller_url, null, null);
        },
        .user_cell => {
            if (!cfg.tenant.enabled) {
                std.debug.print("Gateway role 'user_cell' requires tenant.enabled=true\n", .{});
                std.process.exit(1);
            }
            try yc.gateway.runWithRole(
                allocator,
                cfg.gateway.host,
                cfg.gateway.port,
                &cfg,
                null,
                .user_cell,
                role_options.controller_url,
                role_options.advertise_url,
                role_options.user_id,
            );
        },
    }
}

fn runController(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var owned_cfg: ?yc.config.Config = yc.config.Config.load(allocator) catch null;
    defer if (owned_cfg) |*cfg| cfg.deinit();

    const default_host = if (owned_cfg) |*cfg| cfg.gateway.host else "127.0.0.1";
    const default_port = if (owned_cfg) |*cfg| defaultControllerPort(cfg.gateway.port) else 3001;

    const bind_options = switch (parseControllerBindOptions(default_host, default_port, sub_args)) {
        .ok => |options| options,
        .invalid_port => |value| {
            std.debug.print("Invalid controller port: {s}\n", .{value});
            std.debug.print("Usage: nullalis controller [--port PORT] [--host HOST] [--cell-namespace NAMESPACE]\n", .{});
            std.process.exit(1);
        },
        .missing_value => |flag| {
            std.debug.print("Missing value for {s}\n", .{flag});
            std.debug.print("Usage: nullalis controller [--port PORT] [--host HOST] [--cell-namespace NAMESPACE]\n", .{});
            std.process.exit(1);
        },
        .unknown_option => |flag| {
            std.debug.print("Unknown controller option: {s}\n", .{flag});
            std.debug.print("Usage: nullalis controller [--port PORT] [--host HOST] [--cell-namespace NAMESPACE]\n", .{});
            std.process.exit(1);
        },
    };

    const internal_service_tokens = if (owned_cfg) |*cfg| cfg.gateway.internal_service_tokens else &.{};
    const production_like_controller = !isLoopbackBindHost(bind_options.host);
    const token_validation = yc.gateway.validateInternalTokensForMode(
        internal_service_tokens,
        production_like_controller,
    );
    if (production_like_controller and !token_validation.ok) {
        std.debug.print(
            "Controller internal token configuration invalid: {s}\n",
            .{token_validation.reason orelse "unknown"},
        );
        std.process.exit(1);
    }
    const internal_auth_required = token_validation.configured or production_like_controller;

    try yc.controller.run(
        allocator,
        bind_options.host,
        bind_options.port,
        bind_options.cell_namespace,
        if (owned_cfg) |*cfg| cfg.gateway.port else 3000,
        internal_service_tokens,
        internal_auth_required,
    );
}

// ── Service ──────────────────────────────────────────────────────

fn runService(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print("Usage: nullalis service <install|start|stop|status|uninstall>\n", .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];
    const service_cmd: yc.service.ServiceCommand = blk: {
        const map = .{
            .{ "install", yc.service.ServiceCommand.install },
            .{ "start", yc.service.ServiceCommand.start },
            .{ "stop", yc.service.ServiceCommand.stop },
            .{ "status", yc.service.ServiceCommand.status },
            .{ "uninstall", yc.service.ServiceCommand.uninstall },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, subcmd, entry[0])) break :blk entry[1];
        }
        std.debug.print("Unknown service command: {s}\n", .{subcmd});
        std.debug.print("Usage: nullalis service <install|start|stop|status|uninstall>\n", .{});
        std.process.exit(1);
    };

    var cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
        std.process.exit(1);
    };
    defer cfg.deinit();

    yc.service.handleCommand(allocator, service_cmd, cfg.config_path) catch |err| {
        const any_err: anyerror = err;
        switch (any_err) {
            error.UnsupportedPlatform => {
                std.debug.print("Service management is not supported on this platform.\n", .{});
            },
            error.NoHomeDir => {
                std.debug.print("Could not resolve home directory for service files.\n", .{});
            },
            error.SystemctlUnavailable => {
                std.debug.print("`systemctl` is not available; Linux service commands require systemd user services.\n", .{});
                std.debug.print("Run `nullalis gateway` in the foreground or use another supervisor.\n", .{});
            },
            error.SystemdUserUnavailable => {
                std.debug.print("systemd user services are unavailable (`systemctl --user`).\n", .{});
                std.debug.print("Verify with `systemctl --user status` or run `nullalis gateway` in the foreground.\n", .{});
            },
            error.CommandFailed => {
                std.debug.print("Service command failed: {s}\n", .{subcmd});
            },
            else => return any_err,
        }
        std.process.exit(1);
    };
}

// ── Cron ─────────────────────────────────────────────────────────

const CronBackendMode = enum {
    auto,
    file,
    postgres,
};

const CronBackendError = error{
    PostgresBackendNotEnabled,
    MissingConfig,
    InvalidRuntimeConfig,
    MissingUserId,
};

const PostgresCronContext = struct {
    cfg: *const yc.config.Config,
    user_id: i64,
};

fn parseCronBackendMode(raw: []const u8) ?CronBackendMode {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "file")) return .file;
    if (std.mem.eql(u8, raw, "postgres")) return .postgres;
    return null;
}

fn resolveCronBackendMode(cfg_opt: ?*const yc.config.Config, mode: CronBackendMode) CronBackendMode {
    return switch (mode) {
        .file => .file,
        .postgres => .postgres,
        .auto => blk: {
            if (cfg_opt) |cfg| {
                if (cfg.tenant.enabled and std.mem.eql(u8, cfg.state.backend, "postgres") and build_options.enable_postgres) {
                    break :blk .postgres;
                }
            }
            break :blk .file;
        },
    };
}

fn resolvePostgresCronContext(cfg_opt: ?*const yc.config.Config, user_id_opt: ?i64) CronBackendError!PostgresCronContext {
    if (!build_options.enable_postgres) return error.PostgresBackendNotEnabled;
    const cfg = cfg_opt orelse return error.MissingConfig;
    if (!cfg.tenant.enabled or !std.mem.eql(u8, cfg.state.backend, "postgres")) {
        return error.InvalidRuntimeConfig;
    }
    const user_id = user_id_opt orelse return error.MissingUserId;
    return .{
        .cfg = cfg,
        .user_id = user_id,
    };
}

fn mainSessionKeyForUser(allocator: std.mem.Allocator, user_id: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "agent:zaki-bot:user:{d}:main", .{user_id});
}

fn tenantWorkspacePathForUser(allocator: std.mem.Allocator, cfg: *const yc.config.Config, user_id: i64) ![]u8 {
    if (cfg.tenant.data_root.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}/{d}/workspace", .{ cfg.tenant.data_root, user_id });
    }
    return allocator.dupe(u8, cfg.workspace_dir);
}

fn ensurePostgresCronUserProvisioned(allocator: std.mem.Allocator, cfg: *const yc.config.Config, user_id: i64) !void {
    var mgr = try yc.zaki_state.Manager.init(allocator, cfg.state);
    defer mgr.deinit();
    const workspace_path = try tenantWorkspacePathForUser(allocator, cfg, user_id);
    defer allocator.free(workspace_path);
    try mgr.provisionUser(user_id, workspace_path);
}

fn loadCronSchedulerFromPostgres(
    allocator: std.mem.Allocator,
    cfg: *const yc.config.Config,
    user_id: i64,
) !yc.cron.CronScheduler {
    try ensurePostgresCronUserProvisioned(allocator, cfg, user_id);

    var scheduler = yc.cron.CronScheduler.init(allocator, cfg.scheduler.max_tasks, cfg.scheduler.enabled);
    errdefer scheduler.deinit();

    var mgr = try yc.zaki_state.Manager.init(allocator, cfg.state);
    defer mgr.deinit();

    const jobs_json = try mgr.getJobsJson(allocator, user_id);
    defer allocator.free(jobs_json);
    const trimmed = std.mem.trim(u8, jobs_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return scheduler;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return scheduler;

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        try yc.cron.appendJobFromJsonObject(&scheduler, item.object);
    }

    return scheduler;
}

fn saveCronSchedulerToPostgres(
    allocator: std.mem.Allocator,
    cfg: *const yc.config.Config,
    user_id: i64,
    scheduler: *const yc.cron.CronScheduler,
) !void {
    try ensurePostgresCronUserProvisioned(allocator, cfg, user_id);

    var mgr = try yc.zaki_state.Manager.init(allocator, cfg.state);
    defer mgr.deinit();

    const content = try yc.cron.saveJobsToSlice(allocator, scheduler);
    defer allocator.free(content);
    const session_key = try mainSessionKeyForUser(allocator, user_id);
    defer allocator.free(session_key);
    try mgr.replaceJobsJson(user_id, session_key, content);
}

fn runCronPostgres(
    allocator: std.mem.Allocator,
    cfg: *const yc.config.Config,
    user_id: i64,
    subcmd: []const u8,
    args: []const []const u8,
) !void {
    if (std.mem.eql(u8, subcmd, "list")) {
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();

        const jobs = scheduler.listJobs();
        if (jobs.len == 0) {
            std.debug.print("info(cron): No scheduled tasks yet.\n", .{});
            std.debug.print("info(cron): Usage:\n", .{});
            std.debug.print("info(cron):   nullalis cron add '*/10 * * * *' 'echo hello'\n", .{});
            std.debug.print("info(cron):   nullalis cron once 30m 'echo reminder'\n", .{});
            return;
        }

        std.debug.print("info(cron): Scheduled jobs ({d}):\n", .{jobs.len});
        for (jobs) |job| {
            const flags: []const u8 = blk: {
                if (job.paused and job.one_shot) break :blk " [paused, one-shot]";
                if (job.paused) break :blk " [paused]";
                if (job.one_shot) break :blk " [one-shot]";
                break :blk "";
            };
            const status = job.last_status orelse "n/a";
            std.debug.print("info(cron): - {s} | {s} | next={d} | status={s}{s} cmd: {s}\n", .{
                job.id,
                job.expression,
                job.next_run_secs,
                status,
                flags,
                job.command,
            });
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "add")) {
        if (args.len < 2) {
            std.debug.print("Usage: nullalis cron add <expression> <command>\n", .{});
            std.process.exit(1);
        }
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();
        const job = scheduler.addJob(args[0], args[1]) catch |err| {
            if (err == error.MaxTasksReached) {
                printMaxTasksReached(scheduler.max_tasks);
                std.process.exit(1);
            }
            return err;
        };
        try saveCronSchedulerToPostgres(allocator, cfg, user_id, &scheduler);
        std.debug.print("info(cron): Added cron job {s}\n", .{job.id});
        std.debug.print("info(cron):   Expr: {s}\n", .{job.expression});
        std.debug.print("info(cron):   Next: {d}\n", .{job.next_run_secs});
        std.debug.print("info(cron):   Cmd : {s}\n", .{job.command});
        return;
    }

    if (std.mem.eql(u8, subcmd, "once")) {
        if (args.len < 2) {
            std.debug.print("Usage: nullalis cron once <delay> <command>\n", .{});
            std.process.exit(1);
        }
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();
        const job = scheduler.addOnce(args[0], args[1]) catch |err| {
            if (err == error.MaxTasksReached) {
                printMaxTasksReached(scheduler.max_tasks);
                std.process.exit(1);
            }
            return err;
        };
        try saveCronSchedulerToPostgres(allocator, cfg, user_id, &scheduler);
        std.debug.print("info(cron): Added one-shot task {s}\n", .{job.id});
        std.debug.print("info(cron):   Runs at: {d}\n", .{job.next_run_secs});
        std.debug.print("info(cron):   Cmd    : {s}\n", .{job.command});
        return;
    }

    if (std.mem.eql(u8, subcmd, "remove")) {
        if (args.len < 1) {
            std.debug.print("Usage: nullalis cron remove <id>\n", .{});
            std.process.exit(1);
        }
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();
        if (scheduler.removeJob(args[0])) {
            try saveCronSchedulerToPostgres(allocator, cfg, user_id, &scheduler);
            std.debug.print("info(cron): Removed cron job {s}\n", .{args[0]});
        } else {
            std.debug.print("info(cron): Cron job '{s}' not found\n", .{args[0]});
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "pause")) {
        if (args.len < 1) {
            std.debug.print("Usage: nullalis cron pause <id>\n", .{});
            std.process.exit(1);
        }
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();
        switch (scheduler.pauseJob(args[0])) {
            .changed => {
                try saveCronSchedulerToPostgres(allocator, cfg, user_id, &scheduler);
                std.debug.print("info(cron): Paused job {s}\n", .{args[0]});
            },
            .already_paused => {
                std.debug.print("info(cron): Cron job {s} is already paused\n", .{args[0]});
            },
            .already_active => unreachable,
            .not_found => {
                std.debug.print("info(cron): Cron job '{s}' not found\n", .{args[0]});
            },
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "resume")) {
        if (args.len < 1) {
            std.debug.print("Usage: nullalis cron resume <id>\n", .{});
            std.process.exit(1);
        }
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();
        switch (scheduler.resumeJob(args[0])) {
            .changed => {
                try saveCronSchedulerToPostgres(allocator, cfg, user_id, &scheduler);
                std.debug.print("info(cron): Resumed job {s}\n", .{args[0]});
            },
            .already_active => {
                std.debug.print("info(cron): Cron job {s} is already active\n", .{args[0]});
            },
            .already_paused => unreachable,
            .not_found => {
                std.debug.print("info(cron): Cron job '{s}' not found\n", .{args[0]});
            },
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "run")) {
        if (args.len < 1) {
            std.debug.print("Usage: nullalis cron run <id>\n", .{});
            std.process.exit(1);
        }
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();

        if (scheduler.getJob(args[0])) |job| {
            std.debug.print("info(cron): Running job '{s}': {s}\n", .{ args[0], job.command });
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ yc.platform.getShell(), yc.platform.getShellFlag(), job.command },
            }) catch |err| {
                std.debug.print("error(cron): Job '{s}' failed: {s}\n", .{ args[0], @errorName(err) });
                return;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.stdout.len > 0) std.debug.print("{s}\n", .{result.stdout});
            const exit_code: u8 = switch (result.term) {
                .Exited => |code| code,
                else => 1,
            };
            std.debug.print("info(cron): Job '{s}' completed (exit {d}).\n", .{ args[0], exit_code });
        } else {
            std.debug.print("info(cron): Cron job '{s}' not found\n", .{args[0]});
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "update")) {
        if (args.len < 1) {
            std.debug.print("Usage: nullalis cron update <id> [--expression <expr>] [--command <cmd>] [--enable] [--disable]\n", .{});
            std.process.exit(1);
        }
        const id = args[0];
        var expression: ?[]const u8 = null;
        var command: ?[]const u8 = null;
        var enabled: ?bool = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--expression") and i + 1 < args.len) {
                i += 1;
                expression = args[i];
            } else if (std.mem.eql(u8, args[i], "--command") and i + 1 < args.len) {
                i += 1;
                command = args[i];
            } else if (std.mem.eql(u8, args[i], "--enable")) {
                enabled = true;
            } else if (std.mem.eql(u8, args[i], "--disable")) {
                enabled = false;
            }
        }

        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();
        const patch = yc.cron.CronJobPatch{
            .expression = expression,
            .command = command,
            .enabled = enabled,
        };
        if (scheduler.updateJob(allocator, id, patch)) {
            try saveCronSchedulerToPostgres(allocator, cfg, user_id, &scheduler);
            std.debug.print("info(cron): Updated job {s}\n", .{id});
        } else {
            std.debug.print("info(cron): Cron job '{s}' not found\n", .{id});
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "runs")) {
        if (args.len < 1) {
            std.debug.print("Usage: nullalis cron runs <id>\n", .{});
            std.process.exit(1);
        }
        var scheduler = try loadCronSchedulerFromPostgres(allocator, cfg, user_id);
        defer scheduler.deinit();
        if (scheduler.getJob(args[0])) |job| {
            std.debug.print("info(cron): Run history for job {s} ({s}):\n", .{ args[0], job.command });
            const status = job.last_status orelse "never run";
            std.debug.print("info(cron):   Last status: {s}\n", .{status});
            std.debug.print("info(cron):   Next run:    {d}\n", .{job.next_run_secs});
        } else {
            std.debug.print("info(cron): Cron job '{s}' not found\n", .{args[0]});
        }
        return;
    }

    std.debug.print("Unknown cron command: {s}\n", .{subcmd});
    std.process.exit(1);
}

fn runCron(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullalis cron <command> [args]
            \\
            \\Commands:
            \\  list                          List all scheduled tasks
            \\  add <expression> <command>    Add a recurring cron job
            \\  once <delay> <command>        Add a one-shot delayed task
            \\  remove <id>                   Remove a scheduled task
            \\  pause <id>                    Pause a scheduled task
            \\  resume <id>                   Resume a paused task
            \\  run <id>                      Run a scheduled task immediately
            \\  update <id> [options]         Update a cron job
            \\  runs <id>                     List recent run history for a job
            \\  --backend <auto|file|postgres>  Scheduler backend (default: auto)
            \\  --user-id <id>                Required with postgres backend
            \\
        , .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];
    var backend_mode: CronBackendMode = .auto;
    var user_id_opt: ?i64 = null;
    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(allocator);

    var i: usize = 1;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--backend")) {
            if (i + 1 >= sub_args.len) {
                std.debug.print("Usage: nullalis cron {s} ... --backend <auto|file|postgres>\n", .{subcmd});
                std.process.exit(1);
            }
            i += 1;
            backend_mode = parseCronBackendMode(sub_args[i]) orelse {
                std.debug.print("Invalid --backend value: {s}\n", .{sub_args[i]});
                std.process.exit(1);
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--user-id")) {
            if (i + 1 >= sub_args.len) {
                std.debug.print("Usage: nullalis cron {s} ... --user-id <id>\n", .{subcmd});
                std.process.exit(1);
            }
            i += 1;
            user_id_opt = std.fmt.parseInt(i64, sub_args[i], 10) catch {
                std.debug.print("Invalid --user-id value: {s}\n", .{sub_args[i]});
                std.process.exit(1);
            };
            continue;
        }
        try filtered.append(allocator, arg);
    }

    var cfg_opt: ?yc.config.Config = yc.config.Config.load(allocator) catch null;
    defer if (cfg_opt) |*cfg| cfg.deinit();
    const cfg_ptr: ?*const yc.config.Config = if (cfg_opt) |*cfg| cfg else null;
    const resolved_backend = resolveCronBackendMode(cfg_ptr, backend_mode);

    if (resolved_backend == .postgres) {
        const ctx = resolvePostgresCronContext(cfg_ptr, user_id_opt) catch |err| {
            switch (err) {
                error.PostgresBackendNotEnabled => std.debug.print("Postgres backend is not enabled in this build.\n", .{}),
                error.MissingConfig => std.debug.print("No config found; postgres cron backend is unavailable.\n", .{}),
                error.InvalidRuntimeConfig => std.debug.print("Postgres cron backend requires tenant.enabled=true and state.backend=postgres.\n", .{}),
                error.MissingUserId => std.debug.print("Postgres cron backend requires --user-id <id>.\n", .{}),
            }
            std.process.exit(1);
        };
        try runCronPostgres(allocator, ctx.cfg, ctx.user_id, subcmd, filtered.items);
        return;
    }

    if (std.mem.eql(u8, subcmd, "list")) {
        try yc.cron.cliListJobs(allocator);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (filtered.items.len < 2) {
            std.debug.print("Usage: nullalis cron add <expression> <command>\n", .{});
            std.process.exit(1);
        }
        yc.cron.cliAddJob(allocator, filtered.items[0], filtered.items[1]) catch |err| {
            if (err == error.MaxTasksReached) {
                const max_tasks = if (cfg_ptr) |cfg| @max(@as(usize, 1), cfg.scheduler.max_tasks) else @as(usize, 1024);
                printMaxTasksReached(max_tasks);
                std.process.exit(1);
            }
            return err;
        };
    } else if (std.mem.eql(u8, subcmd, "once")) {
        if (filtered.items.len < 2) {
            std.debug.print("Usage: nullalis cron once <delay> <command>\n", .{});
            std.process.exit(1);
        }
        yc.cron.cliAddOnce(allocator, filtered.items[0], filtered.items[1]) catch |err| {
            if (err == error.MaxTasksReached) {
                const max_tasks = if (cfg_ptr) |cfg| @max(@as(usize, 1), cfg.scheduler.max_tasks) else @as(usize, 1024);
                printMaxTasksReached(max_tasks);
                std.process.exit(1);
            }
            return err;
        };
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (filtered.items.len < 1) {
            std.debug.print("Usage: nullalis cron remove <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliRemoveJob(allocator, filtered.items[0]);
    } else if (std.mem.eql(u8, subcmd, "pause")) {
        if (filtered.items.len < 1) {
            std.debug.print("Usage: nullalis cron pause <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliPauseJob(allocator, filtered.items[0]);
    } else if (std.mem.eql(u8, subcmd, "resume")) {
        if (filtered.items.len < 1) {
            std.debug.print("Usage: nullalis cron resume <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliResumeJob(allocator, filtered.items[0]);
    } else if (std.mem.eql(u8, subcmd, "run")) {
        if (filtered.items.len < 1) {
            std.debug.print("Usage: nullalis cron run <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliRunJob(allocator, filtered.items[0]);
    } else if (std.mem.eql(u8, subcmd, "update")) {
        if (filtered.items.len < 1) {
            std.debug.print("Usage: nullalis cron update <id> [--expression <expr>] [--command <cmd>] [--enable] [--disable]\n", .{});
            std.process.exit(1);
        }
        const id = filtered.items[0];
        var expression: ?[]const u8 = null;
        var command: ?[]const u8 = null;
        var enabled: ?bool = null;
        var j: usize = 1;
        while (j < filtered.items.len) : (j += 1) {
            if (std.mem.eql(u8, filtered.items[j], "--expression") and j + 1 < filtered.items.len) {
                j += 1;
                expression = filtered.items[j];
            } else if (std.mem.eql(u8, filtered.items[j], "--command") and j + 1 < filtered.items.len) {
                j += 1;
                command = filtered.items[j];
            } else if (std.mem.eql(u8, filtered.items[j], "--enable")) {
                enabled = true;
            } else if (std.mem.eql(u8, filtered.items[j], "--disable")) {
                enabled = false;
            }
        }
        try yc.cron.cliUpdateJob(allocator, id, expression, command, enabled);
    } else if (std.mem.eql(u8, subcmd, "runs")) {
        if (filtered.items.len < 1) {
            std.debug.print("Usage: nullalis cron runs <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliListRuns(allocator, filtered.items[0]);
    } else {
        std.debug.print("Unknown cron command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Channel ──────────────────────────────────────────────────────

fn runChannel(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullalis channel <command> [args]
            \\
            \\Commands:
            \\  list                          List configured channels
            \\  start [channel]               Start a channel (default: first available)
            \\  status                        Show channel health/status
            \\  add <type>                    Manual config-only (not implemented in CLI)
            \\  remove <name>                 Manual config-only (not implemented in CLI)
            \\
        , .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    var cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
        std.process.exit(1);
    };
    defer cfg.deinit();

    if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("Configured channels:\n", .{});
        for (yc.channel_catalog.known_channels) |meta| {
            var status_buf: [64]u8 = undefined;
            const status_text = yc.channel_catalog.statusText(&cfg, meta, &status_buf);
            std.debug.print("  {s}: {s}\n", .{ meta.label, status_text });
        }
    } else if (std.mem.eql(u8, subcmd, "start")) {
        try runChannelStart(allocator, sub_args[1..]);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        std.debug.print("Channel health:\n", .{});
        std.debug.print("  CLI: ok\n", .{});
        for (yc.channel_catalog.known_channels) |meta| {
            if (meta.id == .cli) continue;
            if (!yc.channel_catalog.isConfigured(&cfg, meta.id)) continue;
            std.debug.print("  {s}: configured (use `channel start` to verify)\n", .{meta.label});
        }
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis channel add <type>\n", .{});
            std.debug.print("Types:", .{});
            for (yc.channel_catalog.known_channels) |meta| {
                if (meta.id == .cli) continue;
                std.debug.print(" {s}", .{meta.key});
            }
            std.debug.print("\n", .{});
            std.process.exit(1);
        }
        std.debug.print("Not implemented: nullalis channel add\n", .{});
        std.debug.print("To add a '{s}' channel, edit your config file:\n  {s}\n", .{ sub_args[1], cfg.config_path });
        std.debug.print("Add a \"{s}\" object under \"channels\" with the required fields.\n", .{sub_args[1]});
        std.process.exit(2);
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis channel remove <name>\n", .{});
            std.process.exit(1);
        }
        std.debug.print("Not implemented: nullalis channel remove\n", .{});
        std.debug.print("To remove the '{s}' channel, edit your config file:\n  {s}\n", .{ sub_args[1], cfg.config_path });
        std.debug.print("Remove or set the \"{s}\" object to null under \"channels\".\n", .{sub_args[1]});
        std.process.exit(2);
    } else {
        std.debug.print("Unknown channel command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Skills ───────────────────────────────────────────────────────

fn runSkills(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullalis skills <command> [args]
            \\
            \\Commands:
            \\  list                          List installed skills
            \\  search <query>                Search Decision Hub by natural language
            \\  install <source|query>        Install from local path or Decision Hub
            \\  remove <name>                 Remove a skill
            \\  info <name>                   Show skill details
            \\
        , .{});
        std.process.exit(1);
    }

    var cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
        std.process.exit(1);
    };
    defer cfg.deinit();

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const skills_list = yc.skills.listSkills(allocator, cfg.workspace_dir) catch |err| {
            std.debug.print("Failed to list skills: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer yc.skills.freeSkills(allocator, skills_list);

        if (skills_list.len == 0) {
            std.debug.print("No skills installed.\n", .{});
        } else {
            std.debug.print("Installed skills ({d}):\n", .{skills_list.len});
            for (skills_list) |skill| {
                std.debug.print("  {s} v{s}", .{ skill.name, skill.version });
                if (skill.description.len > 0) {
                    std.debug.print(" -- {s}", .{skill.description});
                }
                std.debug.print("\n", .{});
            }
        }
    } else if (std.mem.eql(u8, subcmd, "install")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis skills install <source|query>\n", .{});
            std.process.exit(1);
        }
        const local_path_exists = sub_args.len == 2 and blk: {
            std.fs.cwd().access(sub_args[1], .{}) catch break :blk false;
            break :blk true;
        };
        if (local_path_exists) {
            yc.skills.installSkillFromPath(allocator, sub_args[1], cfg.workspace_dir) catch |err| {
                std.debug.print("Failed to install skill from path: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.debug.print("Skill installed from path: {s}\n", .{sub_args[1]});
        } else {
            const target = try std.mem.join(allocator, " ", sub_args[1..]);
            defer allocator.free(target);
            const result = yc.skills.installSkillFromDecisionHubQueryOrRef(allocator, target, cfg.workspace_dir, .{}) catch |err| {
                std.debug.print("Failed to install from Decision Hub: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer yc.skills.freeDecisionHubInstallResult(allocator, &result);
            std.debug.print(
                "Installed {s}/{s}@{s} as local skill `{s}`\n",
                .{ result.org_slug, result.skill_name, result.resolved_version, result.installed_name },
            );
        }
    } else if (std.mem.eql(u8, subcmd, "search")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis skills search <query>\n", .{});
            std.process.exit(1);
        }
        const query = try std.mem.join(allocator, " ", sub_args[1..]);
        defer allocator.free(query);
        const results = yc.skills.searchDecisionHubSkills(allocator, query, 10) catch |err| {
            std.debug.print("Decision Hub search failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer yc.skills.freeDecisionHubSearchResults(allocator, results);
        if (results.len == 0) {
            std.debug.print("No matching skills found.\n", .{});
        } else {
            std.debug.print("Decision Hub matches ({d}):\n", .{results.len});
            for (results) |item| {
                std.debug.print("  {s}/{s}", .{ item.org_slug, item.skill_name });
                if (item.latest_version.len > 0) std.debug.print(" @ {s}", .{item.latest_version});
                if (item.safety_rating.len > 0) std.debug.print(" [grade {s}]", .{item.safety_rating});
                if (item.description.len > 0) std.debug.print(" -- {s}", .{item.description});
                std.debug.print("\n", .{});
            }
        }
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis skills remove <name>\n", .{});
            std.process.exit(1);
        }
        yc.skills.removeSkill(allocator, sub_args[1], cfg.workspace_dir) catch |err| {
            std.debug.print("Failed to remove skill '{s}': {s}\n", .{ sub_args[1], @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("Removed skill: {s}\n", .{sub_args[1]});
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis skills info <name>\n", .{});
            std.process.exit(1);
        }
        const skill_path = std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ cfg.workspace_dir, sub_args[1] }) catch {
            std.debug.print("Out of memory\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(skill_path);

        const skill = yc.skills.loadSkill(allocator, skill_path) catch {
            std.debug.print("Skill '{s}' not found or invalid.\n", .{sub_args[1]});
            std.process.exit(1);
        };
        defer yc.skills.freeSkill(allocator, &skill);

        std.debug.print("Skill: {s}\n", .{skill.name});
        std.debug.print("  Version:     {s}\n", .{skill.version});
        if (skill.description.len > 0) {
            std.debug.print("  Description: {s}\n", .{skill.description});
        }
        if (skill.author.len > 0) {
            std.debug.print("  Author:      {s}\n", .{skill.author});
        }
        std.debug.print("  Enabled:     {}\n", .{skill.enabled});
        if (skill.instructions.len > 0) {
            std.debug.print("  Instructions: {d} bytes\n", .{skill.instructions.len});
        }
    } else {
        std.debug.print("Unknown skills command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// Hardware CLI surface — fully removed (D19, 2026-04-25). The
// deprecation stub previously here printed a removed-in-V1 notice
// for one release cycle; that cycle has elapsed. Hardware/IoT
// discovery is out of scope for the second-brain runtime. If a
// future fork wants embedded-device support, restore from git
// history at the D19 commit.

// ── Migrate ──────────────────────────────────────────────────────

fn runMigrate(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullalis migrate <source> [options]
            \\
            \\Sources:
            \\  openclaw                      Import from OpenClaw workspace (+ config migration)
            \\  tenant-config                 Normalize tenant config blobs to preference-only overlays
            \\
            \\Options:
            \\  --dry-run                     Preview without writing
            \\  --source <path>               Source workspace path
            \\  --user-id <id>                Restrict tenant-config migration to one user
            \\
        , .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, sub_args[0], "openclaw")) {
        var dry_run = false;
        var source_path: ?[]const u8 = null;

        var i: usize = 1;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, sub_args[i], "--source") and i + 1 < sub_args.len) {
                i += 1;
                source_path = sub_args[i];
            }
        }

        var cfg = yc.config.Config.load(allocator) catch {
            std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
            std.process.exit(1);
        };
        defer cfg.deinit();

        const stats = yc.migration.migrateOpenclaw(allocator, &cfg, source_path, dry_run) catch |err| {
            std.debug.print("Migration failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };

        if (dry_run) {
            std.debug.print("[DRY RUN] ", .{});
        }
        std.debug.print("Migration complete: {d} imported, {d} skipped\n", .{ stats.imported, stats.skipped_unchanged });
        if (stats.config_migrated) {
            if (dry_run) {
                std.debug.print("[DRY RUN] Config migration preview: ~/.openclaw/config.json -> {s}\n", .{cfg.config_path});
            } else {
                std.debug.print("Config migrated: ~/.openclaw/config.json -> {s}\n", .{cfg.config_path});
            }
        }
    } else if (std.mem.eql(u8, sub_args[0], "tenant-config")) {
        var dry_run = false;
        var target_user_id: ?i64 = null;

        var i: usize = 1;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, sub_args[i], "--user-id") and i + 1 < sub_args.len) {
                i += 1;
                target_user_id = std.fmt.parseInt(i64, sub_args[i], 10) catch {
                    std.debug.print("Invalid --user-id value: {s}\n", .{sub_args[i]});
                    std.process.exit(1);
                };
            }
        }

        var cfg = yc.config.Config.load(allocator) catch {
            std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
            std.process.exit(1);
        };
        defer cfg.deinit();

        if (!std.mem.eql(u8, cfg.state.backend, "postgres")) {
            std.debug.print("tenant-config migration requires state.backend=postgres\n", .{});
            std.process.exit(1);
        }

        var mgr = yc.zaki_state.Manager.init(allocator, cfg.state) catch |err| {
            std.debug.print("Failed to initialize tenant state manager: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer mgr.deinit();

        const rows = mgr.listUserConfigRows(allocator) catch |err| {
            std.debug.print("Failed to list tenant configs: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer {
            for (rows) |*row| row.deinit(allocator);
            allocator.free(rows);
        }

        var scanned: usize = 0;
        var changed: usize = 0;
        var unchanged: usize = 0;
        var ignored_override_total: usize = 0;
        var write_failures: usize = 0;
        var changed_user_ids: std.ArrayListUnmanaged(i64) = .empty;
        defer changed_user_ids.deinit(allocator);

        for (rows) |row| {
            if (target_user_id != null and row.user_id != target_user_id.?) continue;
            scanned += 1;

            const normalized = yc.user_settings.normalizeTenantConfigJson(allocator, row.config_json) catch |err| {
                std.debug.print("user {d}: normalize failed: {s}\n", .{ row.user_id, @errorName(err) });
                continue;
            };
            defer allocator.free(normalized.json);

            const old_trimmed = std.mem.trim(u8, row.config_json, " \t\r\n");
            const new_trimmed = std.mem.trim(u8, normalized.json, " \t\r\n");
            const is_changed = !std.mem.eql(u8, old_trimmed, new_trimmed);
            if (!is_changed) {
                unchanged += 1;
                continue;
            }

            changed += 1;
            ignored_override_total += normalized.ignored_override_count;
            if (dry_run) {
                std.debug.print(
                    "[DRY RUN] user {d}: assistant_mode={s} removed_sections={d}\n",
                    .{ row.user_id, normalized.settings.assistant_mode.toSlice(), normalized.ignored_override_count },
                );
                continue;
            }

            mgr.putConfigJson(row.user_id, normalized.json) catch |err| {
                std.debug.print("user {d}: write failed: {s}\n", .{ row.user_id, @errorName(err) });
                write_failures += 1;
                continue;
            };
            changed_user_ids.append(allocator, row.user_id) catch {
                std.debug.print("user {d}: cache invalidation queue append failed\n", .{row.user_id});
                write_failures += 1;
                continue;
            };
            std.debug.print(
                "user {d}: normalized assistant_mode={s} removed_sections={d}\n",
                .{ row.user_id, normalized.settings.assistant_mode.toSlice(), normalized.ignored_override_count },
            );
        }

        if (dry_run) {
            std.debug.print("[DRY RUN] ", .{});
        }
        std.debug.print(
            "Tenant config migration complete: scanned={d} changed={d} unchanged={d} removed_sections_total={d} write_failures={d}\n",
            .{ scanned, changed, unchanged, ignored_override_total, write_failures },
        );
        if (!dry_run and changed > 0) {
            invalidateTenantRuntimeCaches(allocator, &cfg, changed_user_ids.items) catch |err| {
                std.debug.print(
                    "Tenant configs updated, but runtime cache invalidation failed: {s}\n",
                    .{@errorName(err)},
                );
                std.process.exit(1);
            };
            std.debug.print("Tenant runtime cache invalidation complete: refreshed={d}\n", .{changed_user_ids.items.len});
        }
        if (!dry_run and write_failures > 0) {
            std.debug.print("Tenant config migration completed with write failures; inspect logs before rollout.\n", .{});
            std.process.exit(1);
        }
    } else {
        std.debug.print("Unknown migration source: {s}\n", .{sub_args[0]});
        std.process.exit(1);
    }
}

// ── Memory ───────────────────────────────────────────────────────

fn printMemoryUsage() void {
    std.debug.print(
        \\Usage: nullalis memory <command> [args]
        \\
        \\Commands:
        \\  stats                         Show resolved memory config and key counters
        \\  count                         Show total number of memory entries
        \\  reindex                       Rebuild vector index from primary memory
        \\  search <query> [--limit N]    Run runtime retrieval (keyword/hybrid)
        \\  get <key>                     Show a single memory entry by key
        \\  list [--category C] [--limit N]
        \\                                List memory entries (default limit: 20)
        \\  drain-outbox                  Drain durable vector outbox queue
        \\  forget <key>                  Delete entry from primary memory (if backend supports)
        \\  cleanup-test-keys             One-time cleanup of known test keys (markdown + postgres + vectors)
        \\
    , .{});
}

fn parsePositiveUsize(arg: []const u8) ?usize {
    const n = std.fmt.parseInt(usize, arg, 10) catch return null;
    if (n == 0) return null;
    return n;
}

fn isTestMemoryKey(key: []const u8) bool {
    if (std.mem.eql(u8, key, "preferred_transport")) return true;
    if (std.mem.eql(u8, key, "user_preferred_transport")) return true;
    if (std.mem.eql(u8, key, "test_semantic_v2")) return true;
    if (std.mem.eql(u8, key, "test_semantic_v1")) return true;

    const prefixes = [_][]const u8{
        "test_",
        "tool_test",
        "probe_test",
        "runtime_test",
        "diagnostic_test",
        "smoke_",
        "stable_",
        "qa_test",
    };
    inline for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return true;
    }
    return std.mem.indexOf(u8, key, "_test_") != null;
}

fn extractKeyFromMarkdownLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "- **")) return null;
    const rest = line[4..];
    const end = std.mem.indexOf(u8, rest, "**:") orelse return null;
    const key = std.mem.trim(u8, rest[0..end], " \t");
    if (key.len == 0) return null;
    return key;
}

fn addKeyToSet(
    allocator: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
    key: []const u8,
) !void {
    if (set.contains(key)) return;
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    try set.put(allocator, owned, {});
}

fn freeKeySet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.iterator();
    while (it.next()) |kv| allocator.free(@constCast(kv.key_ptr.*));
    set.deinit(allocator);
}

fn collectTestKeysFromMarkdownFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    set: *std.StringHashMapUnmanaged(void),
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 8);
    defer allocator.free(content);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        const key = extractKeyFromMarkdownLine(line) orelse continue;
        if (!isTestMemoryKey(key)) continue;
        try addKeyToSet(allocator, set, key);
    }
}

fn collectTestKeysFromMemoryDir(
    allocator: std.mem.Allocator,
    memory_dir: []const u8,
    set: *std.StringHashMapUnmanaged(void),
) !void {
    var dir = std.fs.openDirAbsolute(memory_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = try std.fs.path.join(allocator, &.{ memory_dir, entry.name });
        defer allocator.free(path);
        try collectTestKeysFromMarkdownFile(allocator, path, set);
    }
}

fn rewriteMarkdownFileRemovingKeys(
    allocator: std.mem.Allocator,
    path: []const u8,
    set: *const std.StringHashMapUnmanaged(void),
) !usize {
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 8);
    defer allocator.free(content);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var removed: usize = 0;
    var first = true;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        var keep = true;
        if (extractKeyFromMarkdownLine(line)) |key| {
            if (set.contains(key)) {
                keep = false;
                removed += 1;
            }
        }
        if (!keep) continue;
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, line);
    }

    if (removed > 0) {
        var out_file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer out_file.close();
        try out_file.writeAll(out.items);
    }
    return removed;
}

fn rewriteMemoryDirRemovingKeys(
    allocator: std.mem.Allocator,
    memory_dir: []const u8,
    set: *const std.StringHashMapUnmanaged(void),
) !usize {
    var dir = std.fs.openDirAbsolute(memory_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    var removed: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = try std.fs.path.join(allocator, &.{ memory_dir, entry.name });
        defer allocator.free(path);
        removed += try rewriteMarkdownFileRemovingKeys(allocator, path, set);
    }
    return removed;
}

fn cleanupTestMemoryKeys(allocator: std.mem.Allocator, cfg: *yc.config.Config) !void {
    if (!std.mem.eql(u8, cfg.state.backend, "postgres")) {
        std.debug.print("State backend is not postgres; cleanup skipped.\n", .{});
        return;
    }

    var mgr = try yc.zaki_state.Manager.init(allocator, cfg.state);
    defer mgr.deinit();

    const users_root = cfg.tenant.data_root;
    var users_dir = std.fs.openDirAbsolute(users_root, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open users root '{s}': {s}\n", .{ users_root, @errorName(err) });
        return;
    };
    defer users_dir.close();

    var vector_store: ?*yc.memory.store_pgvector.PgvectorVectorStore = null;
    if (cfg.state.postgres.connection_string.len > 0) {
        vector_store = yc.memory.store_pgvector.PgvectorVectorStore.init(allocator, .{
            .connection_url = cfg.state.postgres.connection_string,
            .schema_name = if (cfg.memory.search.store.pgvector_schema.len > 0)
                cfg.memory.search.store.pgvector_schema
            else
                cfg.state.postgres.schema,
            .table_name = cfg.memory.search.store.pgvector_table,
            .dimensions = 1024,
        }) catch |err| blk: {
            std.debug.print("Warning: vector store init failed; vector deletes disabled: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }
    defer if (vector_store) |vs| vs.deinit();

    var scanned_users: usize = 0;
    var touched_users: usize = 0;
    var canonical_deleted: usize = 0;
    var vector_delete_attempts: usize = 0;
    var markdown_lines_removed: usize = 0;

    var it = users_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const user_id = std.fmt.parseInt(i64, entry.name, 10) catch continue;
        scanned_users += 1;

        var keys: std.StringHashMapUnmanaged(void) = .empty;
        defer freeKeySet(allocator, &keys);

        const workspace = try std.fs.path.join(allocator, &.{ users_root, entry.name, "workspace" });
        defer allocator.free(workspace);
        const memory_md = try std.fs.path.join(allocator, &.{ workspace, "MEMORY.md" });
        defer allocator.free(memory_md);
        const memory_dir = try std.fs.path.join(allocator, &.{ workspace, "memory" });
        defer allocator.free(memory_dir);

        try collectTestKeysFromMarkdownFile(allocator, memory_md, &keys);
        try collectTestKeysFromMemoryDir(allocator, memory_dir, &keys);

        const entries = mgr.listMemories(allocator, user_id, null, null) catch |err| {
            std.debug.print("Warning: listMemories failed for user {d}: {s}\n", .{ user_id, @errorName(err) });
            continue;
        };
        defer yc.memory.freeEntries(allocator, entries);
        for (entries) |mem_entry| {
            if (isTestMemoryKey(mem_entry.key)) {
                try addKeyToSet(allocator, &keys, mem_entry.key);
            }
        }

        if (keys.count() == 0) continue;
        touched_users += 1;

        var key_it = keys.iterator();
        while (key_it.next()) |kv| {
            const key = kv.key_ptr.*;
            if (mgr.forgetMemory(user_id, key) catch false) canonical_deleted += 1;
            if (vector_store) |vs| {
                vs.store().deleteScoped(user_id, key) catch {};
                vector_delete_attempts += 1;
            }
        }

        markdown_lines_removed += try rewriteMarkdownFileRemovingKeys(allocator, memory_md, &keys);
        markdown_lines_removed += try rewriteMemoryDirRemovingKeys(allocator, memory_dir, &keys);
    }

    std.debug.print(
        "Cleanup complete. scanned_users={d} touched_users={d} canonical_deleted={d} vector_delete_attempts={d} markdown_lines_removed={d}\n",
        .{ scanned_users, touched_users, canonical_deleted, vector_delete_attempts, markdown_lines_removed },
    );
}

fn printMemoryRuntimeInitFailure(allocator: std.mem.Allocator, backend: []const u8) void {
    const enabled = yc.memory.registry.formatEnabledBackends(allocator) catch null;
    defer if (enabled) |names| allocator.free(names);

    if (yc.memory.registry.isKnownBackend(backend) and yc.memory.findBackend(backend) == null) {
        const engine_token = yc.memory.registry.engineTokenForBackend(backend) orelse backend;
        std.debug.print("Memory backend '{s}' is configured but disabled in this build.\n", .{backend});
        std.debug.print("Rebuild with -Dengines={s} (or include it in -Dengines=... list).\n", .{engine_token});
    } else if (!yc.memory.registry.isKnownBackend(backend)) {
        std.debug.print("Unknown memory backend '{s}'.\n", .{backend});
        std.debug.print("Known memory backends: {s}\n", .{yc.memory.registry.known_backends_csv});
    } else {
        std.debug.print("Memory runtime init failed for backend '{s}'. Check memory config and logs.\n", .{backend});
    }

    if (enabled) |names| {
        std.debug.print("Enabled memory backends in this build: {s}\n", .{names});
    }
}

fn printRetrievalScoreLine(c: yc.memory.RetrievalCandidate) void {
    const kw_rank: []const u8 = if (c.keyword_rank != null) "yes" else "no";
    const vec_score: f32 = c.vector_score orelse -1.0;
    if (c.vector_score) |_| {
        std.debug.print("     rrf_score={d:.4} keyword_ranked={s} vector_score={d:.4} source={s}\n", .{
            c.final_score,
            kw_rank,
            vec_score,
            c.source,
        });
    } else {
        std.debug.print("     rrf_score={d:.4} keyword_ranked={s} vector_score=n/a source={s}\n", .{
            c.final_score,
            kw_rank,
            c.source,
        });
    }
}

const MemoryForgetAction = enum {
    missing,
    protected,
    deleted,
    not_deleted,
};

fn forgetMemoryWithValidation(
    allocator: std.mem.Allocator,
    mem: yc.memory.Memory,
    mem_rt: ?*yc.memory.MemoryRuntime,
    key: []const u8,
) !MemoryForgetAction {
    var lookup = try yc.memory.lookupMemoryLifecycleEntry(allocator, mem, key);
    defer lookup.deinit(allocator);

    switch (lookup.status) {
        .missing => return .missing,
        .protected => return .protected,
        .editable => {},
    }

    const deleted = try mem.forget(key);
    if (!deleted) return .not_deleted;
    if (mem_rt) |rt| rt.deleteFromVectorStore(key);
    return .deleted;
}

fn runMemory(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        printMemoryUsage();
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    var cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
        std.process.exit(1);
    };
    defer cfg.deinit();

    if (std.mem.eql(u8, subcmd, "cleanup-test-keys")) {
        cleanupTestMemoryKeys(allocator, &cfg) catch |err| {
            std.debug.print("cleanup-test-keys failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

    var mem_rt = yc.memory.initRuntimeWithOptions(allocator, &cfg.memory, cfg.workspace_dir, .{
        .providers = cfg.providers,
    }) orelse {
        printMemoryRuntimeInitFailure(allocator, cfg.memory.backend);
        std.process.exit(1);
    };
    defer mem_rt.deinit();

    if (std.mem.eql(u8, subcmd, "stats")) {
        const r = mem_rt.resolved;
        const report = mem_rt.diagnose();
        std.debug.print("Memory stats:\n", .{});
        std.debug.print("  backend: {s}\n", .{r.primary_backend});
        std.debug.print("  retrieval: {s}\n", .{r.retrieval_mode});
        std.debug.print("  vector: {s}\n", .{r.vector_mode});
        std.debug.print("  embedding: {s}\n", .{r.embedding_provider});
        std.debug.print("  rollout: {s}\n", .{r.rollout_mode});
        std.debug.print("  sync: {s}\n", .{r.vector_sync_mode});
        std.debug.print("  sources: {d}\n", .{r.source_count});
        std.debug.print("  fallback: {s}\n", .{r.fallback_policy});
        std.debug.print("  entries: {d}\n", .{report.entry_count});
        if (report.vector_entry_count) |n| {
            std.debug.print("  vector_entries: {d}\n", .{n});
        } else {
            std.debug.print("  vector_entries: n/a\n", .{});
        }
        if (report.outbox_pending) |n| {
            std.debug.print("  outbox_pending: {d}\n", .{n});
        } else {
            std.debug.print("  outbox_pending: n/a\n", .{});
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "count")) {
        const count = mem_rt.memory.count() catch |err| {
            std.debug.print("memory count failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("{d}\n", .{count});
        return;
    }

    if (std.mem.eql(u8, subcmd, "reindex")) {
        const count = mem_rt.reindex(allocator);
        if (std.mem.eql(u8, mem_rt.resolved.vector_mode, "none")) {
            std.debug.print("Vector plane is disabled; reindex skipped (0 entries).\n", .{});
        } else {
            std.debug.print("Reindex complete: {d} entries reindexed.\n", .{count});
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "drain-outbox")) {
        const drained = mem_rt.drainOutbox(allocator);
        std.debug.print("Outbox drain complete: {d} operation(s) processed.\n", .{drained});
        return;
    }

    if (std.mem.eql(u8, subcmd, "forget")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis memory forget <key>\n", .{});
            std.process.exit(1);
        }
        const key = sub_args[1];
        const outcome = forgetMemoryWithValidation(allocator, mem_rt.memory, &mem_rt, key) catch |err| {
            std.debug.print("memory forget failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        switch (outcome) {
            .deleted => std.debug.print("Deleted memory entry: {s}\n", .{key}),
            .missing, .not_deleted => std.debug.print("Entry not deleted (missing or backend is append-only): {s}\n", .{key}),
            .protected => std.debug.print("Memory key is not deletable: {s}\n", .{key}),
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "get")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis memory get <key>\n", .{});
            std.process.exit(1);
        }
        const key = sub_args[1];
        const entry = mem_rt.memory.get(allocator, key) catch |err| {
            std.debug.print("memory get failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (entry) |e| {
            defer e.deinit(allocator);
            std.debug.print("key: {s}\ncategory: {s}\ntimestamp: {s}\ncontent:\n{s}\n", .{
                e.key,
                e.category.toString(),
                e.timestamp,
                e.content,
            });
        } else {
            std.debug.print("Not found: {s}\n", .{key});
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "list")) {
        var limit: usize = 20;
        var category_opt: ?yc.memory.MemoryCategory = null;

        var i: usize = 1;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--limit")) {
                if (i + 1 >= sub_args.len) {
                    std.debug.print("Usage: nullalis memory list [--category C] [--limit N]\n", .{});
                    std.process.exit(1);
                }
                i += 1;
                limit = parsePositiveUsize(sub_args[i]) orelse {
                    std.debug.print("Invalid --limit value: {s}\n", .{sub_args[i]});
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, sub_args[i], "--category")) {
                if (i + 1 >= sub_args.len) {
                    std.debug.print("Usage: nullalis memory list [--category C] [--limit N]\n", .{});
                    std.process.exit(1);
                }
                i += 1;
                category_opt = yc.memory.MemoryCategory.fromString(sub_args[i]);
            } else {
                std.debug.print("Unknown option for memory list: {s}\n", .{sub_args[i]});
                std.process.exit(1);
            }
        }

        const entries = mem_rt.memory.list(allocator, category_opt, null) catch |err| {
            std.debug.print("memory list failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer yc.memory.freeEntries(allocator, entries);

        const shown = @min(limit, entries.len);
        std.debug.print("Memory entries: showing {d}/{d}\n", .{ shown, entries.len });
        for (entries[0..shown], 0..) |e, idx| {
            const preview_len = @min(@as(usize, 120), e.content.len);
            const preview = e.content[0..preview_len];
            std.debug.print("  {d}. {s} [{s}] {s}\n     {s}{s}\n", .{
                idx + 1,
                e.key,
                e.category.toString(),
                e.timestamp,
                preview,
                if (e.content.len > preview_len) "..." else "",
            });
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "search")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis memory search <query> [--limit N]\n", .{});
            std.process.exit(1);
        }
        const query = sub_args[1];
        var limit: usize = 6;

        var i: usize = 2;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--limit")) {
                if (i + 1 >= sub_args.len) {
                    std.debug.print("Usage: nullalis memory search <query> [--limit N]\n", .{});
                    std.process.exit(1);
                }
                i += 1;
                limit = parsePositiveUsize(sub_args[i]) orelse {
                    std.debug.print("Invalid --limit value: {s}\n", .{sub_args[i]});
                    std.process.exit(1);
                };
            } else {
                std.debug.print("Unknown option for memory search: {s}\n", .{sub_args[i]});
                std.process.exit(1);
            }
        }

        const results = mem_rt.search(allocator, query, limit, null) catch |err| {
            std.debug.print("memory search failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer yc.memory.retrieval.freeCandidates(allocator, results);

        std.debug.print("Search results: {d}\n", .{results.len});
        for (results, 0..) |c, idx| {
            std.debug.print("  {d}. {s} [{s}]\n", .{ idx + 1, c.key, c.category.toString() });
            printRetrievalScoreLine(c);
            const preview_len = @min(@as(usize, 140), c.snippet.len);
            const preview = c.snippet[0..preview_len];
            std.debug.print("     {s}{s}\n", .{ preview, if (c.snippet.len > preview_len) "..." else "" });
        }
        return;
    }

    std.debug.print("Unknown memory command: {s}\n\n", .{subcmd});
    printMemoryUsage();
    std.process.exit(1);
}

fn runCapabilities(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var as_json = false;
    if (sub_args.len > 0) {
        if (sub_args.len == 1 and (std.mem.eql(u8, sub_args[0], "--json") or std.mem.eql(u8, sub_args[0], "json"))) {
            as_json = true;
        } else {
            std.debug.print("Usage: nullalis capabilities [--json]\n", .{});
            std.process.exit(1);
        }
    }

    var cfg_opt: ?yc.config.Config = yc.config.Config.load(allocator) catch null;
    defer if (cfg_opt) |*cfg| cfg.deinit();
    const cfg_ptr: ?*const yc.config.Config = if (cfg_opt) |*cfg| cfg else null;

    const output = if (as_json)
        try yc.capabilities.buildManifestJson(allocator, cfg_ptr, null)
    else
        try yc.capabilities.buildSummaryText(allocator, cfg_ptr, null);
    defer allocator.free(output);

    std.debug.print("{s}", .{output});
}

// ── Models ───────────────────────────────────────────────────────

fn runModels(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullalis models <command>
            \\
            \\Commands:
            \\  list                          List available models
            \\  info <model>                  Show model details
            \\  benchmark                     Not implemented
            \\  refresh                       Refresh model catalog
            \\
        , .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        var cfg_opt: ?yc.config.Config = yc.config.Config.load(allocator) catch null;
        defer if (cfg_opt) |*c| c.deinit();

        std.debug.print("Current configuration:\n", .{});
        if (cfg_opt) |c| {
            std.debug.print("  Provider: {s}\n", .{c.default_provider});
            std.debug.print("  Model:    {s}\n", .{c.default_model orelse "(not set)"});
            std.debug.print("  Temp:     {d:.1}\n\n", .{c.default_temperature});
        } else {
            std.debug.print("  (no config -- run `nullalis onboard` first)\n\n", .{});
        }

        std.debug.print("Known providers and default models:\n", .{});
        for (yc.onboard.known_providers) |p| {
            std.debug.print("  {s:<12} {s:<36} {s}\n", .{ p.key, p.default_model, p.label });
        }
        std.debug.print("\nUse `nullalis models info <model>` for details.\n", .{});
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullalis models info <model>\n", .{});
            std.process.exit(1);
        }
        std.debug.print("Model: {s}\n", .{sub_args[1]});
        std.debug.print("  Default provider: {s}\n", .{yc.onboard.canonicalProviderName(sub_args[1])});
        std.debug.print("  Context: varies by provider\n", .{});
        std.debug.print("  Pricing: see provider dashboard\n", .{});
    } else if (std.mem.eql(u8, subcmd, "benchmark")) {
        std.debug.print("Not implemented: nullalis models benchmark\n", .{});
        std.debug.print("Use `nullalis models list` and provider dashboards for latency verification.\n", .{});
        std.process.exit(2);
    } else if (std.mem.eql(u8, subcmd, "refresh")) {
        try yc.onboard.runModelsRefresh(allocator);
    } else {
        std.debug.print("Unknown models command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Onboard ──────────────────────────────────────────────────────

const OnboardMode = enum {
    quick,
    interactive,
    channels_only,
};

const OnboardArgs = struct {
    mode: OnboardMode = .quick,
    api_key: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    memory_backend: ?[]const u8 = null,
};

const OnboardArgParseResult = union(enum) {
    ok: OnboardArgs,
    unknown_option: []const u8,
    missing_value: []const u8,
    unexpected_argument: []const u8,
    invalid_combination: void,
};

fn parseOnboardArgs(sub_args: []const []const u8) OnboardArgParseResult {
    var parsed = OnboardArgs{};

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--interactive")) {
            if (parsed.mode == .channels_only) return .{ .invalid_combination = {} };
            parsed.mode = .interactive;
            continue;
        }
        if (std.mem.eql(u8, arg, "--channels-only")) {
            if (parsed.mode == .interactive) return .{ .invalid_combination = {} };
            parsed.mode = .channels_only;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api-key")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            parsed.api_key = sub_args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--provider")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            parsed.provider = sub_args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--memory")) {
            if (i + 1 >= sub_args.len) return .{ .missing_value = arg };
            i += 1;
            parsed.memory_backend = sub_args[i];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            return .{ .unknown_option = arg };
        }
        return .{ .unexpected_argument = arg };
    }

    if (parsed.mode != .quick and
        (parsed.api_key != null or parsed.provider != null or parsed.memory_backend != null))
    {
        return .{ .invalid_combination = {} };
    }

    return .{ .ok = parsed };
}

fn printOnboardUsage() void {
    std.debug.print(
        \\Usage: nullalis onboard [--interactive | --channels-only | [--api-key KEY] [--provider PROV] [--memory MEM]]
        \\
        \\Modes:
        \\  (default)         quick setup
        \\  --interactive     run full interactive wizard
        \\  --channels-only   reconfigure channels and allowlists only
        \\
        \\Quick setup options:
        \\  --api-key KEY     provider API key to persist in config
        \\  --provider PROV   default provider key (e.g. openrouter, anthropic)
        \\  --memory MEM      memory backend key (e.g. markdown, sqlite, memory)
        \\
        \\Examples:
        \\  nullalis onboard --api-key sk-... --provider openrouter
        \\  nullalis onboard --interactive
        \\
    , .{});
}

fn printKnownOnboardProviders() void {
    std.debug.print("Known providers:", .{});
    for (yc.onboard.known_providers) |p| {
        std.debug.print(" {s}", .{p.key});
    }
    std.debug.print("\n", .{});
}

fn printEnabledMemoryBackends(allocator: std.mem.Allocator) void {
    const enabled = yc.memory.registry.formatEnabledBackends(allocator) catch null;
    defer if (enabled) |names| allocator.free(names);

    if (enabled) |names| {
        std.debug.print("Enabled memory backends in this build: {s}\n", .{names});
    }
}

fn runOnboard(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len == 1 and
        (std.mem.eql(u8, sub_args[0], "--help") or std.mem.eql(u8, sub_args[0], "-h")))
    {
        printOnboardUsage();
        return;
    }

    const parsed = switch (parseOnboardArgs(sub_args)) {
        .ok => |args| args,
        .unknown_option => |opt| {
            std.debug.print("Unknown onboard option: {s}\n\n", .{opt});
            printOnboardUsage();
            std.process.exit(1);
        },
        .missing_value => |opt| {
            std.debug.print("Missing value for onboard option: {s}\n\n", .{opt});
            printOnboardUsage();
            std.process.exit(1);
        },
        .unexpected_argument => |arg| {
            std.debug.print("Unexpected positional argument for onboard: {s}\n\n", .{arg});
            printOnboardUsage();
            std.process.exit(1);
        },
        .invalid_combination => {
            std.debug.print("Invalid onboard option combination.\n", .{});
            std.debug.print("Use either --interactive, --channels-only, or quick-setup flags.\n\n", .{});
            printOnboardUsage();
            std.process.exit(1);
        },
    };

    switch (parsed.mode) {
        .channels_only => try yc.onboard.runChannelsOnly(allocator),
        .interactive => try yc.onboard.runWizard(allocator),
        .quick => yc.onboard.runQuickSetup(allocator, parsed.api_key, parsed.provider, parsed.memory_backend) catch |err| switch (err) {
            error.UnknownProvider => {
                const requested = parsed.provider orelse "(missing)";
                std.debug.print("Unknown provider '{s}' for quick setup.\n", .{requested});
                printKnownOnboardProviders();
                std.process.exit(1);
            },
            error.UnknownMemoryBackend => {
                const requested = parsed.memory_backend orelse "(missing)";
                std.debug.print("Unknown memory backend '{s}' for quick setup.\n", .{requested});
                std.debug.print("Known memory backends: {s}\n", .{yc.memory.registry.known_backends_csv});
                printEnabledMemoryBackends(allocator);
                std.process.exit(1);
            },
            error.MemoryBackendDisabledInBuild => {
                const requested = parsed.memory_backend orelse "(missing)";
                const engine_token = yc.memory.registry.engineTokenForBackend(requested) orelse requested;
                std.debug.print("Memory backend '{s}' is disabled in this build.\n", .{requested});
                std.debug.print("Rebuild with -Dengines={s} (or include it in -Dengines=... list).\n", .{engine_token});
                printEnabledMemoryBackends(allocator);
                std.process.exit(1);
            },
            else => return err,
        },
    }
}

// ── Channel Start ────────────────────────────────────────────────
// Usage: nullalis channel start [channel]
// If a channel name is given, start that specific channel.
// Otherwise, start the first available (Telegram first, then Signal).
// To run all configured channels/accounts together, use `nullalis gateway`.

fn canStartFromChannelCommand(channel_id: yc.channel_catalog.ChannelId) bool {
    if (!yc.channel_catalog.isBuildEnabled(channel_id)) return false;
    return switch (channel_id) {
        .cli, .webhook => false,
        else => true,
    };
}

fn printChannelStartSupported() void {
    std.debug.print("Supported:", .{});
    for (yc.channel_catalog.known_channels) |meta| {
        if (!canStartFromChannelCommand(meta.id)) continue;
        std.debug.print(" {s}", .{meta.key});
    }
    std.debug.print("\n", .{});
}

fn dispatchChannelStart(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: *const yc.config.Config,
    meta: yc.channel_catalog.ChannelMeta,
) !void {
    if (!yc.channel_catalog.isBuildEnabled(meta.id)) {
        std.debug.print("{s} channel is disabled in this build.\n", .{meta.label});
        std.debug.print("Rebuild with -Dchannels={s} (or -Dchannels=all).\n", .{meta.key});
        std.process.exit(1);
    }

    switch (meta.id) {
        .telegram => {
            if (config.channels.telegramPrimary()) |tg_config| {
                return runTelegramChannel(allocator, args, config.*, tg_config);
            }
            std.debug.print("Telegram channel is not configured.\n", .{});
            std.process.exit(1);
        },
        .signal => {
            if (config.channels.signalPrimary()) |sig_config| {
                return runSignalChannel(allocator, args, config, sig_config);
            }
            std.debug.print("Signal channel is not configured.\n", .{});
            std.process.exit(1);
        },
        .matrix => {
            if (config.channels.matrixPrimary()) |mx_config| {
                return runMatrixChannel(allocator, args, config, mx_config);
            }
            std.debug.print("Matrix channel is not configured.\n", .{});
            std.process.exit(1);
        },
        else => return runGatewayChannel(allocator, config, meta.key),
    }
}

fn hasConfiguredStartableChannels(config: *const yc.config.Config) bool {
    for (yc.channel_catalog.known_channels) |meta| {
        if (!canStartFromChannelCommand(meta.id)) continue;
        if (yc.channel_catalog.isConfigured(config, meta.id)) return true;
    }
    return false;
}

fn hasConfiguredButBuildDisabledStartableChannels(config: *const yc.config.Config) bool {
    for (yc.channel_catalog.known_channels) |meta| {
        if (meta.id == .cli or meta.id == .webhook) continue;
        if (yc.channel_catalog.isBuildEnabled(meta.id)) continue;
        if (yc.channel_catalog.configuredCount(config, meta.id) > 0) return true;
    }
    return false;
}

fn printConfiguredButBuildDisabledChannelsHint(config: *const yc.config.Config) void {
    std.debug.print("Configured channels are disabled in this build:", .{});
    var first: bool = true;
    for (yc.channel_catalog.known_channels) |meta| {
        if (meta.id == .cli or meta.id == .webhook) continue;
        if (yc.channel_catalog.isBuildEnabled(meta.id)) continue;
        if (yc.channel_catalog.configuredCount(config, meta.id) == 0) continue;
        if (first) {
            std.debug.print(" {s}", .{meta.key});
            first = false;
        } else {
            std.debug.print(", {s}", .{meta.key});
        }
    }
    std.debug.print("\n", .{});
    std.debug.print("Rebuild with -Dchannels=all or -Dchannels=", .{});
    first = true;
    for (yc.channel_catalog.known_channels) |meta| {
        if (meta.id == .cli or meta.id == .webhook) continue;
        if (yc.channel_catalog.isBuildEnabled(meta.id)) continue;
        if (yc.channel_catalog.configuredCount(config, meta.id) == 0) continue;
        if (first) {
            std.debug.print("{s}", .{meta.key});
            first = false;
        } else {
            std.debug.print(",{s}", .{meta.key});
        }
    }
    std.debug.print("\n", .{});
}

fn printNoMessagingChannelConfiguredHint() void {
    std.debug.print("No messaging channel configured. Add to config.json:\n", .{});
    std.debug.print("  Telegram: {{\"channels\": {{\"telegram\": {{\"accounts\": {{\"main\": {{\"bot_token\": \"...\"}}}}}}}}\n", .{});
    std.debug.print("  Signal:   {{\"channels\": {{\"signal\": {{\"accounts\": {{\"main\": {{\"http_url\": \"http://127.0.0.1:8080\", \"account\": \"+1234567890\"}}}}}}}}\n", .{});
}

fn runChannelStart(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--all")) {
        std.debug.print("Use `nullalis gateway` to start all configured channels/accounts.\n", .{});
        std.process.exit(1);
    }

    // Load config
    var config = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullalis onboard` first\n", .{});
        std.process.exit(1);
    };
    defer config.deinit();

    config.validate() catch |err| {
        yc.config.Config.printValidationError(err);
        std.process.exit(1);
    };

    if (!hasConfiguredStartableChannels(&config)) {
        if (hasConfiguredButBuildDisabledStartableChannels(&config)) {
            printConfiguredButBuildDisabledChannelsHint(&config);
        } else {
            printNoMessagingChannelConfiguredHint();
        }
        std.process.exit(1);
    }

    // Check if user specified a channel name
    const requested: ?[]const u8 = if (args.len > 0) args[0] else null;

    if (requested) |ch_name| {
        const meta = yc.channel_catalog.findByKey(ch_name) orelse {
            std.debug.print("Unknown channel: {s}\n", .{ch_name});
            printChannelStartSupported();
            std.process.exit(1);
        };
        if (!yc.channel_catalog.isBuildEnabled(meta.id)) {
            const configured = yc.channel_catalog.configuredCount(&config, meta.id);
            if (configured > 0) {
                std.debug.print("Channel {s} is configured ({d} account(s)) but disabled in this build.\n", .{ meta.key, configured });
            } else {
                std.debug.print("Channel {s} is disabled in this build.\n", .{meta.key});
            }
            std.debug.print("Rebuild with -Dchannels={s} (or -Dchannels=all).\n", .{meta.key});
            printChannelStartSupported();
            std.process.exit(1);
        }
        if (!canStartFromChannelCommand(meta.id)) {
            std.debug.print("Channel {s} cannot be started via `channel start`.\n", .{ch_name});
            printChannelStartSupported();
            std.process.exit(1);
        }
        if (!yc.channel_catalog.isConfigured(&config, meta.id)) {
            std.debug.print("{s} channel is not configured.\n", .{meta.label});
            std.process.exit(1);
        }

        const child_args: []const []const u8 = if (args.len > 1) args[1..] else &.{};
        return dispatchChannelStart(allocator, child_args, &config, meta);
    }

    // No channel specified -- keep historical preference:
    // Telegram first, then Signal, then any other configured channel.
    if (yc.channel_catalog.findByKey("telegram")) |meta| {
        if (yc.channel_catalog.isConfigured(&config, meta.id)) {
            return dispatchChannelStart(allocator, args, &config, meta);
        }
    }
    if (yc.channel_catalog.findByKey("signal")) |meta| {
        if (yc.channel_catalog.isConfigured(&config, meta.id)) {
            return dispatchChannelStart(allocator, args, &config, meta);
        }
    }

    for (yc.channel_catalog.known_channels) |meta| {
        if (!canStartFromChannelCommand(meta.id)) continue;
        if (meta.id == .telegram or meta.id == .signal) continue;
        if (!yc.channel_catalog.isConfigured(&config, meta.id)) continue;
        return dispatchChannelStart(allocator, args, &config, meta);
    }
}

/// Start a single configured non-polling channel using ChannelManager.
fn runGatewayChannel(allocator: std.mem.Allocator, config: *const yc.config.Config, ch_name: []const u8) !void {
    var registry = yc.channels.dispatch.ChannelRegistry.init(allocator);
    defer registry.deinit();

    const mgr = try yc.channel_manager.ChannelManager.init(allocator, config, &registry);
    defer mgr.deinit();

    try mgr.collectConfiguredChannels();

    // Find and start only the requested channel
    var found = false;
    for (mgr.channelEntries()) |entry| {
        if (std.mem.eql(u8, entry.name, ch_name)) {
            entry.channel.start() catch |err| {
                std.debug.print("{s} channel failed to start: {}\n", .{ ch_name, err });
                std.process.exit(1);
            };
            found = true;
            break;
        }
    }

    if (!found) {
        std.debug.print("{s} channel is not configured.\n", .{ch_name});
        std.process.exit(1);
    }

    std.debug.print("{s} channel started. Press Ctrl+C to stop.\n", .{ch_name});

    // Block until Ctrl+C
    while (!yc.daemon.isShutdownRequested()) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

const StandaloneCompletionChannelDispatch = struct {
    channel: yc.channels.Channel,

    fn dispatch(ctx: ?*anyopaque, outbound: *const yc.bus.OutboundMessage) anyerror!void {
        const self: *StandaloneCompletionChannelDispatch = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, self.channel.name(), outbound.channel)) {
            return error.ChannelMismatch;
        }
        try self.channel.send(outbound.chat_id, outbound.content, outbound.media);
    }
};

// ── Signal Channel ─────────────────────────────────────────────────

fn hasReliabilityCredentialFallback(allocator: std.mem.Allocator, config: *const yc.config.Config) bool {
    for (config.reliability.api_keys) |raw_key| {
        if (std.mem.trim(u8, raw_key, " \t\r\n").len > 0) return true;
    }

    for (config.reliability.fallback_providers) |provider_name| {
        if (yc.providers.classifyProvider(provider_name) == .openai_codex_provider) return true;

        const resolved = yc.providers.resolveApiKeyFromConfig(
            allocator,
            provider_name,
            config.providers,
        ) catch null;
        defer if (resolved) |k| allocator.free(k);

        if (resolved) |key| {
            if (std.mem.trim(u8, key, " \t\r\n").len > 0) return true;
        }
    }

    return false;
}

fn runSignalChannel(allocator: std.mem.Allocator, args: []const []const u8, config: *const yc.config.Config, signal_config: yc.config.SignalConfig) !void {
    _ = args;
    if (!build_options.enable_channel_signal) {
        std.debug.print("Signal channel is disabled in this build.\n", .{});
        std.process.exit(1);
    }

    // Resolve API key: config providers first, then env vars (ANTHROPIC_API_KEY, etc.)
    const resolved_api_key = yc.providers.resolveApiKeyFromConfig(
        allocator,
        config.default_provider,
        config.providers,
    ) catch null;
    defer if (resolved_api_key) |k| allocator.free(k);

    // OAuth providers (openai-codex) don't need an API key
    const provider_kind = yc.providers.classifyProvider(config.default_provider);
    const has_fallback_credentials = hasReliabilityCredentialFallback(allocator, config);
    if (resolved_api_key == null and provider_kind != .openai_codex_provider and !has_fallback_credentials) {
        std.debug.print("No API key configured. Set env var or add to ~/.nullalis/config.json:\n", .{});
        std.debug.print("  \"providers\": {{ \"{s}\": {{ \"api_key\": \"...\" }} }}\n", .{config.default_provider});
        std.process.exit(1);
    }

    const temperature = config.default_temperature;

    std.debug.print("nullalis Signal bot starting...\n", .{});
    config.printModelConfig();
    std.debug.print("  Temperature: {d:.1}\n", .{temperature});
    std.debug.print("  Signal URL: {s}\n", .{signal_config.http_url});
    std.debug.print("  Account: {s}\n", .{signal_config.account});
    if (signal_config.allow_from.len == 0) {
        std.debug.print("  Allowed users: (none — all messages will be denied)\n", .{});
    } else if (signal_config.allow_from.len == 1 and std.mem.eql(u8, signal_config.allow_from[0], "*")) {
        std.debug.print("  Allowed users: *\n", .{});
    } else {
        std.debug.print("  Allowed users:", .{});
        for (signal_config.allow_from) |u| {
            std.debug.print(" {s}", .{u});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("  Group policy: {s}\n", .{signal_config.group_policy});
    if (signal_config.group_allow_from.len == 0) {
        std.debug.print("  Group allowed senders: (fallback to allow_from)\n", .{});
    } else if (signal_config.group_allow_from.len == 1 and std.mem.eql(u8, signal_config.group_allow_from[0], "*")) {
        std.debug.print("  Group allowed senders: *\n", .{});
    } else {
        std.debug.print("  Group allowed senders:", .{});
        for (signal_config.group_allow_from) |g| {
            std.debug.print(" {s}", .{g});
        }
        std.debug.print("\n", .{});
    }

    // Env overrides for Signal
    const env_http_url = std.process.getEnvVarOwned(allocator, "SIGNAL_HTTP_URL") catch null;
    defer if (env_http_url) |v| allocator.free(v);
    const env_account = std.process.getEnvVarOwned(allocator, "SIGNAL_ACCOUNT") catch null;
    defer if (env_account) |v| allocator.free(v);
    const effective_http_url = env_http_url orelse signal_config.http_url;
    const effective_account = env_account orelse signal_config.account;

    var sg = yc.channels.signal.SignalChannel.init(
        allocator,
        effective_http_url,
        effective_account,
        signal_config.allow_from,
        signal_config.group_allow_from,
        signal_config.ignore_attachments,
        signal_config.ignore_stories,
    );
    sg.group_policy = signal_config.group_policy;
    sg.account_id = signal_config.account_id;

    // Verify health
    if (!sg.healthCheck()) {
        std.debug.print("Signal health check failed. Is signal-cli daemon running?\n", .{});
        std.debug.print("  Run: signal-cli --account {s} daemon --http 127.0.0.1:8080\n", .{signal_config.account});
        std.process.exit(1);
    }

    std.debug.print("  Polling for messages... (Ctrl+C to stop)\n\n", .{});

    // Initialize MCP tools from config
    const mcp_tools: ?[]const yc.tools.Tool = if (config.mcp_servers.len > 0)
        yc.mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
            std.debug.print("  MCP: init failed: {}\n", .{err});
            break :blk null;
        }
    else
        null;
    defer if (mcp_tools) |mt| allocator.free(mt);

    // Build security policy from config
    const security = @import("nullalis").security.policy;
    var tracker = security.RateTracker.init(allocator, config.autonomy.max_actions_per_hour);
    defer tracker.deinit();

    var sec_policy = security.SecurityPolicy{
        .autonomy = config.autonomy.level,
        .workspace_dir = config.workspace_dir,
        .workspace_only = config.autonomy.workspace_only,
        .allowed_commands = if (config.autonomy.allowed_commands.len > 0) config.autonomy.allowed_commands else &security.default_allowed_commands,
        .max_actions_per_hour = config.autonomy.max_actions_per_hour,
        .require_approval_for_medium_risk = config.autonomy.require_approval_for_medium_risk,
        .block_high_risk_commands = config.autonomy.block_high_risk_commands,
        .tracker = &tracker,
    };

    var subagent_manager = yc.subagent.SubagentManager.init(allocator, config, null, .{});
    defer subagent_manager.deinit();
    // V1.14.4 review F-1 — wire CLI completion delivery so subagent
    // results surface to stderr instead of vanishing into the path=none
    // discard branch (subagent.zig:709). Closes the original symptom of
    // project_subagent_received_bug for CLI users.
    subagent_manager.attachCompletionDelivery(null, cliSubagentCompletionDelivery);

    // Create tools (for system prompt and tool calling)
    const tools = yc.tools.allTools(allocator, config.workspace_dir, .{
        .config = config,
        .http_enabled = config.http_request.enabled,
        .browser_enabled = config.browser.enabled,
        .screenshot_enabled = true,
        .composio_api_key = if (config.composio.enabled) config.composio.api_key else null,
        .browser_open_domains = if (config.browser.allowed_domains.len > 0) config.browser.allowed_domains else null,
        .mcp_tools = mcp_tools,
        .agents = config.agents,
        .fallback_api_key = resolved_api_key,
        .tools_config = config.tools,
        .allowed_paths = config.autonomy.allowed_paths,
        .policy = &sec_policy,
        .subagent_manager = &subagent_manager,
    }) catch &.{};
    defer if (tools.len > 0) yc.tools.deinitTools(allocator, tools);

    if (mcp_tools) |mt| {
        std.debug.print("  MCP tools: {d}\n", .{mt.len});
    }

    // Create optional memory backend (don't fail if unavailable)
    var mem_rt = yc.memory.initRuntimeWithOptions(allocator, &config.memory, config.workspace_dir, .{
        .providers = config.providers,
        .search_api_key_override = resolved_api_key,
    });
    defer if (mem_rt) |*rt| rt.deinit();
    const mem_opt: ?yc.memory.Memory = if (mem_rt) |rt| rt.memory else null;

    // Wire MemoryRuntime into tools for retrieval pipeline + vector sync
    if (mem_rt) |*rt| {
        yc.tools.bindMemoryRuntime(tools, rt);
    }
    // iter27: transcript_read SessionStore binding (standalone path)
    yc.tools.bindSessionStore(tools, if (mem_rt) |rt| rt.session_store else null);
    // N1: image_generate Together key (standalone)
    yc.tools.bindImageGenerate(tools, yc.tools.lookupProviderApiKey(config.providers, "together"), "");

    // Create provider with reliability wrapper (retry + fallback chains).
    var runtime_provider = try yc.providers.runtime_bundle.RuntimeProviderBundle.init(allocator, config);
    defer runtime_provider.deinit();
    const provider_i = runtime_provider.provider();

    // Create noop observer
    var noop_obs = yc.observability.NoopObserver{};
    const obs = noop_obs.observer();

    // Initialize session manager
    var session_mgr = yc.session.SessionManager.init(allocator, config, provider_i, tools, mem_opt, obs, if (mem_rt) |rt| rt.session_store else null, if (mem_rt) |*rt| rt.response_cache else null);
    session_mgr.policy = &sec_policy;
    if (mem_rt) |*rt| {
        session_mgr.mem_rt = rt;
    }
    defer session_mgr.deinit();

    // Session key buffer
    var key_buf: [128]u8 = undefined;

    // Message loop: poll → full agent loop (tool calling) → reply
    while (true) {
        const messages = sg.pollMessages(allocator) catch |err| {
            std.debug.print("Signal poll error: {}\n", .{err});
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        for (messages) |msg| {
            std.debug.print("[{s}] {s}: {s}\n", .{ msg.channel, msg.id, msg.content });

            // Session key — resolve through route engine, fallback to legacy key.
            const group_peer_id = yc.channels.signal.signalGroupPeerId(msg.reply_target);
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);
            const session_key = blk: {
                const route = yc.agent_routing.resolveRouteWithSession(
                    allocator,
                    .{
                        .channel = "signal",
                        .account_id = sg.account_id,
                        .peer = .{
                            .kind = if (msg.is_group) .group else .direct,
                            .id = if (msg.is_group) group_peer_id else msg.sender,
                        },
                    },
                    config.agent_bindings,
                    config.agents,
                    config.session,
                ) catch break :blk if (msg.is_group)
                    std.fmt.bufPrint(&key_buf, "signal:{s}:group:{s}:{s}", .{
                        sg.account_id,
                        group_peer_id,
                        msg.sender,
                    }) catch msg.sender
                else
                    std.fmt.bufPrint(&key_buf, "signal:{s}:{s}", .{ sg.account_id, msg.sender }) catch msg.sender;
                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            // Build conversation context for Signal (includes sender UUID and group ID)
            const conversation_context: ?yc.agent.ConversationContext = if (std.mem.eql(u8, msg.channel, "signal")) blk: {
                break :blk .{
                    .channel = "signal",
                    .sender_number = if (msg.sender.len > 0 and msg.sender[0] == '+') msg.sender else null,
                    .sender_uuid = msg.sender_uuid,
                    .group_id = msg.group_id,
                    .is_group = msg.is_group,
                };
            } else null;

            const reply = session_mgr.processMessage(session_key, msg.content, conversation_context) catch |err| {
                std.debug.print("  Agent error: {}\n", .{err});
                const err_msg = switch (err) {
                    error.Timeout => "The model request timed out. Please try again.",
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.",
                    error.NoResponseContent => "Model returned an empty response. Please retry or /new for a fresh session.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again or /new for a fresh session.",
                };
                if (msg.reply_target) |target| {
                    sg.sendMessage(target, err_msg, &.{}) catch |send_err| std.debug.print("  Send error: {}\n", .{send_err});
                }
                continue;
            };
            defer allocator.free(reply);

            std.debug.print("  -> {s}\n", .{reply});

            // Reply on Signal; handles split
            if (msg.reply_target) |target| {
                sg.sendMessage(target, reply, &.{}) catch |err| {
                    std.debug.print("  Send error: {}\n", .{err});
                };
            }
        }

        if (messages.len > 0) {
            // Free message memory
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        // Small delay between polls
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

// ── Matrix Channel ────────────────────────────────────────────────

fn runMatrixChannel(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: *const yc.config.Config,
    matrix_config: yc.config.MatrixConfig,
) !void {
    _ = args;
    if (!build_options.enable_channel_matrix) {
        std.debug.print("Matrix channel is disabled in this build.\n", .{});
        std.process.exit(1);
    }

    var mx = yc.channels.matrix.MatrixChannel.initFromConfig(allocator, matrix_config);

    std.debug.print("nullalis Matrix bot starting...\n", .{});
    std.debug.print("  Provider: {s}\n", .{config.default_provider});
    std.debug.print("  Homeserver: {s}\n", .{mx.homeserver});
    std.debug.print("  Account ID: {s}\n", .{mx.account_id});
    std.debug.print("  Room: {s}\n", .{mx.room_id});
    std.debug.print("  Group policy: {s}\n", .{mx.group_policy});
    if (mx.group_allow_from.len == 0) {
        std.debug.print("  Group allowed senders: (fallback to allow_from)\n", .{});
    } else if (mx.group_allow_from.len == 1 and std.mem.eql(u8, mx.group_allow_from[0], "*")) {
        std.debug.print("  Group allowed senders: *\n", .{});
    } else {
        std.debug.print("  Group allowed senders:", .{});
        for (mx.group_allow_from) |entry| {
            std.debug.print(" {s}", .{entry});
        }
        std.debug.print("\n", .{});
    }

    if (!mx.healthCheck()) {
        std.debug.print("Matrix health check failed. Verify homeserver/access_token.\n", .{});
        std.process.exit(1);
    }

    std.debug.print("  Polling for messages... (Ctrl+C to stop)\n\n", .{});

    const runtime = yc.channel_loop.ChannelRuntime.init(allocator, config, null) catch |err| {
        std.debug.print("Runtime init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer runtime.deinit();

    var completion_dispatch = StandaloneCompletionChannelDispatch{ .channel = mx.channel() };
    runtime.attachCompletionOutboundDispatch(@ptrCast(&completion_dispatch), StandaloneCompletionChannelDispatch.dispatch);

    var loop_state = yc.channel_loop.MatrixLoopState.init();
    yc.channel_loop.runMatrixLoop(allocator, config, runtime, &loop_state, &mx);
}

// ── Telegram Channel ───────────────────────────────────────────────-

fn runTelegramChannel(allocator: std.mem.Allocator, args: []const []const u8, config: yc.config.Config, telegram_config: yc.config.TelegramConfig) !void {
    if (!build_options.enable_channel_telegram) {
        std.debug.print("Telegram channel is disabled in this build.\n", .{});
        std.process.exit(1);
    }

    // Determine allowed users: --user CLI args override config allow_from
    var user_list: std.ArrayList([]const u8) = .empty;
    defer user_list.deinit(allocator);
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--user") and i + 1 < args.len) {
                i += 1;
                user_list.append(allocator, args[i]) catch |err| log.err("failed to append user: {}", .{err});
            }
        }
    }
    const allowed: []const []const u8 = if (user_list.items.len > 0)
        user_list.items
    else
        telegram_config.allow_from;

    // Resolve API key: config providers first, then env vars (ANTHROPIC_API_KEY, etc.)
    const resolved_api_key = yc.providers.resolveApiKeyFromConfig(
        allocator,
        config.default_provider,
        config.providers,
    ) catch null;
    defer if (resolved_api_key) |k| allocator.free(k);

    // OAuth providers (openai-codex) don't need an API key
    const provider_kind = yc.providers.classifyProvider(config.default_provider);
    const has_fallback_credentials = hasReliabilityCredentialFallback(allocator, &config);
    if (resolved_api_key == null and provider_kind != .openai_codex_provider and !has_fallback_credentials) {
        std.debug.print("No API key configured. Set env var or add to ~/.nullalis/config.json:\n", .{});
        std.debug.print("  \"providers\": {{ \"{s}\": {{ \"api_key\": \"...\" }} }}\n", .{config.default_provider});
        std.process.exit(1);
    }

    const model = config.default_model.?;
    const temperature = config.default_temperature;

    std.debug.print("nullalis telegram bot starting...\n", .{});
    std.debug.print("  Provider: {s}\n", .{config.default_provider});
    std.debug.print("  Model: {s}\n", .{model});
    std.debug.print("  Temperature: {d:.1}\n", .{temperature});
    if (allowed.len == 0) {
        std.debug.print("  Allowed users: (none — all messages will be denied)\n", .{});
    } else if (allowed.len == 1 and std.mem.eql(u8, allowed[0], "*")) {
        std.debug.print("  Allowed users: *\n", .{});
    } else {
        std.debug.print("  Allowed users:", .{});
        for (allowed) |u| {
            std.debug.print(" {s}", .{u});
        }
        std.debug.print("\n", .{});
    }

    var tg = yc.channels.telegram.TelegramChannel.init(allocator, telegram_config.bot_token, allowed, telegram_config.group_allow_from, telegram_config.group_policy);
    tg.proxy = telegram_config.proxy;
    tg.account_id = telegram_config.account_id;

    // Set up transcription — key comes from providers.{audio_media.provider}
    const trans = config.audio_media;
    const whisper_ptr: ?*yc.voice.WhisperTranscriber = blk: {
        if (!trans.enabled) break :blk null;
        if (config.getProviderKey(trans.provider)) |key| {
            const wt = try allocator.create(yc.voice.WhisperTranscriber);
            wt.* = .{
                .endpoint = yc.voice.resolveTranscriptionEndpoint(trans.provider, trans.base_url),
                .api_key = key,
                .model = trans.model,
                .language = trans.language,
            };
            break :blk wt;
        }
        break :blk null;
    };
    defer if (whisper_ptr) |wt| allocator.destroy(wt);
    if (whisper_ptr) |wt| {
        tg.transcriber = wt.transcriber();
        yc.voice.markTelegramTranscriberConfigured();
    }

    // Initialize MCP tools from config
    const mcp_tools: ?[]const yc.tools.Tool = if (config.mcp_servers.len > 0)
        yc.mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
            std.debug.print("  MCP: init failed: {}\n", .{err});
            break :blk null;
        }
    else
        null;
    defer if (mcp_tools) |mt| allocator.free(mt);

    // Build security policy from config
    const security = @import("nullalis").security.policy;
    var tracker = security.RateTracker.init(allocator, config.autonomy.max_actions_per_hour);
    defer tracker.deinit();

    var sec_policy = security.SecurityPolicy{
        .autonomy = config.autonomy.level,
        .workspace_dir = config.workspace_dir,
        .workspace_only = config.autonomy.workspace_only,
        .allowed_commands = if (config.autonomy.allowed_commands.len > 0) config.autonomy.allowed_commands else &security.default_allowed_commands,
        .max_actions_per_hour = config.autonomy.max_actions_per_hour,
        .require_approval_for_medium_risk = config.autonomy.require_approval_for_medium_risk,
        .block_high_risk_commands = config.autonomy.block_high_risk_commands,
        .tracker = &tracker,
    };

    var subagent_manager = yc.subagent.SubagentManager.init(allocator, &config, null, .{});
    defer subagent_manager.deinit();
    // V1.14.4 review F-1 — same CLI completion delivery wire-up as the
    // standalone-run path above. Closes project_subagent_received_bug
    // for the service-mode CLI entry point as well.
    subagent_manager.attachCompletionDelivery(null, cliSubagentCompletionDelivery);

    // Create tools (for system prompt and tool calling)
    const tools = yc.tools.allTools(allocator, config.workspace_dir, .{
        .config = &config,
        .http_enabled = config.http_request.enabled,
        .browser_enabled = config.browser.enabled,
        .screenshot_enabled = true,
        .composio_api_key = if (config.composio.enabled) config.composio.api_key else null,
        .browser_open_domains = if (config.browser.allowed_domains.len > 0) config.browser.allowed_domains else null,
        .mcp_tools = mcp_tools,
        .agents = config.agents,
        .fallback_api_key = resolved_api_key,
        .tools_config = config.tools,
        .allowed_paths = config.autonomy.allowed_paths,
        .policy = &sec_policy,
        .subagent_manager = &subagent_manager,
    }) catch &.{};
    defer if (tools.len > 0) yc.tools.deinitTools(allocator, tools);

    if (mcp_tools) |mt| {
        std.debug.print("  MCP tools: {d}\n", .{mt.len});
    }

    // Create optional memory backend (don't fail if unavailable)
    var mem_rt = yc.memory.initRuntimeWithOptions(allocator, &config.memory, config.workspace_dir, .{
        .providers = config.providers,
        .search_api_key_override = resolved_api_key,
    });
    defer if (mem_rt) |*rt| rt.deinit();
    const mem_opt: ?yc.memory.Memory = if (mem_rt) |rt| rt.memory else null;

    // Wire MemoryRuntime into tools for retrieval pipeline + vector sync
    if (mem_rt) |*rt| {
        yc.tools.bindMemoryRuntime(tools, rt);
    }
    // iter27: transcript_read SessionStore binding
    yc.tools.bindSessionStore(tools, if (mem_rt) |rt| rt.session_store else null);
    // N1: image_generate Together key
    yc.tools.bindImageGenerate(tools, yc.tools.lookupProviderApiKey(config.providers, "together"), "");

    // Create noop observer
    var noop_obs = yc.observability.NoopObserver{};
    const obs = noop_obs.observer();

    // Create provider with reliability wrapper (retry + fallback chains).
    var runtime_provider = try yc.providers.runtime_bundle.RuntimeProviderBundle.init(allocator, &config);
    defer runtime_provider.deinit();
    const provider_i: yc.providers.Provider = runtime_provider.provider();

    std.debug.print("  Tools: {d} loaded\n", .{tools.len});
    std.debug.print("  Memory: {s}\n", .{if (mem_opt != null) "enabled" else "disabled"});

    // Register bot commands in Telegram's "/" menu
    tg.setMyCommands();

    // Skip messages accumulated while bot was offline
    tg.dropPendingUpdates();

    std.debug.print("  Polling for messages... (Ctrl+C to stop)\n\n", .{});

    var session_mgr = yc.session.SessionManager.init(allocator, &config, provider_i, tools, mem_opt, obs, if (mem_rt) |rt| rt.session_store else null, if (mem_rt) |*rt| rt.response_cache else null);
    session_mgr.policy = &sec_policy;
    if (mem_rt) |*rt| {
        session_mgr.mem_rt = rt;
    }
    defer session_mgr.deinit();

    var evict_counter: u32 = 0;

    // Bot loop: poll → full agent loop (tool calling) → reply
    while (true) {
        const messages = tg.pollUpdates(allocator) catch |err| {
            std.debug.print("Poll error: {}\n", .{err});
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        for (messages) |msg| {
            std.debug.print("[{s}] {s}: {s}\n", .{ msg.channel, msg.id, msg.content });

            // Handle /start command (Telegram-specific greeting, not sent to LLM)
            const trimmed_content = std.mem.trim(u8, msg.content, " \t\r\n");
            if (std.mem.eql(u8, trimmed_content, "/start")) {
                var greeting_buf: [512]u8 = undefined;
                const name = msg.first_name orelse msg.id;
                const greeting = std.fmt.bufPrint(&greeting_buf, "Hello, {s}! I'm nullALIS.\n\nModel: {s}\nType /help for available commands.", .{ name, model }) catch "Hello! I'm nullALIS. Type /help for commands.";
                tg.sendMessageWithReply(msg.sender, greeting, msg.message_id) catch |err| log.err("failed to send /start reply: {}", .{err});
                continue;
            }

            // Determine reply-to: always in groups, configurable in private chats
            const use_reply_to = msg.is_group or telegram_config.reply_in_private;
            const reply_to_id: ?i64 = if (use_reply_to) msg.message_id else null;

            // Session key — resolve through route engine, fallback to legacy key.
            var key_buf: [128]u8 = undefined;
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);
            const session_key = blk: {
                const route = yc.agent_routing.resolveRouteWithSession(
                    allocator,
                    .{
                        .channel = "telegram",
                        .account_id = tg.account_id,
                        .peer = .{
                            .kind = if (msg.is_group) .group else .direct,
                            .id = msg.sender,
                        },
                    },
                    config.agent_bindings,
                    config.agents,
                    config.session,
                ) catch break :blk std.fmt.bufPrint(&key_buf, "telegram:{s}:{s}", .{ tg.account_id, msg.sender }) catch msg.sender;
                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            // Start periodic typing indicator while the model is processing
            const typing_target = msg.sender;
            tg.startTyping(typing_target) catch {};
            defer tg.stopTyping(typing_target) catch {};

            const reply = session_mgr.processMessage(session_key, msg.content, null) catch |err| {
                std.debug.print("  Agent error: {}\n", .{err});
                const err_msg = switch (err) {
                    error.Timeout => "The model request timed out. Please try again.",
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.",
                    error.NoResponseContent => "Model returned an empty response. Please retry or /new for a fresh session.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again or /new for a fresh session.",
                };
                tg.sendMessageWithReply(msg.sender, err_msg, reply_to_id) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
                continue;
            };
            defer allocator.free(reply);

            std.debug.print("  -> {s}\n", .{reply});

            // Reply on telegram; handles [IMAGE:path] markers + split
            tg.sendMessageWithReply(msg.sender, reply, reply_to_id) catch |err| {
                std.debug.print("  Send error: {}\n", .{err});
            };
        }

        if (messages.len > 0) {
            // Free message memory
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        // Periodically evict sessions idle longer than the configured timeout
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }
    }
}

// ── Auth ─────────────────────────────────────────────────────────

fn runAuth(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 2) {
        printAuthUsage();
        std.process.exit(1);
    }

    const subcmd = sub_args[0];
    const provider_name = sub_args[1];
    const rest = sub_args[2..];

    // Resolve provider-specific constants
    const codex = yc.providers.openai_codex;
    const auth_mod = yc.auth;

    if (!std.mem.eql(u8, provider_name, "openai-codex")) {
        std.debug.print("Unknown auth provider: {s}\n\n", .{provider_name});
        std.debug.print("Available providers:\n", .{});
        std.debug.print("  openai-codex    ChatGPT Plus/Pro subscription (OAuth)\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, subcmd, "login")) {
        var import_codex = false;
        for (rest) |arg| {
            if (std.mem.eql(u8, arg, "--import-codex")) import_codex = true;
        }

        if (import_codex) {
            runAuthImportCodex(allocator, codex, auth_mod);
        } else {
            runAuthDeviceCodeLogin(allocator, codex, auth_mod);
        }
    } else if (std.mem.eql(u8, subcmd, "status")) {
        if (auth_mod.loadCredential(allocator, codex.CREDENTIAL_KEY) catch null) |token| {
            defer token.deinit(allocator);
            std.debug.print("openai-codex: authenticated\n", .{});
            if (token.expires_at != 0) {
                const remaining = token.expires_at - std.time.timestamp();
                if (remaining > 0) {
                    std.debug.print("  Token expires in: {d}h {d}m\n", .{
                        @divTrunc(remaining, 3600),
                        @divTrunc(@mod(remaining, 3600), 60),
                    });
                } else {
                    std.debug.print("  Token: expired (will auto-refresh)\n", .{});
                }
            }
            if (token.refresh_token != null) {
                std.debug.print("  Refresh token: present\n", .{});
            }
            const account_id = codex.extractAccountIdFromJwt(allocator, token.access_token) catch null;
            defer if (account_id) |id| allocator.free(id);
            if (account_id) |id| {
                std.debug.print("  Account: {s}\n", .{id});
            }
        } else {
            std.debug.print("openai-codex: not authenticated\n", .{});
            std.debug.print("  Run `nullalis auth login openai-codex` to authenticate.\n", .{});
        }
    } else if (std.mem.eql(u8, subcmd, "logout")) {
        if (auth_mod.deleteCredential(allocator, codex.CREDENTIAL_KEY) catch false) {
            std.debug.print("openai-codex: credentials removed.\n", .{});
        } else {
            std.debug.print("openai-codex: no credentials found.\n", .{});
        }
    } else {
        std.debug.print("Unknown auth command: {s}\n\n", .{subcmd});
        printAuthUsage();
        std.process.exit(1);
    }
}

// ── Update ─────────────────────────────────────────────────────────

fn runUpdate(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var opts = yc.update.Options{ .check_only = false, .yes = false };

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if (std.mem.eql(u8, sub_args[i], "--check")) {
            opts.check_only = true;
        } else if (std.mem.eql(u8, sub_args[i], "--yes")) {
            opts.yes = true;
        } else {
            std.debug.print("Unknown option: {s}\n", .{sub_args[i]});
            std.debug.print("Usage: nullalis update [--check] [--yes]\n", .{});
            std.process.exit(1);
        }
    }

    yc.update.run(allocator, opts) catch |err| {
        std.debug.print("Update failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn printAuthUsage() void {
    std.debug.print(
        \\Usage: nullalis auth <command> <provider> [options]
        \\
        \\Commands:
        \\  login <provider>                    Authenticate via device code flow
        \\  login <provider> --import-codex     Import from Codex CLI (~/.codex/auth.json)
        \\  status <provider>                   Show authentication status
        \\  logout <provider>                   Remove stored credentials
        \\
        \\Providers:
        \\  openai-codex    ChatGPT Plus/Pro subscription (OAuth)
        \\
        \\Examples:
        \\  nullalis auth login openai-codex
        \\  nullalis auth login openai-codex --import-codex
        \\  nullalis auth status openai-codex
        \\  nullalis auth logout openai-codex
        \\
    , .{});
}

fn runAuthDeviceCodeLogin(
    allocator: std.mem.Allocator,
    codex: type,
    auth_mod: type,
) void {
    std.debug.print("Starting OpenAI Codex authentication...\n\n", .{});

    const dc = auth_mod.startDeviceCodeFlow(
        allocator,
        codex.OAUTH_CLIENT_ID,
        codex.OAUTH_DEVICE_URL,
        codex.OAUTH_SCOPE,
    ) catch {
        std.debug.print("Failed to start device code flow (likely Cloudflare block).\n", .{});
        std.debug.print("Alternative:\n", .{});
        std.debug.print("  nullalis auth login openai-codex --import-codex   (import from Codex CLI)\n", .{});
        std.process.exit(1);
    };
    defer dc.deinit(allocator);

    std.debug.print("Open this URL in your browser:\n", .{});
    std.debug.print("  {s}\n\n", .{dc.verification_uri});
    std.debug.print("Enter code: {s}\n\n", .{dc.user_code});
    std.debug.print("Waiting for authorization...\n", .{});

    const token = auth_mod.pollDeviceCode(
        allocator,
        codex.OAUTH_TOKEN_URL,
        codex.OAUTH_CLIENT_ID,
        dc.device_code,
        dc.interval,
    ) catch |err| {
        switch (err) {
            error.DeviceCodeDenied => std.debug.print("Authorization denied.\n", .{}),
            error.DeviceCodeTimeout => std.debug.print("Authorization timed out.\n", .{}),
            else => std.debug.print("Authorization failed: {}\n", .{err}),
        }
        std.process.exit(1);
    };
    defer token.deinit(allocator);

    saveAndPrintResult(allocator, codex, auth_mod, token);
}

fn runAuthImportCodex(
    allocator: std.mem.Allocator,
    codex: type,
    auth_mod: type,
) void {
    const home = yc.platform.getHomeDir(allocator) catch {
        std.debug.print("HOME not set.\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(home);

    const path = std.fs.path.join(allocator, &.{ home, ".codex", "auth.json" }) catch {
        std.debug.print("Out of memory.\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("Could not open {s}\n", .{path});
        std.debug.print("Install and authenticate with Codex CLI first.\n", .{});
        std.process.exit(1);
    };
    defer file.close();

    const json_bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        std.debug.print("Failed to read {s}\n", .{path});
        std.process.exit(1);
    };
    defer allocator.free(json_bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch {
        std.debug.print("Failed to parse {s}\n", .{path});
        std.process.exit(1);
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.debug.print("Invalid format in {s}\n", .{path});
            std.process.exit(1);
        },
    };

    // Extract tokens object
    const tokens_val = root_obj.get("tokens") orelse {
        std.debug.print("No \"tokens\" field in {s}\n", .{path});
        std.process.exit(1);
    };
    const tokens_obj = switch (tokens_val) {
        .object => |o| o,
        else => {
            std.debug.print("Invalid \"tokens\" field in {s}\n", .{path});
            std.process.exit(1);
        },
    };

    const access_token_str = switch (tokens_obj.get("access_token") orelse {
        std.debug.print("No access_token in Codex CLI credentials.\n", .{});
        std.process.exit(1);
    }) {
        .string => |s| s,
        else => {
            std.debug.print("Invalid access_token in Codex CLI credentials.\n", .{});
            std.process.exit(1);
        },
    };

    if (access_token_str.len == 0) {
        std.debug.print("Empty access_token in Codex CLI credentials.\n", .{});
        std.process.exit(1);
    }

    const refresh_token_str: ?[]const u8 = if (tokens_obj.get("refresh_token")) |rt_val| switch (rt_val) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    } else null;

    // Decode JWT exp from access_token
    const expires_at = decodeJwtExp(allocator, access_token_str);

    const token = auth_mod.OAuthToken{
        .access_token = access_token_str,
        .refresh_token = refresh_token_str,
        .expires_at = expires_at,
        .token_type = "Bearer",
    };

    auth_mod.saveCredential(allocator, codex.CREDENTIAL_KEY, token) catch {
        std.debug.print("Failed to save credential.\n", .{});
        std.process.exit(1);
    };

    const account_id = codex.extractAccountIdFromJwt(allocator, access_token_str) catch null;
    defer if (account_id) |id| allocator.free(id);

    std.debug.print("Imported from Codex CLI ({s})\n", .{path});
    if (account_id) |id| {
        std.debug.print("  Account: {s}\n", .{id});
    }
    std.debug.print("  Access token: {d} bytes\n", .{access_token_str.len});
    if (refresh_token_str != null) {
        std.debug.print("  Refresh token: present\n", .{});
    } else {
        std.debug.print("  Refresh token: absent\n", .{});
    }
    if (expires_at != 0) {
        const remaining = expires_at - std.time.timestamp();
        if (remaining > 0) {
            std.debug.print("  Expires in: {d}h {d}m\n", .{
                @divTrunc(remaining, 3600),
                @divTrunc(@mod(remaining, 3600), 60),
            });
        } else {
            std.debug.print("  Token: expired (will auto-refresh)\n", .{});
        }
    }
    std.debug.print("\nTo use: set \"agents.defaults.model.primary\": \"openai-codex/gpt-5.3-codex\" in ~/.nullalis/config.json\n", .{});
}

/// Decode the "exp" claim from a JWT, returning the Unix timestamp or 0 if not decodable.
fn decodeJwtExp(allocator: std.mem.Allocator, token: []const u8) i64 {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return 0;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return 0;
    const payload_b64 = rest[0..second_dot];
    if (payload_b64.len == 0) return 0;

    const Decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = Decoder.calcSizeForSlice(payload_b64) catch return 0;
    const decoded = allocator.alloc(u8, decoded_len) catch return 0;
    defer allocator.free(decoded);
    Decoder.decode(decoded, payload_b64) catch return 0;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return 0;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return 0,
    };

    if (obj.get("exp")) |exp_val| {
        switch (exp_val) {
            .integer => |i| return i,
            .float => |f| return @intFromFloat(f),
            else => {},
        }
    }
    return 0;
}

fn saveAndPrintResult(
    allocator: std.mem.Allocator,
    codex: type,
    auth_mod: type,
    token: auth_mod.OAuthToken,
) void {
    auth_mod.saveCredential(allocator, codex.CREDENTIAL_KEY, token) catch {
        std.debug.print("Failed to save credential.\n", .{});
        std.process.exit(1);
    };

    const account_id = codex.extractAccountIdFromJwt(allocator, token.access_token) catch null;
    defer if (account_id) |id| allocator.free(id);

    if (account_id) |id| {
        std.debug.print("Authenticated (account: {s})\n", .{id});
    } else {
        std.debug.print("Authenticated successfully.\n", .{});
    }
    std.debug.print("\nTo use: set \"agents.defaults.model.primary\": \"openai-codex/gpt-5.3-codex\" in ~/.nullalis/config.json\n", .{});
}

fn printUsage() void {
    const usage =
        \\nullALIS -- The smallest AI assistant. Zig-powered.
        \\
        \\USAGE:
        \\  nullalis <command> [options]
        \\
        \\COMMANDS:
        \\  onboard     Initialize workspace and configuration
        \\  agent       Start the AI agent loop
        \\  gateway     Start the gateway server (HTTP/WebSocket)
        \\  controller  Start the hosted cell lifecycle controller
        \\  service     Manage OS service lifecycle (install/start/stop/status/uninstall)
        \\  status      Show system status
        \\  version     Show CLI version
        \\  doctor      Run diagnostics
        \\  arzt        Alias for doctor diagnostics
        \\  cron        Manage scheduled tasks
        \\  channel     Manage channels (Telegram, Discord, Slack, ...)
        \\  skills      Manage skills
        \\  migrate     Migrate data from other agent runtimes
        \\  memory      Inspect and maintain memory subsystem
        \\  capabilities Show runtime capabilities manifest
        \\  models      Manage provider model catalogs
        \\  auth        Manage OAuth authentication (OpenAI Codex)
        \\  update      Check for and install updates
        \\  help        Show this help
        \\
        \\OPTIONS:
        \\  onboard [--interactive] [--api-key KEY] [--provider PROV] [--memory MEM]
        \\  agent [-m MESSAGE] [-s SESSION] [--provider PROVIDER] [--model MODEL] [--temperature TEMP]
        \\  gateway [--port PORT] [--host HOST] [--role shared|broker|user_cell] [--user-id ID] [--controller-url URL] [--advertise-url URL]
        \\  controller [--port PORT] [--host HOST] [--cell-namespace NAMESPACE]
        \\  status [--user-id ID]
        \\  version | --version | -V
        \\  doctor [--user-id ID]
        \\  arzt [--user-id ID]
        \\  service <install|start|stop|status|uninstall>
        \\  cron <list|add|once|remove|pause|resume> [ARGS] [--backend auto|file|postgres] [--user-id ID]
        \\  channel <list|start|status|add|remove> [ARGS]
        \\  skills <list|search|install|remove> [ARGS]
        \\  migrate openclaw [--dry-run] [--source PATH]
        \\  migrate tenant-config [--dry-run] [--user-id ID]
        \\  memory <stats|count|reindex|search|get|list|drain-outbox|forget> [ARGS]
        \\  capabilities [--json]
        \\  models refresh
        \\  auth <login|status|logout> <provider> [--import-codex]
        \\  update [--check] [--yes]
        \\
    ;
    // V1.8-16: route help to stdout (matches printVersion pattern at
    // line 412). Was std.debug.print which goes to stderr — that broke
    // the deploy-zaki-runtime smoke test which captures stdout via
    // `out=$(docker run ... help)`. Help is not an error; Unix
    // convention is help → stdout, errors → stderr. Aligns with
    // `printVersion` which already does this correctly.
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    bw.interface.print("{s}", .{usage}) catch return;
    bw.interface.flush() catch return;
}

test "parse known commands" {
    try std.testing.expectEqual(.agent, parseCommand("agent").?);
    try std.testing.expectEqual(.status, parseCommand("status").?);
    try std.testing.expectEqual(.version, parseCommand("version").?);
    try std.testing.expectEqual(.version, parseCommand("--version").?);
    try std.testing.expectEqual(.version, parseCommand("-V").?);
    try std.testing.expectEqual(.arzt, parseCommand("arzt").?);
    try std.testing.expectEqual(.service, parseCommand("service").?);
    try std.testing.expectEqual(.migrate, parseCommand("migrate").?);
    try std.testing.expectEqual(.memory, parseCommand("memory").?);
    try std.testing.expectEqual(.capabilities, parseCommand("capabilities").?);
    try std.testing.expectEqual(.models, parseCommand("models").?);
    try std.testing.expectEqual(.auth, parseCommand("auth").?);
    try std.testing.expectEqual(.update, parseCommand("update").?);
    try std.testing.expectEqual(.controller, parseCommand("controller").?);
    try std.testing.expect(parseCommand("daemon") == null);
    try std.testing.expect(parseCommand("unknown") == null);
}

test "parseGatewayRoleLaunchOptions defaults to shared role" {
    const args = [_][]const u8{ "--port", "3000", "--host", "0.0.0.0" };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .ok => |options| {
            try std.testing.expectEqual(GatewayRole.shared, options.role);
            try std.testing.expect(options.user_id == null);
            try std.testing.expect(options.controller_url == null);
            try std.testing.expect(options.advertise_url == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions parses broker role and controller url" {
    const args = [_][]const u8{
        "--role",
        "broker",
        "--controller-url",
        "http://127.0.0.1:3001",
    };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .ok => |options| {
            try std.testing.expectEqual(GatewayRole.broker, options.role);
            try std.testing.expectEqualStrings("http://127.0.0.1:3001", options.controller_url.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions requires user id for user_cell role" {
    const args = [_][]const u8{ "--role", "user_cell" };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .missing_user_id_for_role => |role| try std.testing.expectEqual(GatewayRole.user_cell, role),
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions rejects invalid role" {
    const args = [_][]const u8{ "--role", "not-real" };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .invalid_role => |value| try std.testing.expectEqualStrings("not-real", value),
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions rejects unknown option" {
    const args = [_][]const u8{ "--controller-ulr", "http://127.0.0.1:3001" };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .unknown_option => |value| try std.testing.expectEqualStrings("--controller-ulr", value),
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions rejects unsupported future options" {
    const args = [_][]const u8{ "--workspace", "/workspace" };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .unsupported_option => |value| try std.testing.expectEqualStrings("--workspace", value),
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions rejects missing short option value" {
    const args = [_][]const u8{"-p"};
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .missing_value => |value| try std.testing.expectEqualStrings("-p", value),
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions rejects unknown short option" {
    const args = [_][]const u8{"-x"};
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .unknown_option => |value| try std.testing.expectEqualStrings("-x", value),
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions rejects controller url in shared role" {
    const args = [_][]const u8{ "--controller-url", "http://127.0.0.1:3001" };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .option_requires_role => |info| {
            try std.testing.expectEqualStrings("--controller-url", info.option);
            try std.testing.expectEqual(GatewayRole.broker, info.role);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions allows controller url for user_cell role" {
    const args = [_][]const u8{
        "--role",
        "user_cell",
        "--user-id",
        "42",
        "--controller-url",
        "http://127.0.0.1:3001",
        "--advertise-url",
        "http://nullalis-cell-42.zaki.svc.cluster.local:3000",
    };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .ok => |options| {
            try std.testing.expectEqual(GatewayRole.user_cell, options.role);
            try std.testing.expectEqualStrings("42", options.user_id.?);
            try std.testing.expectEqualStrings("http://127.0.0.1:3001", options.controller_url.?);
            try std.testing.expectEqualStrings("http://nullalis-cell-42.zaki.svc.cluster.local:3000", options.advertise_url.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions rejects advertise url outside user_cell role" {
    const args = [_][]const u8{ "--role", "broker", "--advertise-url", "http://example.invalid:3000" };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .option_requires_role => |info| {
            try std.testing.expectEqualStrings("--advertise-url", info.option);
            try std.testing.expectEqual(GatewayRole.user_cell, info.role);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseGatewayRoleLaunchOptions requires advertise url when controller url is set for user_cell" {
    const args = [_][]const u8{
        "--role",
        "user_cell",
        "--user-id",
        "42",
        "--controller-url",
        "http://127.0.0.1:3001",
    };
    switch (parseGatewayRoleLaunchOptions(&args)) {
        .missing_option_for_role => |info| {
            try std.testing.expectEqualStrings("--advertise-url", info.option);
            try std.testing.expectEqual(GatewayRole.user_cell, info.role);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "defaultControllerPort increments gateway port when possible" {
    try std.testing.expectEqual(@as(u16, 3001), defaultControllerPort(3000));
    try std.testing.expectEqual(std.math.maxInt(u16), defaultControllerPort(std.math.maxInt(u16)));
}

test "isLoopbackBindHost recognizes loopback addresses only" {
    try std.testing.expect(isLoopbackBindHost("127.0.0.1"));
    try std.testing.expect(isLoopbackBindHost("localhost"));
    try std.testing.expect(isLoopbackBindHost("::1"));
    try std.testing.expect(!isLoopbackBindHost("0.0.0.0"));
    try std.testing.expect(!isLoopbackBindHost("::"));
    try std.testing.expect(!isLoopbackBindHost("10.0.0.5"));
}

test "parseControllerBindOptions defaults to gateway host plus one port" {
    const args = [_][]const u8{};
    switch (parseControllerBindOptions("127.0.0.1", 3001, &args)) {
        .ok => |options| {
            try std.testing.expectEqualStrings("127.0.0.1", options.host);
            try std.testing.expectEqual(@as(u16, 3001), options.port);
            try std.testing.expectEqualStrings("default", options.cell_namespace);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseControllerBindOptions parses host and port" {
    const args = [_][]const u8{ "--host", "0.0.0.0", "--port", "4401", "--cell-namespace", "zaki-bot-staging" };
    switch (parseControllerBindOptions("127.0.0.1", 3001, &args)) {
        .ok => |options| {
            try std.testing.expectEqualStrings("0.0.0.0", options.host);
            try std.testing.expectEqual(@as(u16, 4401), options.port);
            try std.testing.expectEqualStrings("zaki-bot-staging", options.cell_namespace);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseControllerBindOptions rejects unknown option" {
    const args = [_][]const u8{ "--role", "broker" };
    switch (parseControllerBindOptions("127.0.0.1", 3001, &args)) {
        .unknown_option => |value| try std.testing.expectEqualStrings("--role", value),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveCronBackendMode auto selects postgres for tenant postgres config" {
    var cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";
    const resolved = resolveCronBackendMode(&cfg, .auto);
    if (build_options.enable_postgres) {
        try std.testing.expectEqual(CronBackendMode.postgres, resolved);
    } else {
        try std.testing.expectEqual(CronBackendMode.file, resolved);
    }
}

test "resolveCronBackendMode auto selects file for non-tenant mode" {
    var cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = false;
    cfg.state.backend = "postgres";
    try std.testing.expectEqual(CronBackendMode.file, resolveCronBackendMode(&cfg, .auto));
}

test "resolvePostgresCronContext requires user id in tenant postgres mode" {
    var cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";

    if (build_options.enable_postgres) {
        try std.testing.expectError(error.MissingUserId, resolvePostgresCronContext(&cfg, null));
        const ctx = try resolvePostgresCronContext(&cfg, 42);
        try std.testing.expectEqual(@as(i64, 42), ctx.user_id);
        try std.testing.expect(ctx.cfg == &cfg);
    } else {
        try std.testing.expectError(error.PostgresBackendNotEnabled, resolvePostgresCronContext(&cfg, 42));
    }
}

test "resolvePostgresCronContext rejects non-tenant config" {
    var cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = false;
    cfg.state.backend = "postgres";
    if (build_options.enable_postgres) {
        try std.testing.expectError(error.InvalidRuntimeConfig, resolvePostgresCronContext(&cfg, 7));
    } else {
        try std.testing.expectError(error.PostgresBackendNotEnabled, resolvePostgresCronContext(&cfg, 7));
    }
}

test "parsePositiveUsize accepts only positive integers" {
    try std.testing.expectEqual(@as(?usize, 1), parsePositiveUsize("1"));
    try std.testing.expectEqual(@as(?usize, 42), parsePositiveUsize("42"));
    try std.testing.expect(parsePositiveUsize("0") == null);
    try std.testing.expect(parsePositiveUsize("-1") == null);
    try std.testing.expect(parsePositiveUsize("bad") == null);
}

test "forgetMemoryWithValidation returns missing for absent key" {
    var mem_impl = yc.memory.InMemoryLruMemory.init(std.testing.allocator, 16);
    defer mem_impl.deinit();

    try std.testing.expectEqual(
        MemoryForgetAction.missing,
        try forgetMemoryWithValidation(std.testing.allocator, mem_impl.memory(), null, "missing"),
    );
}

test "forgetMemoryWithValidation rejects protected key" {
    var mem_impl = yc.memory.InMemoryLruMemory.init(std.testing.allocator, 16);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();
    try mem.store("summary_latest/agent:zaki-bot:user:1:main", "focus: shipping", .core, null);

    try std.testing.expectEqual(
        MemoryForgetAction.protected,
        try forgetMemoryWithValidation(std.testing.allocator, mem, null, "summary_latest/agent:zaki-bot:user:1:main"),
    );
}

test "forgetMemoryWithValidation deletes editable key" {
    var mem_impl = yc.memory.InMemoryLruMemory.init(std.testing.allocator, 16);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();
    try mem.store("user_name", "Nova", .core, null);

    try std.testing.expectEqual(
        MemoryForgetAction.deleted,
        try forgetMemoryWithValidation(std.testing.allocator, mem, null, "user_name"),
    );
    try std.testing.expect((try mem.get(std.testing.allocator, "user_name")) == null);
}

test "parseOnboardArgs parses quick setup flags" {
    const args = [_][]const u8{ "--api-key", "sk-test", "--provider", "openrouter", "--memory", "markdown" };
    switch (parseOnboardArgs(&args)) {
        .ok => |parsed| {
            try std.testing.expectEqual(OnboardMode.quick, parsed.mode);
            try std.testing.expectEqualStrings("sk-test", parsed.api_key.?);
            try std.testing.expectEqualStrings("openrouter", parsed.provider.?);
            try std.testing.expectEqualStrings("markdown", parsed.memory_backend.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseOnboardArgs parses interactive mode" {
    const args = [_][]const u8{"--interactive"};
    switch (parseOnboardArgs(&args)) {
        .ok => |parsed| {
            try std.testing.expectEqual(OnboardMode.interactive, parsed.mode);
            try std.testing.expect(parsed.api_key == null);
            try std.testing.expect(parsed.provider == null);
            try std.testing.expect(parsed.memory_backend == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseOnboardArgs reports unknown option" {
    const args = [_][]const u8{"--not-real"};
    switch (parseOnboardArgs(&args)) {
        .unknown_option => |opt| try std.testing.expectEqualStrings("--not-real", opt),
        else => return error.TestUnexpectedResult,
    }
}

test "parseOnboardArgs reports missing option value" {
    const args = [_][]const u8{"--provider"};
    switch (parseOnboardArgs(&args)) {
        .missing_value => |opt| try std.testing.expectEqualStrings("--provider", opt),
        else => return error.TestUnexpectedResult,
    }
}

test "parseOnboardArgs rejects mixed interactive and quick flags" {
    const args = [_][]const u8{ "--interactive", "--provider", "openrouter" };
    switch (parseOnboardArgs(&args)) {
        .invalid_combination => {},
        else => return error.TestUnexpectedResult,
    }
}

test "parseOnboardArgs rejects positional arguments" {
    const args = [_][]const u8{"extra"};
    switch (parseOnboardArgs(&args)) {
        .unexpected_argument => |arg| try std.testing.expectEqualStrings("extra", arg),
        else => return error.TestUnexpectedResult,
    }
}

test "applyGatewayDaemonOverrides applies CLI port before validation" {
    var cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .default_model = "openrouter/auto",
        .allocator = std.testing.allocator,
    };
    cfg.gateway.port = 0;

    const args = [_][]const u8{ "--port", "8080" };
    try applyGatewayDaemonOverrides(&cfg, &args);

    try std.testing.expectEqual(@as(u16, 8080), cfg.gateway.port);
    try cfg.validate();
}

test "applyGatewayDaemonOverrides applies host override" {
    var cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .default_model = "openrouter/auto",
        .allocator = std.testing.allocator,
    };
    const args = [_][]const u8{ "--host", "0.0.0.0" };
    try applyGatewayDaemonOverrides(&cfg, &args);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.gateway.host);
}

test "applyGatewayDaemonOverrides rejects invalid port" {
    var cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .default_model = "openrouter/auto",
        .allocator = std.testing.allocator,
    };
    const args = [_][]const u8{ "--port", "bad" };
    try std.testing.expectError(error.InvalidPort, applyGatewayDaemonOverrides(&cfg, &args));
}

test "hasConfiguredStartableChannels ignores cli and webhook-only defaults" {
    const cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .default_model = "openrouter/auto",
        .allocator = std.testing.allocator,
        .channels = .{
            .cli = true,
            .webhook = .{ .port = 8080 },
        },
    };

    try std.testing.expect(!hasConfiguredStartableChannels(&cfg));
}

test "hasConfiguredStartableChannels returns true when telegram configured" {
    const cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .default_model = "openrouter/auto",
        .allocator = std.testing.allocator,
        .channels = .{
            .telegram = &[_]yc.config.TelegramConfig{
                .{ .account_id = "main", .bot_token = "123:abc" },
            },
        },
    };

    if (!yc.channel_catalog.isBuildEnabled(.telegram)) return error.SkipZigTest;
    try std.testing.expect(hasConfiguredStartableChannels(&cfg));
}

test "hasConfiguredButBuildDisabledStartableChannels detects configured disabled channel" {
    const cfg = yc.config.Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .default_model = "openrouter/auto",
        .allocator = std.testing.allocator,
        .channels = .{
            .telegram = &[_]yc.config.TelegramConfig{
                .{ .account_id = "main", .bot_token = "123:abc" },
            },
        },
    };

    try std.testing.expectEqual(!yc.channel_catalog.isBuildEnabled(.telegram), hasConfiguredButBuildDisabledStartableChannels(&cfg));
}
