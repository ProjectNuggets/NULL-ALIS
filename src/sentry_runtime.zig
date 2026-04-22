const std = @import("std");
const sentry = @import("sentry-zig");
const version = @import("version.zig");
const observability = @import("observability.zig");

const Allocator = std.mem.Allocator;

/// Process-global Sentry runtime pointer. Set once by main.zig after boot so
/// observability composition sites (gateway, session, channel_loop) can attach
/// a SentryObserver without threading the runtime through every init call.
var current_runtime: ?*Runtime = null;

pub fn setGlobal(rt: *Runtime) void {
    current_runtime = rt;
}

pub fn clearGlobal() void {
    current_runtime = null;
}

pub fn currentGlobal() ?*Runtime {
    return current_runtime;
}

/// Always-disabled stub used as an observer fallback when the real Runtime
/// hasn't been set yet (unit tests, pre-main setup). The stub's client stays
/// null so every captureError is a no-op.
var fallback_disabled: Runtime = .{ .allocator = undefined };

/// Return the process Sentry runtime if registered, otherwise a safe disabled
/// stub. Callers wiring the observer chain should use this so they can always
/// attach a Sentry observer without threading null-checks through composition.
pub fn globalOrFallback() *Runtime {
    return current_runtime orelse &fallback_disabled;
}

pub const Runtime = struct {
    allocator: Allocator,
    client: ?*sentry.Client = null,
    dsn: ?[]u8 = null,
    release: ?[]u8 = null,
    environment: ?[]u8 = null,

    pub fn init(allocator: Allocator) Runtime {
        var runtime = Runtime{ .allocator = allocator };
        runtime.bootstrap() catch |err| {
            std.log.warn("Sentry bootstrap disabled ({s})", .{@errorName(err)});
            runtime.resetOwned();
        };
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.client) |client| {
            client.deinit();
            self.client = null;
        }
        self.resetOwned();
    }

    pub fn isEnabled(self: *const Runtime) bool {
        return self.client != null;
    }

    pub fn capturePanic(self: *Runtime, msg: []const u8) void {
        if (self.client) |client| {
            client.captureException("panic", msg);
        }
    }

    pub fn captureError(self: *Runtime, component: []const u8, message: []const u8) void {
        if (self.client) |client| {
            client.captureException(component, message);
        }
    }

    pub fn captureMessage(self: *Runtime, message: []const u8, level: sentry.Level) void {
        if (self.client) |client| {
            client.captureMessage(message, level);
        }
    }

    pub fn flush(self: *Runtime, timeout_ms: u64) void {
        if (self.client) |client| {
            _ = client.flush(timeout_ms);
        }
    }

    // ── Observer interface ────────────────────────────────────────────
    //
    // Runtime implements observability.Observer directly so composition sites
    // can attach it alongside LogObserver / MetricsObserver without a separate
    // wrapper struct. Only ObserverEvent.err and elevated .system_notice are
    // captured — other events are noise for Sentry.

    const runtime_observer_vtable = observability.Observer.VTable{
        .record_event = observerRecordEvent,
        .record_metric = observerRecordMetric,
        .flush = observerFlush,
        .name = observerName,
    };

    pub fn observer(self: *Runtime) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &runtime_observer_vtable };
    }

    fn resolveObserver(ptr: *anyopaque) *Runtime {
        return @ptrCast(@alignCast(ptr));
    }

    fn observerRecordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self = resolveObserver(ptr);
        if (!self.isEnabled()) return;
        switch (event.*) {
            .err => |e| self.captureError(e.component, e.message),
            .system_notice => |n| {
                const is_elevated = std.ascii.eqlIgnoreCase(n.severity, "error") or
                    std.ascii.eqlIgnoreCase(n.severity, "critical");
                if (!is_elevated) return;
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ n.kind, n.message }) catch n.message;
                self.captureError(n.kind, msg);
            },
            else => {},
        }
    }

    fn observerRecordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}

    fn observerFlush(ptr: *anyopaque) void {
        resolveObserver(ptr).flush(2000);
    }

    fn observerName(_: *anyopaque) []const u8 {
        return "sentry";
    }

    fn bootstrap(self: *Runtime) !void {
        const dsn = try getEnvVarOwnedWithFallback(self.allocator, "NULLALIS_SENTRY_DSN", "NULLCLAW_SENTRY_DSN");
        if (dsn == null) return;
        self.dsn = dsn;
        errdefer self.resetOwned();

        self.environment = try getEnvVarOwnedWithFallback(self.allocator, "NULLALIS_SENTRY_ENVIRONMENT", "NULLCLAW_SENTRY_ENVIRONMENT");
        if (try getEnvVarOwnedWithFallback(self.allocator, "NULLALIS_SENTRY_RELEASE", "NULLCLAW_SENTRY_RELEASE")) |release| {
            self.release = release;
        } else {
            self.release = try std.fmt.allocPrint(self.allocator, "nullalis@{s}", .{version.string});
        }

        const sample_rate = readEnvF64WithFallback(self.allocator, "NULLALIS_SENTRY_SAMPLE_RATE", "NULLCLAW_SENTRY_SAMPLE_RATE", 1.0);
        const traces_sample_rate = readEnvF64WithFallback(self.allocator, "NULLALIS_SENTRY_TRACES_SAMPLE_RATE", "NULLCLAW_SENTRY_TRACES_SAMPLE_RATE", 0.0);
        const debug = readEnvBoolWithFallback(self.allocator, "NULLALIS_SENTRY_DEBUG", "NULLCLAW_SENTRY_DEBUG", false);
        const auto_session_tracking = readEnvBoolWithFallback(self.allocator, "NULLALIS_SENTRY_AUTO_SESSION", "NULLCLAW_SENTRY_AUTO_SESSION", false);
        const install_signal_handlers = readEnvBoolWithFallback(self.allocator, "NULLALIS_SENTRY_INSTALL_SIGNAL_HANDLERS", "NULLCLAW_SENTRY_INSTALL_SIGNAL_HANDLERS", false);

        self.client = try sentry.init(self.allocator, .{
            .dsn = self.dsn.?,
            .release = self.release,
            .environment = self.environment,
            .sample_rate = sample_rate,
            .traces_sample_rate = traces_sample_rate,
            .debug = debug,
            .auto_session_tracking = auto_session_tracking,
            .install_signal_handlers = install_signal_handlers,
        });

        if (readEnvBoolWithFallback(self.allocator, "NULLALIS_SENTRY_STARTUP_EVENT", "NULLCLAW_SENTRY_STARTUP_EVENT", false)) {
            self.captureMessage("nullalis startup", .info);
        }
    }

    fn resetOwned(self: *Runtime) void {
        if (self.dsn) |value| {
            self.allocator.free(value);
            self.dsn = null;
        }
        if (self.release) |value| {
            self.allocator.free(value);
            self.release = null;
        }
        if (self.environment) |value| {
            self.allocator.free(value);
            self.environment = null;
        }
    }
};

fn getEnvVarOwned(allocator: Allocator, key: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

// Rebrand chokepoint: read NULLALIS_* primary, fall back to legacy NULLCLAW_*.
// Deprecate fallbacks one wave at a time per Sprint 8 W5.3.
fn getEnvVarOwnedWithFallback(allocator: Allocator, primary: []const u8, fallback: []const u8) !?[]u8 {
    if (try getEnvVarOwned(allocator, primary)) |value| return value;
    if (try getEnvVarOwned(allocator, fallback)) |value| {
        std.log.warn("env {s} is deprecated; use {s}", .{ fallback, primary });
        return value;
    }
    return null;
}

fn readEnvBool(allocator: Allocator, key: []const u8, default_value: bool) bool {
    const raw = std.process.getEnvVarOwned(allocator, key) catch return default_value;
    defer allocator.free(raw);
    return parseBool(raw) orelse default_value;
}

fn readEnvBoolIfSet(allocator: Allocator, key: []const u8) ?bool {
    const raw = std.process.getEnvVarOwned(allocator, key) catch return null;
    defer allocator.free(raw);
    return parseBool(raw);
}

fn readEnvBoolWithFallback(allocator: Allocator, primary: []const u8, fallback: []const u8, default_value: bool) bool {
    if (readEnvBoolIfSet(allocator, primary)) |v| return v;
    if (readEnvBoolIfSet(allocator, fallback)) |v| {
        std.log.warn("env {s} is deprecated; use {s}", .{ fallback, primary });
        return v;
    }
    return default_value;
}

fn readEnvF64(allocator: Allocator, key: []const u8, default_value: f64) f64 {
    const raw = std.process.getEnvVarOwned(allocator, key) catch return default_value;
    defer allocator.free(raw);
    return std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r\n")) catch default_value;
}

fn readEnvF64IfSet(allocator: Allocator, key: []const u8) ?f64 {
    const raw = std.process.getEnvVarOwned(allocator, key) catch return null;
    defer allocator.free(raw);
    return std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r\n")) catch null;
}

fn readEnvF64WithFallback(allocator: Allocator, primary: []const u8, fallback: []const u8, default_value: f64) f64 {
    if (readEnvF64IfSet(allocator, primary)) |v| return v;
    if (readEnvF64IfSet(allocator, fallback)) |v| {
        std.log.warn("env {s} is deprecated; use {s}", .{ fallback, primary });
        return v;
    }
    return default_value;
}

fn parseBool(raw: []const u8) ?bool {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return false;
    }
    return null;
}

test "parseBool supports common true/false values" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("false"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("0"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("maybe"));
}

test "Runtime observer is a safe no-op when Sentry disabled" {
    var rt = Runtime{ .allocator = std.testing.allocator };
    try std.testing.expect(!rt.isEnabled());

    const o = rt.observer();
    const e = observability.ObserverEvent{ .err = .{ .component = "test", .message = "boom" } };
    o.recordEvent(&e);
    o.flush();

    const notice = observability.ObserverEvent{
        .system_notice = .{ .kind = "generic", .severity = "info", .message = "noise" },
    };
    o.recordEvent(&notice);

    try std.testing.expectEqualStrings("sentry", o.getName());
}
