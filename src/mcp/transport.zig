//! MCP — transport layer.
//!
//! Two transports implement one vtable so `McpServer` is transport-agnostic:
//!
//!   * `StdioTransport` — spawns the server as a child process and speaks
//!     newline-delimited JSON-RPC over its stdin/stdout. Drains stderr on a
//!     background thread (a chatty server otherwise fills the ~64 KiB pipe
//!     buffer and deadlocks).
//!
//!   * `HttpTransport` — POSTs JSON-RPC to an HTTP endpoint (MCP Streamable
//!     HTTP, 2025-03-26). The response may be a single `application/json`
//!     body or a `text/event-stream`; both are handled. The MCP session id
//!     returned in the `Mcp-Session-Id` response header is echoed back on
//!     every subsequent request.
//!
//! Frame routing — the multi-turn stability fix lives here. `request()`
//! sends one JSON-RPC request, then reads frames in a loop:
//!   - notification frames are skipped (logged at debug),
//!   - server-initiated requests get a "method not found" reply,
//!   - the first *response* frame whose id matches is returned.
//! The pre-Sprint-2 client returned the first line unconditionally, so a
//! server log notification was mistaken for the response and every
//! subsequent request read a stale, off-by-one frame — the crash-after-N-turns
//! bug. With id correlation the stream stays aligned indefinitely.

const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("../config.zig");
const platform = @import("../platform.zig");
const jsonrpc = @import("jsonrpc.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.mcp);

pub const McpServerConfig = config_mod.McpServerConfig;

pub const TransportError = error{
    NotConnected,
    SpawnFailed,
    WriteFailed,
    ReadFailed,
    ReadTimeout,
    EndOfStream,
    EmptyResponse,
    HttpError,
    IdMismatch,
    OutOfMemory,
};

/// Result of a request: the matched response frame, caller-owned.
pub const Frame = []const u8;

// ── Transport vtable ────────────────────────────────────────────

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Establish the connection (spawn child / no-op for HTTP).
        connect: *const fn (ptr: *anyopaque) TransportError!void,
        /// Send a JSON-RPC request and return the matching response frame.
        /// `params` is a complete JSON value or null. Caller owns the result.
        request: *const fn (ptr: *anyopaque, id: i64, method: []const u8, params: ?[]const u8) TransportError!Frame,
        /// Send a fire-and-forget notification.
        notify: *const fn (ptr: *anyopaque, method: []const u8, params: ?[]const u8) TransportError!void,
        /// True if the underlying connection looks alive (child not exited).
        isAlive: *const fn (ptr: *anyopaque) bool,
        /// Tear down the connection. Idempotent.
        close: *const fn (ptr: *anyopaque) void,
        /// Free the transport object itself.
        destroy: *const fn (ptr: *anyopaque, allocator: Allocator) void,
    };

    pub fn connect(self: Transport) TransportError!void {
        return self.vtable.connect(self.ptr);
    }
    pub fn request(self: Transport, id: i64, method: []const u8, params: ?[]const u8) TransportError!Frame {
        return self.vtable.request(self.ptr, id, method, params);
    }
    pub fn notify(self: Transport, method: []const u8, params: ?[]const u8) TransportError!void {
        return self.vtable.notify(self.ptr, method, params);
    }
    pub fn isAlive(self: Transport) bool {
        return self.vtable.isAlive(self.ptr);
    }
    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
    pub fn destroy(self: Transport, allocator: Allocator) void {
        self.vtable.destroy(self.ptr, allocator);
    }
};

/// Allocate the transport matching the config's `transport` field.
pub fn create(allocator: Allocator, config: McpServerConfig) TransportError!Transport {
    switch (config.transport) {
        .stdio => {
            const t = allocator.create(StdioTransport) catch return error.OutOfMemory;
            t.* = StdioTransport.init(allocator, config);
            return t.transport();
        },
        .http => {
            const t = allocator.create(HttpTransport) catch return error.OutOfMemory;
            t.* = HttpTransport.init(allocator, config);
            return t.transport();
        },
    }
}

// ── StdioTransport ──────────────────────────────────────────────

pub const StdioTransport = struct {
    allocator: Allocator,
    config: McpServerConfig,
    child: ?std.process.Child = null,
    /// Background thread draining the child's stderr pipe (S7.12).
    stderr_drain_thread: ?std.Thread = null,

    const STDERR_LINE_MAX: usize = 4096;
    /// Hard cap on a single response line. A misbehaving server emitting an
    /// unbounded line without a newline would otherwise grow this buffer
    /// without limit.
    const RESPONSE_LINE_MAX: usize = 16 * 1024 * 1024;
    /// How many notification/foreign frames to skip before giving up. Bounds
    /// the loop so a server stuck emitting only notifications cannot spin
    /// forever inside one `request`.
    const MAX_SKIPPED_FRAMES: usize = 256;

    const vtable = Transport.VTable{
        .connect = &connectImpl,
        .request = &requestImpl,
        .notify = &notifyImpl,
        .isAlive = &isAliveImpl,
        .close = &closeImpl,
        .destroy = &destroyImpl,
    };

    pub fn init(allocator: Allocator, config: McpServerConfig) StdioTransport {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn transport(self: *StdioTransport) Transport {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn connectImpl(ptr: *anyopaque) TransportError!void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));

        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);
        argv_list.append(self.allocator, self.config.command) catch return error.OutOfMemory;
        for (self.config.args) |a| {
            argv_list.append(self.allocator, a) catch return error.OutOfMemory;
        }

        var child = std.process.Child.init(argv_list.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        var env = std.process.EnvMap.init(self.allocator);
        defer env.deinit();
        const inherit_vars = [_][]const u8{
            "PATH",              "HOME",        "TERM",    "LANG",         "LC_ALL",
            "LC_CTYPE",          "USER",        "SHELL",   "TMPDIR",       "NODE_PATH",
            "NPM_CONFIG_PREFIX", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP",
            "TMP",               "SYSTEMROOT",  "COMSPEC", "PROGRAMFILES", "WINDIR",
        };
        for (&inherit_vars) |key| {
            if (platform.getEnvOrNull(self.allocator, key)) |val| {
                defer self.allocator.free(val);
                env.put(key, val) catch return error.OutOfMemory;
            }
        }
        for (self.config.env) |entry| {
            env.put(entry.key, entry.value) catch return error.OutOfMemory;
        }
        child.env_map = &env;

        child.spawn() catch return error.SpawnFailed;
        self.child = child;

        // S7.12 — drain stderr so a log-heavy server cannot deadlock on a
        // full pipe buffer.
        if (self.child.?.stderr) |_| {
            self.stderr_drain_thread = std.Thread.spawn(.{}, drainStderr, .{self}) catch null;
        }
    }

    fn requestImpl(ptr: *anyopaque, id: i64, method: []const u8, params: ?[]const u8) TransportError!Frame {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        const msg = jsonrpc.buildRequest(self.allocator, id, method, params) catch return error.OutOfMemory;
        defer self.allocator.free(msg);

        const stdin = (self.child orelse return error.NotConnected).stdin orelse return error.NotConnected;
        stdin.writeAll(msg) catch return error.WriteFailed;

        // Read frames until the response whose id matches arrives. Skip
        // notifications; answer foreign server requests.
        var skipped: usize = 0;
        while (skipped < MAX_SKIPPED_FRAMES) {
            const frame = try self.readLine();
            errdefer self.allocator.free(frame);
            const c = jsonrpc.classify(self.allocator, frame);
            switch (c.kind) {
                .response => {
                    if (c.id != null and c.id.? == id) return frame;
                    // A response for a different id: drop it. Should not
                    // happen with serialized requests but stays robust.
                    log.debug("[{s}] stdio: dropping response id={?d} (awaiting {d})", .{ self.config.name, c.id, id });
                    self.allocator.free(frame);
                    skipped += 1;
                },
                .notification => {
                    log.debug("[{s}] stdio: skipping notification frame", .{self.config.name});
                    self.allocator.free(frame);
                    skipped += 1;
                },
                .server_request => {
                    self.allocator.free(frame);
                    if (c.id) |sid| {
                        const err_reply = jsonrpc.buildMethodNotFound(self.allocator, sid) catch return error.OutOfMemory;
                        defer self.allocator.free(err_reply);
                        stdin.writeAll(err_reply) catch return error.WriteFailed;
                    }
                    skipped += 1;
                },
                .invalid => {
                    log.warn("[{s}] stdio: dropping unparseable frame", .{self.config.name});
                    self.allocator.free(frame);
                    skipped += 1;
                },
            }
        }
        return error.IdMismatch;
    }

    fn notifyImpl(ptr: *anyopaque, method: []const u8, params: ?[]const u8) TransportError!void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        const msg = jsonrpc.buildNotification(self.allocator, method, params) catch return error.OutOfMemory;
        defer self.allocator.free(msg);
        const stdin = (self.child orelse return error.NotConnected).stdin orelse return error.NotConnected;
        stdin.writeAll(msg) catch return error.WriteFailed;
    }

    fn isAliveImpl(ptr: *anyopaque) bool {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        return self.child != null and self.child.?.stdin != null;
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        if (self.child) |*child| {
            if (child.stdin) |stdin| {
                stdin.close();
                child.stdin = null;
            }
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.child = null;
        // Join the drain thread AFTER kill+wait so its read sees EOF.
        if (self.stderr_drain_thread) |t| {
            t.join();
            self.stderr_drain_thread = null;
        }
    }

    fn destroyImpl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }

    /// Read one newline-terminated frame from the child's stdout. Bounded by
    /// a POSIX-poll deadline (S7.11) so a hung server cannot block forever.
    fn readLine(self: *StdioTransport) TransportError!Frame {
        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer line_buf.deinit(self.allocator);
        var byte: [1]u8 = undefined;
        const stdout = (self.child orelse return error.NotConnected).stdout orelse return error.NotConnected;

        const timeout_secs: u64 = self.config.read_line_timeout_secs;
        const use_timeout = timeout_secs > 0 and builtin.os.tag != .windows;
        const deadline_ns: i128 = if (use_timeout)
            std.time.nanoTimestamp() + @as(i128, @intCast(timeout_secs)) * std.time.ns_per_s
        else
            0;

        // One deadline covers the whole call, including any blank lines
        // skipped between frames — a server spewing endless blank lines hits
        // ReadTimeout rather than recursing the stack.
        while (true) {
            if (use_timeout) {
                const remaining_ns = deadline_ns - std.time.nanoTimestamp();
                if (remaining_ns <= 0) return error.ReadTimeout;
                const remaining_ms: i32 = @intCast(@min(@as(i128, std.math.maxInt(i32)), @divTrunc(remaining_ns, std.time.ns_per_ms)));
                var pfd = [_]std.posix.pollfd{.{
                    .fd = stdout.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&pfd, remaining_ms) catch return error.ReadFailed;
                if (ready == 0) return error.ReadTimeout;
                if ((pfd[0].revents & std.posix.POLL.IN) == 0) return error.EndOfStream;
            }
            const n = stdout.read(&byte) catch return error.ReadFailed;
            if (n == 0) {
                if (line_buf.items.len > 0) return line_buf.toOwnedSlice(self.allocator);
                return error.EndOfStream;
            }
            if (byte[0] == '\n') {
                if (line_buf.items.len == 0) continue; // blank line between frames
                return line_buf.toOwnedSlice(self.allocator);
            }
            if (byte[0] != '\r') {
                if (line_buf.items.len >= RESPONSE_LINE_MAX) return error.ReadFailed;
                line_buf.append(self.allocator, byte[0]) catch return error.OutOfMemory;
            }
        }
    }

    /// S7.12 — background reader for the child's stderr pipe.
    fn drainStderr(self: *StdioTransport) void {
        const stderr = (self.child orelse return).stderr orelse return;
        var line_buf: [STDERR_LINE_MAX]u8 = undefined;
        var line_len: usize = 0;
        var byte: [1]u8 = undefined;
        while (true) {
            const n = stderr.read(&byte) catch return;
            if (n == 0) {
                if (line_len > 0) log.warn("[{s}] {s}", .{ self.config.name, line_buf[0..line_len] });
                return;
            }
            if (byte[0] == '\n') {
                if (line_len > 0) log.warn("[{s}] {s}", .{ self.config.name, line_buf[0..line_len] });
                line_len = 0;
                continue;
            }
            if (byte[0] == '\r') continue;
            if (line_len < STDERR_LINE_MAX) {
                line_buf[line_len] = byte[0];
                line_len += 1;
            } else {
                log.warn("[{s}] {s}...(truncated)", .{ self.config.name, line_buf[0..line_len] });
                line_len = 0;
                while (true) {
                    const m = stderr.read(&byte) catch return;
                    if (m == 0) return;
                    if (byte[0] == '\n') break;
                }
            }
        }
    }
};

// ── HttpTransport ───────────────────────────────────────────────

/// MCP Streamable HTTP transport. Every JSON-RPC message is POSTed to the
/// configured `url`. We accept both `application/json` and
/// `text/event-stream` responses (the spec lets the server choose). A
/// session id returned via `Mcp-Session-Id` is captured and re-sent.
pub const HttpTransport = struct {
    allocator: Allocator,
    config: McpServerConfig,
    /// MCP session id captured from the `Mcp-Session-Id` response header on
    /// the `initialize` response. Echoed on every subsequent request.
    session_id: ?[]u8 = null,
    /// Set false after a transport-level HTTP failure so `isAlive` reports
    /// the connection as dead and the owner can trigger a reconnect.
    healthy: bool = true,

    const vtable = Transport.VTable{
        .connect = &connectImpl,
        .request = &requestImpl,
        .notify = &notifyImpl,
        .isAlive = &isAliveImpl,
        .close = &closeImpl,
        .destroy = &destroyImpl,
    };

    pub fn init(allocator: Allocator, config: McpServerConfig) HttpTransport {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn connectImpl(ptr: *anyopaque) TransportError!void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        // No persistent socket for Streamable HTTP — connectivity is proven
        // by the `initialize` request the McpServer issues next. Just reset
        // health so a re-connect after a crash starts clean.
        self.healthy = true;
    }

    fn requestImpl(ptr: *anyopaque, id: i64, method: []const u8, params: ?[]const u8) TransportError!Frame {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const body = jsonrpc.buildRequest(arena, id, method, params) catch return error.OutOfMemory;
        const resp = self.curlPost(arena, body) catch {
            self.healthy = false;
            return error.HttpError;
        };

        if (resp.status >= 400) {
            self.healthy = false;
            log.warn("[{s}] http: status {d}", .{ self.config.name, resp.status });
            return error.HttpError;
        }
        self.healthy = true;

        // Capture the MCP session id from the response headers the first time
        // the server issues one (per spec, on the `initialize` response).
        if (self.session_id == null) {
            if (parseSessionId(resp.headers)) |sid| {
                self.session_id = self.allocator.dupe(u8, sid) catch null;
            }
        }

        // The body is either a bare JSON object or an SSE stream. Extract the
        // JSON-RPC frame whose id matches our request.
        const frame = extractJsonRpcFrame(self.allocator, resp.body, id) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.EmptyResponse,
            };
        };
        return frame;
    }

    const HttpResult = struct {
        status: u16,
        headers: []const u8,
        body: []const u8,
    };

    /// POST `body` to the configured MCP URL with curl, capturing both the
    /// response headers (via `-D-`, dumped before the body) and the body.
    /// http_util.curlRequest discards headers, and we need `Mcp-Session-Id` —
    /// hence this dedicated invocation. Arena-allocated; caller's arena owns.
    fn curlPost(self: *HttpTransport, arena: Allocator, body: []const u8) !HttpResult {
        var timeout_buf: [16]u8 = undefined;
        const timeout_secs = if (self.config.read_line_timeout_secs > 0) self.config.read_line_timeout_secs else 30;
        const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_secs}) catch "30";

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.appendSlice(arena, &.{
            "curl", "-sS",
            "-D",         "-", // dump response headers to stdout, before body
            "--max-time", timeout_str,
            "-X",         "POST",
            "-H",         "Content-Type: application/json",
            "-H",         "Accept: application/json, text/event-stream",
        });
        if (self.session_id) |sid| {
            try argv.append(arena, "-H");
            try argv.append(arena, try std.fmt.allocPrint(arena, "Mcp-Session-Id: {s}", .{sid}));
        }
        for (self.config.headers) |h| {
            try argv.append(arena, "-H");
            try argv.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ h.key, h.value }));
        }
        try argv.appendSlice(arena, &.{ "--data-binary", "@-", self.config.url });

        var child = std.process.Child.init(argv.items, arena);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        if (child.stdin) |stdin| {
            stdin.writeAll(body) catch {};
            stdin.close();
            child.stdin = null;
        }
        const raw = child.stdout.?.readToEndAlloc(arena, 8 * 1024 * 1024) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.HttpError;
        };
        const term = child.wait() catch return error.HttpError;
        switch (term) {
            .Exited => |code| if (code != 0) return error.HttpError,
            else => return error.HttpError,
        }

        // `-D -` writes the header block(s) then the body. With redirects or
        // 100-continue there may be multiple header blocks; the body starts
        // after the LAST blank line. Status comes from the last HTTP/ line.
        const sep = "\r\n\r\n";
        var header_end: usize = 0;
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, raw, search_from, sep)) |idx| {
            header_end = idx + sep.len;
            search_from = idx + sep.len;
        }
        // Fallback for LF-only header termination.
        if (header_end == 0) {
            if (std.mem.indexOf(u8, raw, "\n\n")) |idx| header_end = idx + 2;
        }
        const headers = raw[0..header_end];
        const resp_body = raw[header_end..];
        const status = parseHttpStatus(headers);
        return .{ .status = status, .headers = headers, .body = resp_body };
    }

    fn notifyImpl(ptr: *anyopaque, method: []const u8, params: ?[]const u8) TransportError!void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const body = jsonrpc.buildNotification(arena, method, params) catch return error.OutOfMemory;
        const resp = self.curlPost(arena, body) catch {
            self.healthy = false;
            return error.HttpError;
        };
        // A notification yields 202 Accepted (no body) per spec; anything in
        // the 4xx/5xx range is a real failure the caller should see.
        if (resp.status >= 400) {
            self.healthy = false;
            return error.HttpError;
        }
    }

    fn isAliveImpl(ptr: *anyopaque) bool {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        return self.healthy;
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }
        self.healthy = false;
    }

    fn destroyImpl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        if (self.session_id) |sid| self.allocator.free(sid);
        allocator.destroy(self);
    }
};

/// Parse the HTTP status code from a curl `-D-` header dump. Returns the
/// code from the LAST `HTTP/...` status line (handles redirects / 100-continue).
pub fn parseHttpStatus(headers: []const u8) u16 {
    var status: u16 = 0;
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            // "HTTP/1.1 200 OK" — the code is the 2nd space-delimited token.
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            _ = parts.next(); // HTTP/x.y
            if (parts.next()) |code_str| {
                status = std.fmt.parseInt(u16, code_str, 10) catch status;
            }
        }
    }
    return status;
}

/// Extract the `Mcp-Session-Id` header value from a curl `-D-` header dump.
/// Header name match is case-insensitive (HTTP header names are). Returns a
/// slice into `headers` — borrow only.
pub fn parseSessionId(headers: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (std.ascii.eqlIgnoreCase(name, "mcp-session-id")) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        }
    }
    return null;
}

/// Extract the JSON-RPC response frame matching `want_id` from an HTTP
/// response body. The body is either:
///   * a single JSON object (`application/json`), or
///   * an SSE stream of `data:` lines (`text/event-stream`).
/// SSE streams may carry notification frames before the response; we scan
/// every `data:` payload and return the first response whose id matches.
/// Caller owns the returned slice.
pub fn extractJsonRpcFrame(allocator: Allocator, body: []const u8, want_id: i64) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyResponse;

    // Bare JSON object — the common application/json case.
    if (trimmed[0] == '{') {
        const c = jsonrpc.classify(allocator, trimmed);
        if (c.kind == .response) {
            // Accept it even if the id check is loose — a single-object body
            // is unambiguously the answer to the single request we sent.
            return allocator.dupe(u8, trimmed);
        }
        // A lone notification/invalid object: not our answer.
        return error.EmptyResponse;
    }

    // SSE framing: lines like `data: {...}`. Concatenate multi-line data
    // payloads per event (SSE allows a payload split across `data:` lines).
    var it = std.mem.splitScalar(u8, body, '\n');
    var data_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer data_buf.deinit(allocator);
    var fallback: ?[]const u8 = null;
    errdefer if (fallback) |f| allocator.free(f);

    while (it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) {
            // End of an SSE event — evaluate the accumulated data payload.
            if (data_buf.items.len > 0) {
                const payload = std.mem.trim(u8, data_buf.items, " \t\r\n");
                if (payload.len > 0 and payload[0] == '{') {
                    const c = jsonrpc.classify(allocator, payload);
                    if (c.kind == .response) {
                        if (c.id != null and c.id.? == want_id) {
                            const out = try allocator.dupe(u8, payload);
                            if (fallback) |f| allocator.free(f);
                            return out;
                        }
                        // Keep the last response as a fallback in case ids
                        // are absent / float-coerced oddly.
                        if (fallback) |f| allocator.free(f);
                        fallback = try allocator.dupe(u8, payload);
                    }
                }
                data_buf.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            var v = line["data:".len..];
            if (v.len > 0 and v[0] == ' ') v = v[1..];
            try data_buf.appendSlice(allocator, v);
        }
    }
    // Flush a trailing event with no terminating blank line.
    if (data_buf.items.len > 0) {
        const payload = std.mem.trim(u8, data_buf.items, " \t\r\n");
        if (payload.len > 0 and payload[0] == '{') {
            const c = jsonrpc.classify(allocator, payload);
            if (c.kind == .response) {
                if (c.id != null and c.id.? == want_id) {
                    const out = try allocator.dupe(u8, payload);
                    if (fallback) |f| allocator.free(f);
                    return out;
                }
                if (fallback) |f| allocator.free(f);
                fallback = try allocator.dupe(u8, payload);
            }
        }
    }
    if (fallback) |f| {
        fallback = null;
        return f;
    }
    return error.EmptyResponse;
}

// ── Tests ───────────────────────────────────────────────────────

test "create stdio transport from config" {
    const t = try create(std.testing.allocator, .{ .name = "x", .transport = .stdio, .command = "/bin/echo" });
    defer t.destroy(std.testing.allocator);
    try std.testing.expect(!t.isAlive()); // not connected yet
}

test "create http transport from config" {
    const t = try create(std.testing.allocator, .{ .name = "x", .transport = .http, .url = "http://localhost/mcp" });
    defer t.destroy(std.testing.allocator);
    try std.testing.expect(t.isAlive()); // http is "alive" until a request fails
}

test "extractJsonRpcFrame bare json object" {
    const body =
        \\{"jsonrpc":"2.0","id":5,"result":{"ok":true}}
    ;
    const frame = try extractJsonRpcFrame(std.testing.allocator, body, 5);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
}

test "extractJsonRpcFrame sse stream picks matching id" {
    const body =
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\n" ++
        "\n" ++
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"v\":1}}\n" ++
        "\n";
    const frame = try extractJsonRpcFrame(std.testing.allocator, body, 9);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"v\":1") != null);
}

test "extractJsonRpcFrame sse multi-line data payload" {
    // SSE allows one logical payload split across consecutive data: lines.
    const body =
        "data: {\"jsonrpc\":\"2.0\",\n" ++
        "data: \"id\":3,\"result\":{\"x\":2}}\n" ++
        "\n";
    const frame = try extractJsonRpcFrame(std.testing.allocator, body, 3);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"x\":2") != null);
}

test "extractJsonRpcFrame empty body errors" {
    try std.testing.expectError(error.EmptyResponse, extractJsonRpcFrame(std.testing.allocator, "   \n", 1));
}

test "extractJsonRpcFrame notification-only sse errors" {
    const body = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}\n\n";
    try std.testing.expectError(error.EmptyResponse, extractJsonRpcFrame(std.testing.allocator, body, 1));
}

test "parseHttpStatus reads last status line" {
    const h = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n";
    try std.testing.expectEqual(@as(u16, 200), parseHttpStatus(h));
}

test "parseHttpStatus error code" {
    try std.testing.expectEqual(@as(u16, 404), parseHttpStatus("HTTP/2 404 Not Found\r\n\r\n"));
}

test "parseSessionId case-insensitive" {
    const h = "HTTP/1.1 200 OK\r\nMcp-Session-Id: abc-123\r\nContent-Type: application/json\r\n\r\n";
    try std.testing.expectEqualStrings("abc-123", parseSessionId(h).?);
    const h2 = "HTTP/1.1 200 OK\r\nmcp-session-id: xyz\r\n\r\n";
    try std.testing.expectEqualStrings("xyz", parseSessionId(h2).?);
}

test "parseSessionId absent returns null" {
    try std.testing.expect(parseSessionId("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n") == null);
}
