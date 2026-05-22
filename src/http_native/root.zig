const std = @import("std");
const net_security = @import("../net_security.zig");
pub const types = @import("types.zig");
pub const pool_mod = @import("pool.zig");

pub const PooledConn = pool_mod.PooledConn;

pub const TransportMode = types.TransportMode;
pub const TransportSubsystem = types.TransportSubsystem;
pub const PoolConfig = types.PoolConfig;
pub const ResolverConfig = types.ResolverConfig;
pub const RequestOptions = types.RequestOptions;
pub const Response = types.Response;
pub const TransportConfig = types.TransportConfig;

const Certificate = std.crypto.Certificate;
const RequestScheme = enum { http, https };
const HTTP_HEAD_BUFFER_LEN = 16 * 1024;
const HTTP_WRITE_BUFFER_LEN = 16 * 1024;

pub const TlsIoState = struct {
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,
    tls_client: std.crypto.tls.Client,
    tls_read_buf: []u8,
    tls_write_buf: []u8,
    socket_write_buf: []u8,
    socket_read_buf: []u8,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, host: []const u8, bundle: Certificate.Bundle) RequestError!*TlsIoState {
        const tls_buf_len = std.crypto.tls.Client.min_buffer_len;
        const tls_read_buf = try allocator.alloc(u8, tls_buf_len + HTTP_HEAD_BUFFER_LEN);
        errdefer allocator.free(tls_read_buf);
        const tls_write_buf = try allocator.alloc(u8, tls_buf_len);
        errdefer allocator.free(tls_write_buf);
        const socket_write_buf = try allocator.alloc(u8, HTTP_WRITE_BUFFER_LEN);
        errdefer allocator.free(socket_write_buf);
        const socket_read_buf = try allocator.alloc(u8, tls_buf_len);
        errdefer allocator.free(socket_read_buf);

        const state = try allocator.create(TlsIoState);
        errdefer allocator.destroy(state);
        state.tls_read_buf = tls_read_buf;
        state.tls_write_buf = tls_write_buf;
        state.socket_write_buf = socket_write_buf;
        state.socket_read_buf = socket_read_buf;
        state.stream_reader = stream.reader(socket_read_buf);
        state.stream_writer = stream.writer(tls_write_buf);
        state.tls_client = std.crypto.tls.Client.init(
            state.stream_reader.interface(),
            &state.stream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = bundle },
                .read_buffer = tls_read_buf,
                .write_buffer = socket_write_buf,
                .allow_truncation_attacks = true,
            },
        ) catch return error.TlsInitializationFailed;
        return state;
    }

    pub fn deinit(self: *TlsIoState, allocator: std.mem.Allocator) void {
        allocator.free(self.tls_read_buf);
        allocator.free(self.tls_write_buf);
        allocator.free(self.socket_write_buf);
        allocator.free(self.socket_read_buf);
        allocator.destroy(self);
    }
};

// ── Pool integration ──────────────────────────────────────────────────────────

/// Called by the pool to close a PooledConn (plain or TLS).
fn closePooledConn(conn: pool_mod.PooledConn) void {
    if (conn.tls_state) |opaque_tls| {
        const tls: *TlsIoState = @ptrCast(@alignCast(opaque_tls));
        // We can't pass an allocator here (pool uses page_allocator);
        // TlsIoState was allocated with page_allocator when pooled.
        tls.deinit(std.heap.page_allocator);
    }
    conn.stream.close();
}

/// The TransportConfig used for pooling — pulled from process-level config
/// when available, falls back to reasonable defaults.
const POOL_CONFIG = @import("types.zig").PoolConfig{
    .max_connections = 8,
    .max_idle_time_ms = 30_000,
    .max_requests_per_conn = 100,
};

fn getPool() *pool_mod.ConnectionPool {
    return pool_mod.globalPool(POOL_CONFIG, closePooledConn);
}

/// Public alias so gateway.zig can reference the close function without
/// triggering a circular import.
pub const closePooledConnForGateway = closePooledConn;

const shared_ca_bundle = struct {
    var mutex: std.Thread.Mutex = .{};
    var state: enum { uninitialized, ready, failed } = .uninitialized;
    var bundle: Certificate.Bundle = .{};

    fn get() RequestError!Certificate.Bundle {
        mutex.lock();
        defer mutex.unlock();

        switch (state) {
            .ready => return bundle,
            .failed => return error.CaBundleLoadFailed,
            .uninitialized => {
                bundle.rescan(std.heap.page_allocator) catch {
                    state = .failed;
                    return error.CaBundleLoadFailed;
                };
                state = .ready;
                return bundle;
            },
        }
    }
};

/// Process-wide verified CA bundle, lazily scanned from the system trust
/// store and cached. Returns `error.CaBundleLoadFailed` if the system
/// certificate store cannot be loaded — callers MUST fail closed rather
/// than fall back to unverified TLS. Used by non-HTTP TLS clients (e.g.
/// the email channel's IMAP/SMTP connections) so they verify certificates
/// against the same trust anchor as the HTTP transport.
pub fn sharedCaBundle() RequestError!Certificate.Bundle {
    return shared_ca_bundle.get();
}

pub const RequestError = error{
    UnsupportedScheme,
    MissingHost,
    UnsupportedProxy,
    HeaderTooLarge,
    ResponseTooLarge,
    InvalidHttpResponse,
    InvalidChunkedEncoding,
    AddressResolveFailed,
    TcpConnectFailed,
    SocketTimeoutFailed,
    TlsInitializationFailed,
    TlsReadFailed,
    TlsWriteFailed,
    CaBundleLoadFailed,
} || std.mem.Allocator.Error || std.Uri.ParseError || net_security.ResolveConnectHostError || std.fmt.ParseIntError;

pub const NotImplementedError = error{NotImplemented};

pub const TransportManager = struct {
    allocator: std.mem.Allocator,
    config: TransportConfig,

    pub fn init(allocator: std.mem.Allocator, config: TransportConfig) TransportManager {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *TransportManager) void {
        _ = self;
    }

    pub fn request(self: *TransportManager, allocator: std.mem.Allocator, options: RequestOptions) RequestError!Response {
        _ = self;
        return root_request(allocator, options);
    }
};

const ParsedRequest = struct {
    scheme: RequestScheme,
    authority_host: []const u8,
    connect_host: []const u8,
    tls_host: []const u8,
    port: u16,
    request_target: []u8,
    host_header: []u8,

    fn deinit(self: ParsedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.request_target);
        allocator.free(self.host_header);
    }
};

pub fn request(allocator: std.mem.Allocator, options: RequestOptions) RequestError!Response {
    return root_request(allocator, options);
}

pub fn stream_body(
    allocator: std.mem.Allocator,
    options: RequestOptions,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!u16 {
    return root_stream_body(allocator, options, ctx, on_chunk);
}

fn root_request(allocator: std.mem.Allocator, options: RequestOptions) RequestError!Response {
    if (options.proxy != null) return error.UnsupportedProxy;

    const parsed = try parse_request(allocator, options);
    defer parsed.deinit(allocator);

    const is_tls = parsed.scheme == .https;
    const pool = getPool();

    // ── Try to acquire a pooled connection ───────────────────────────────────
    const pooled = pool.acquire(parsed.connect_host, parsed.port, is_tls);
    const reused = pooled != null;

    // ── Open a fresh connection if pool missed ───────────────────────────────
    var stream: std.net.Stream = undefined;
    var tls_state: ?*TlsIoState = null;

    if (pooled) |pc| {
        stream = pc.stream;
        if (pc.tls_state) |op| tls_state = @ptrCast(@alignCast(op));
    } else {
        const addr = try resolve_connect_address(allocator, parsed.connect_host, parsed.port);
        stream = std.net.tcpConnectToAddress(addr) catch return error.TcpConnectFailed;
        if (is_tls) {
            const bundle = try shared_ca_bundle.get();
            tls_state = TlsIoState.init(allocator, stream, parsed.tls_host, bundle) catch |err| {
                stream.close();
                return err;
            };
        }
    }

    // On any error: if we opened a fresh connection, close it.
    // If we reused a pooled one, also close (stale connection).
    errdefer {
        if (tls_state) |tls| tls.deinit(allocator);
        stream.close();
    }

    apply_timeouts(stream, options.timeout_ms) catch return error.SocketTimeoutFailed;

    var raw_response = std.ArrayListUnmanaged(u8).empty;
    defer raw_response.deinit(allocator);

    if (is_tls) {
        try request_tls_with_state(allocator, &raw_response, tls_state.?, parsed, options);
    } else {
        try request_plain(allocator, &raw_response, stream, parsed, options);
    }

    // ── Parse response and decide pooling ────────────────────────────────────
    var parsed_resp = try parse_http_response_poolable(allocator, raw_response.items, options.max_response_bytes);
    parsed_resp.response.reused_connection = reused;

    // Only pool if:
    //  1. Response had explicit body boundary (Content-Length or chunked)
    //  2. Server did not send Connection: close
    if (parsed_resp.poolable and !parsed_resp.server_close) {
        const served: u32 = if (pooled) |pc| pc.requests_served + 1 else 1;
        const created: i64 = if (pooled) |pc| pc.created_at_s else std.time.timestamp();
        pool.release(parsed.connect_host, parsed.port, is_tls, .{
            .stream = stream,
            .tls_state = if (tls_state) |tls| @ptrCast(tls) else null,
            .created_at_s = created,
            .requests_served = served,
            .is_tls = is_tls,
        });
    } else {
        // Close (either not poolable or server wants close).
        if (tls_state) |tls| tls.deinit(allocator);
        stream.close();
    }

    return parsed_resp.response;
}

fn root_stream_body(
    allocator: std.mem.Allocator,
    options: RequestOptions,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!u16 {
    if (options.proxy != null) return error.UnsupportedProxy;

    const parsed = try parse_request(allocator, options);
    defer parsed.deinit(allocator);

    const addr = try resolve_connect_address(allocator, parsed.connect_host, parsed.port);
    const stream = std.net.tcpConnectToAddress(addr) catch return error.TcpConnectFailed;
    defer stream.close();

    apply_timeouts(stream, options.timeout_ms) catch return error.SocketTimeoutFailed;

    if (parsed.scheme == .https) {
        return try stream_tls_body(allocator, stream, parsed, options, ctx, on_chunk);
    }
    return try stream_plain_body(allocator, stream, parsed, options, ctx, on_chunk);
}

fn request_plain(
    allocator: std.mem.Allocator,
    raw_response: *std.ArrayListUnmanaged(u8),
    stream: std.net.Stream,
    parsed: ParsedRequest,
    options: RequestOptions,
) RequestError!void {
    const request_bytes = try build_request(allocator, parsed, options);
    defer allocator.free(request_bytes);

    stream.writeAll(request_bytes) catch return error.TlsWriteFailed;
    try read_to_eof_plain(allocator, raw_response, stream, options.max_response_bytes);
}

fn resolve_connect_address(allocator: std.mem.Allocator, host: []const u8, port: u16) RequestError!std.net.Address {
    return std.net.Address.parseIp(host, port) catch {
        var addrs = std.net.getAddressList(allocator, host, port) catch return error.AddressResolveFailed;
        defer addrs.deinit();
        if (addrs.addrs.len == 0) return error.AddressResolveFailed;
        return addrs.addrs[0];
    };
}

fn stream_plain_body(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    parsed: ParsedRequest,
    options: RequestOptions,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!u16 {
    const request_bytes = try build_request(allocator, parsed, options);
    defer allocator.free(request_bytes);

    stream.writeAll(request_bytes) catch return error.TlsWriteFailed;

    return try stream_http_body_from_reader(allocator, plain_read_fn, stream, options.max_response_bytes, ctx, on_chunk);
}

fn request_tls(
    allocator: std.mem.Allocator,
    raw_response: *std.ArrayListUnmanaged(u8),
    stream: std.net.Stream,
    parsed: ParsedRequest,
    options: RequestOptions,
) RequestError!void {
    const bundle = try shared_ca_bundle.get();
    const tls = try TlsIoState.init(allocator, stream, parsed.tls_host, bundle);
    defer tls.deinit(allocator);

    const request_bytes = try build_request(allocator, parsed, options);
    defer allocator.free(request_bytes);

    tls.tls_client.writer.writeAll(request_bytes) catch return error.TlsWriteFailed;
    tls.tls_client.writer.flush() catch return error.TlsWriteFailed;
    tls.stream_writer.interface.flush() catch return error.TlsWriteFailed;

    try read_to_eof_tls(allocator, raw_response, &tls.tls_client, options.max_response_bytes);

    tls.tls_client.end() catch {};
    tls.stream_writer.interface.flush() catch {};
}

/// Like request_tls but reuses an existing TlsIoState (from pool).
/// Does NOT call tls.deinit — caller owns the TlsIoState.
fn request_tls_with_state(
    allocator: std.mem.Allocator,
    raw_response: *std.ArrayListUnmanaged(u8),
    tls: *TlsIoState,
    parsed: ParsedRequest,
    options: RequestOptions,
) RequestError!void {
    const request_bytes = try build_request(allocator, parsed, options);
    defer allocator.free(request_bytes);

    tls.tls_client.writer.writeAll(request_bytes) catch return error.TlsWriteFailed;
    tls.tls_client.writer.flush() catch return error.TlsWriteFailed;
    tls.stream_writer.interface.flush() catch return error.TlsWriteFailed;

    // Use EOF reading here — the raw bytes will be parsed by parse_http_response_poolable.
    try read_to_eof_tls(allocator, raw_response, &tls.tls_client, options.max_response_bytes);
}

fn stream_tls_body(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    parsed: ParsedRequest,
    options: RequestOptions,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!u16 {
    const bundle = try shared_ca_bundle.get();
    const tls = try TlsIoState.init(allocator, stream, parsed.tls_host, bundle);
    defer tls.deinit(allocator);

    const request_bytes = try build_request(allocator, parsed, options);
    defer allocator.free(request_bytes);

    tls.tls_client.writer.writeAll(request_bytes) catch return error.TlsWriteFailed;
    tls.tls_client.writer.flush() catch return error.TlsWriteFailed;
    tls.stream_writer.interface.flush() catch return error.TlsWriteFailed;

    const status_code = try stream_http_body_from_reader(allocator, tls_read_fn, &tls.tls_client, options.max_response_bytes, ctx, on_chunk);

    tls.tls_client.end() catch {};
    tls.stream_writer.interface.flush() catch {};
    return status_code;
}

fn build_request(
    allocator: std.mem.Allocator,
    parsed: ParsedRequest,
    options: RequestOptions,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print("{s} {s} HTTP/1.1\r\n", .{ options.method, parsed.request_target });
    try writer.print("Host: {s}\r\n", .{parsed.host_header});
    try writer.writeAll("Connection: close\r\n");
    try writer.writeAll("User-Agent: nullalis-native/0.1\r\n");

    for (options.headers) |header| {
        if (header_is_managed(header)) continue;
        try writer.print("{s}\r\n", .{header});
    }

    if (options.body) |body| {
        try writer.print("Content-Length: {d}\r\n", .{body.len});
    }

    try writer.writeAll("\r\n");
    if (options.body) |body| try writer.writeAll(body);

    return try buf.toOwnedSlice(allocator);
}

fn parse_request(allocator: std.mem.Allocator, options: RequestOptions) RequestError!ParsedRequest {
    const uri = try std.Uri.parse(options.url);
    const authority_source = options.resolve_host orelse net_security.extractHost(options.url) orelse return error.MissingHost;
    const connect_source = options.connect_host orelse authority_source;

    const scheme: RequestScheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        .https
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
        .http
    else
        return error.UnsupportedScheme;

    const default_port: u16 = if (scheme == .https) 443 else 80;
    const port = if (options.resolve_port != 0) options.resolve_port else uri.port orelse default_port;
    const request_target = try build_request_target(allocator, uri);
    const host_header = try build_host_header(allocator, authority_source, port, default_port);

    return .{
        .scheme = scheme,
        .authority_host = authority_source,
        .connect_host = connect_source,
        .tls_host = strip_host_brackets(authority_source),
        .port = port,
        .request_target = request_target,
        .host_header = host_header,
    };
}

fn build_request_target(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const raw_path = component_as_slice(uri.path);
    const query = if (uri.query) |q| component_as_slice(q) else "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    if (raw_path.len == 0) {
        try writer.writeByte('/');
    } else {
        if (raw_path[0] != '/') try writer.writeByte('/');
        try writer.writeAll(raw_path);
    }

    if (query.len > 0) {
        try writer.writeByte('?');
        try writer.writeAll(query);
    }

    return try buf.toOwnedSlice(allocator);
}

fn build_host_header(allocator: std.mem.Allocator, host: []const u8, port: u16, default_port: u16) ![]u8 {
    const needs_brackets = std.mem.indexOfScalar(u8, host, ':') != null and !std.mem.startsWith(u8, host, "[");
    const bracketed_host = if (needs_brackets) blk: {
        break :blk try std.fmt.allocPrint(allocator, "[{s}]", .{host});
    } else try allocator.dupe(u8, host);
    defer allocator.free(bracketed_host);

    if (port == default_port) return try allocator.dupe(u8, bracketed_host);
    return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ bracketed_host, port });
}

fn component_as_slice(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
}

fn strip_host_brackets(host: []const u8) []const u8 {
    if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) {
        return host[1 .. host.len - 1];
    }
    return host;
}

fn header_is_managed(header: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(header, "host:") or
        std.ascii.startsWithIgnoreCase(header, "connection:") or
        std.ascii.startsWithIgnoreCase(header, "content-length:");
}

fn apply_timeouts(stream: std.net.Stream, timeout_ms: u32) !void {
    const timeout = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.c.SO.SNDTIMEO, std.mem.asBytes(&timeout));
}

fn read_to_eof_plain(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    stream: std.net.Stream,
    max_response_bytes: usize,
) RequestError!void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch return error.TlsReadFailed;
        if (n == 0) break;
        if (out.items.len + n > max_response_bytes + 16 * 1024) return error.ResponseTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }
}

fn read_to_eof_tls(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tls_client: *std.crypto.tls.Client,
    max_response_bytes: usize,
) RequestError!void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try tls_read_fn(tls_client, &buf);
        if (n == 0) break;
        if (out.items.len + n > max_response_bytes + 16 * 1024) return error.ResponseTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }
}

fn parse_http_response(allocator: std.mem.Allocator, raw: []const u8, max_response_bytes: usize) RequestError!Response {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const header_block = raw[0..header_end];
    const body_block = raw[header_end + 4 ..];

    const line_end = std.mem.indexOf(u8, header_block, "\r\n") orelse header_block.len;
    const status_line = header_block[0..line_end];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 ")) {
        return error.InvalidHttpResponse;
    }

    const status_slice = if (status_line.len >= 12) status_line[9..12] else return error.InvalidHttpResponse;
    const status_code = try std.fmt.parseInt(u16, status_slice, 10);

    var transfer_chunked = false;
    var content_length: ?usize = null;

    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            transfer_chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }

    const response_body = if (transfer_chunked)
        try decode_chunked_body(allocator, body_block, max_response_bytes)
    else if (content_length) |len| blk: {
        if (len > max_response_bytes) return error.ResponseTooLarge;
        if (body_block.len < len) return error.InvalidHttpResponse;
        break :blk try allocator.dupe(u8, body_block[0..len]);
    } else blk: {
        if (body_block.len > max_response_bytes) return error.ResponseTooLarge;
        break :blk try allocator.dupe(u8, body_block);
    };

    return .{
        .status_code = status_code,
        .body = response_body,
        .reused_connection = false,
    };
}

/// Result from parse_http_response_poolable.
const ParsedResponse = struct {
    response: Response,
    /// True if the body boundary is explicit (Content-Length or chunked).
    /// Only poolable responses consumed exactly the right bytes.
    poolable: bool,
    /// True if the server sent Connection: close.
    server_close: bool,
};

/// Extended parser that also returns pooling metadata.
fn parse_http_response_poolable(allocator: std.mem.Allocator, raw: []const u8, max_response_bytes: usize) RequestError!ParsedResponse {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const header_block = raw[0..header_end];
    const body_block = raw[header_end + 4 ..];

    const line_end = std.mem.indexOf(u8, header_block, "\r\n") orelse header_block.len;
    const status_line = header_block[0..line_end];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 ")) {
        return error.InvalidHttpResponse;
    }

    const status_slice = if (status_line.len >= 12) status_line[9..12] else return error.InvalidHttpResponse;
    const status_code = try std.fmt.parseInt(u16, status_slice, 10);

    var transfer_chunked = false;
    var content_length: ?usize = null;
    var server_close = false;

    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            transfer_chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "close")) {
                server_close = true;
            }
        }
    }

    // poolable only if we have an explicit boundary
    const poolable = transfer_chunked or content_length != null;

    const response_body = if (transfer_chunked)
        try decode_chunked_body(allocator, body_block, max_response_bytes)
    else if (content_length) |len| blk: {
        if (len > max_response_bytes) return error.ResponseTooLarge;
        if (body_block.len < len) return error.InvalidHttpResponse;
        break :blk try allocator.dupe(u8, body_block[0..len]);
    } else blk: {
        // EOF-terminated: body not explicitly bounded, cannot pool.
        if (body_block.len > max_response_bytes) return error.ResponseTooLarge;
        break :blk try allocator.dupe(u8, body_block);
    };

    return .{
        .response = .{
            .status_code = status_code,
            .body = response_body,
            .reused_connection = false,
        },
        .poolable = poolable,
        .server_close = server_close,
    };
}

fn decode_chunked_body(allocator: std.mem.Allocator, body: []const u8, max_response_bytes: usize) RequestError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (true) {
        const line_end_rel = std.mem.indexOf(u8, body[index..], "\r\n") orelse return error.InvalidChunkedEncoding;
        const line = body[index .. index + line_end_rel];
        index += line_end_rel + 2;

        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const size_str = std.mem.trim(u8, line[0..semi], " \t");
        const chunk_len = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidChunkedEncoding;

        if (chunk_len == 0) {
            if (index + 2 <= body.len and std.mem.eql(u8, body[index..@min(index + 2, body.len)], "\r\n")) {
                index += 2;
            }
            break;
        }

        if (index + chunk_len + 2 > body.len) return error.InvalidChunkedEncoding;
        if (out.items.len + chunk_len > max_response_bytes) return error.ResponseTooLarge;
        try out.appendSlice(allocator, body[index .. index + chunk_len]);
        index += chunk_len;

        if (!std.mem.eql(u8, body[index .. index + 2], "\r\n")) return error.InvalidChunkedEncoding;
        index += 2;
    }

    return try out.toOwnedSlice(allocator);
}

fn plain_read_fn(stream: std.net.Stream, buf: []u8) RequestError!usize {
    return stream.read(buf) catch return error.TlsReadFailed;
}

fn tls_read_fn(tls_client: *std.crypto.tls.Client, buf: []u8) RequestError!usize {
    if (buf.len == 0) return 0;

    var total: usize = 0;

    if (tls_client.reader.bufferedLen() == 0) {
        const first = tls_client.reader.take(1) catch |read_err| switch (read_err) {
            error.EndOfStream => return 0,
            else => return error.TlsReadFailed,
        };
        if (first.len == 0) return 0;
        buf[0] = first[0];
        total = 1;
    }

    while (total < buf.len) {
        const buffered = tls_client.reader.bufferedLen();
        if (buffered == 0) break;
        const to_copy = @min(buffered, buf.len - total);
        const chunk = tls_client.reader.take(to_copy) catch |read_err| switch (read_err) {
            error.EndOfStream => break,
            else => return error.TlsReadFailed,
        };
        if (chunk.len == 0) break;
        @memcpy(buf[total .. total + chunk.len], chunk);
        total += chunk.len;
    }

    return total;
}

fn stream_http_body_from_reader(
    allocator: std.mem.Allocator,
    comptime read_fn: anytype,
    reader: anytype,
    max_response_bytes: usize,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!u16 {
    var header_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer header_buf.deinit(allocator);

    var tmp: [4096]u8 = undefined;
    var body_start_index: usize = 0;

    while (std.mem.indexOf(u8, header_buf.items, "\r\n\r\n") == null) {
        const n = try read_fn(reader, &tmp);
        if (n == 0) return error.InvalidHttpResponse;
        if (header_buf.items.len + n > 16 * 1024) return error.HeaderTooLarge;
        try header_buf.appendSlice(allocator, tmp[0..n]);
    }

    const header_end = std.mem.indexOf(u8, header_buf.items, "\r\n\r\n").?;
    body_start_index = header_end + 4;
    const header_block = header_buf.items[0..header_end];
    const status_code = try parse_status_code(header_block);

    var transfer_chunked = false;
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            transfer_chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }

    const initial_body = header_buf.items[body_start_index..];
    if (transfer_chunked) {
        try stream_chunked_body(allocator, read_fn, reader, initial_body, max_response_bytes, ctx, on_chunk);
    } else if (content_length) |len| {
        try stream_sized_body(allocator, read_fn, reader, initial_body, len, max_response_bytes, ctx, on_chunk);
    } else {
        try stream_eof_body(read_fn, reader, initial_body, max_response_bytes, ctx, on_chunk);
    }

    return status_code;
}

fn parse_status_code(header_block: []const u8) RequestError!u16 {
    const line_end = std.mem.indexOf(u8, header_block, "\r\n") orelse header_block.len;
    const status_line = header_block[0..line_end];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 ")) {
        return error.InvalidHttpResponse;
    }
    const status_slice = if (status_line.len >= 12) status_line[9..12] else return error.InvalidHttpResponse;
    return try std.fmt.parseInt(u16, status_slice, 10);
}

fn stream_sized_body(
    _: std.mem.Allocator,
    comptime read_fn: anytype,
    reader: anytype,
    initial_body: []const u8,
    content_length: usize,
    max_response_bytes: usize,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!void {
    if (content_length > max_response_bytes) return error.ResponseTooLarge;

    var remaining = content_length;
    if (initial_body.len > 0) {
        const first = initial_body[0..@min(initial_body.len, remaining)];
        if (!(try on_chunk(ctx, first))) return;
        remaining -= first.len;
    }

    var tmp: [4096]u8 = undefined;
    while (remaining > 0) {
        const to_read = @min(tmp.len, remaining);
        const n = try read_fn(reader, tmp[0..to_read]);
        if (n == 0) return error.InvalidHttpResponse;
        if (!(try on_chunk(ctx, tmp[0..n]))) return;
        remaining -= n;
    }
}

fn stream_eof_body(
    comptime read_fn: anytype,
    reader: anytype,
    initial_body: []const u8,
    max_response_bytes: usize,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!void {
    var total: usize = 0;
    if (initial_body.len > 0) {
        total += initial_body.len;
        if (total > max_response_bytes) return error.ResponseTooLarge;
        if (!(try on_chunk(ctx, initial_body))) return;
    }

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try read_fn(reader, &tmp);
        if (n == 0) break;
        total += n;
        if (total > max_response_bytes) return error.ResponseTooLarge;
        if (!(try on_chunk(ctx, tmp[0..n]))) return;
    }
}

fn stream_chunked_body(
    allocator: std.mem.Allocator,
    comptime read_fn: anytype,
    reader: anytype,
    initial_body: []const u8,
    max_response_bytes: usize,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) anyerror!void {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, initial_body);

    var total: usize = 0;
    var tmp: [4096]u8 = undefined;

    while (true) {
        while (true) {
            const line_end = std.mem.indexOf(u8, buffer.items, "\r\n") orelse break;
            const size_line = buffer.items[0..line_end];
            const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
            const size_str = std.mem.trim(u8, size_line[0..semi], " \t");
            const chunk_len = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidChunkedEncoding;

            const frame_len = line_end + 2 + chunk_len + 2;
            if (buffer.items.len < frame_len) break;

            if (chunk_len == 0) return;

            const chunk_start = line_end + 2;
            const chunk = buffer.items[chunk_start .. chunk_start + chunk_len];
            total += chunk.len;
            if (total > max_response_bytes) return error.ResponseTooLarge;
            if (!(try on_chunk(ctx, chunk))) return;

            if (!std.mem.eql(u8, buffer.items[chunk_start + chunk_len .. chunk_start + chunk_len + 2], "\r\n")) {
                return error.InvalidChunkedEncoding;
            }

            const remaining = buffer.items[frame_len..];
            std.mem.copyForwards(u8, buffer.items[0..remaining.len], remaining);
            buffer.shrinkRetainingCapacity(remaining.len);
        }

        const n = try read_fn(reader, &tmp);
        if (n == 0) return error.InvalidChunkedEncoding;
        try buffer.appendSlice(allocator, tmp[0..n]);
    }
}

fn serve_once(server: *std.net.Server, response: []const u8) !void {
    const conn = try server.accept();
    defer conn.stream.close();

    var request_buf: [4096]u8 = undefined;
    _ = try conn.stream.read(&request_buf);
    try conn.stream.writeAll(response);
}

test "transport defaults are sane" {
    const cfg = TransportConfig{};
    try std.testing.expectEqual(TransportMode.native_preferred, cfg.mode);
    try std.testing.expectEqual(@as(u16, 24), cfg.providers.max_connections);
    try std.testing.expectEqual(@as(u8, 2), cfg.resolver.threads);
}

test "transport manager init is stable" {
    var manager = TransportManager.init(std.testing.allocator, .{});
    defer manager.deinit();
    try std.testing.expectEqual(TransportMode.native_preferred, manager.config.mode);
}

test "native http request handles content-length response" {
    const addr = try std.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, serve_once, .{ &server, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello" });
    defer thread.join();

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/hello", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);

    const response = try request(std.testing.allocator, .{
        .method = "GET",
        .url = url,
        .timeout_ms = 5_000,
        .max_response_bytes = 1024,
        .subsystem = .tools,
    });
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("hello", response.body);
}

test "native http request decodes chunked response" {
    const addr = try std.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const chunked =
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n";
    const thread = try std.Thread.spawn(.{}, serve_once, .{ &server, chunked });
    defer thread.join();

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chunked", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);

    const response = try request(std.testing.allocator, .{
        .method = "GET",
        .url = url,
        .timeout_ms = 5_000,
        .max_response_bytes = 1024,
        .subsystem = .tools,
    });
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("hello world", response.body);
}

test "native http request resolves localhost hostname" {
    var addrs = try std.net.getAddressList(std.testing.allocator, "localhost", 0);
    defer addrs.deinit();
    var server = try addrs.addrs[0].listen(.{ .reuse_address = true });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, serve_once, .{ &server, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" });
    defer thread.join();

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://localhost:{d}/host", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);

    const response = try request(std.testing.allocator, .{
        .method = "GET",
        .url = url,
        .timeout_ms = 5_000,
        .max_response_bytes = 1024,
        .subsystem = .tools,
    });
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("ok", response.body);
}
