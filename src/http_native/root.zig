const std = @import("std");
const net_security = @import("../net_security.zig");
pub const types = @import("types.zig");

pub const TransportMode = types.TransportMode;
pub const TransportSubsystem = types.TransportSubsystem;
pub const PoolConfig = types.PoolConfig;
pub const ResolverConfig = types.ResolverConfig;
pub const RequestOptions = types.RequestOptions;
pub const Response = types.Response;
pub const TransportConfig = types.TransportConfig;

const Certificate = std.crypto.Certificate;
const RequestScheme = enum { http, https };

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

fn root_request(allocator: std.mem.Allocator, options: RequestOptions) RequestError!Response {
    if (options.proxy != null) return error.UnsupportedProxy;

    const parsed = try parse_request(allocator, options);
    defer parsed.deinit(allocator);

    const addr = std.net.Address.resolveIp(parsed.connect_host, parsed.port) catch return error.AddressResolveFailed;
    const stream = std.net.tcpConnectToAddress(addr) catch return error.TcpConnectFailed;
    defer stream.close();

    apply_timeouts(stream, options.timeout_ms) catch return error.SocketTimeoutFailed;

    var raw_response = std.ArrayListUnmanaged(u8).empty;
    defer raw_response.deinit(allocator);

    if (parsed.scheme == .https) {
        try request_tls(allocator, &raw_response, stream, parsed, options);
    } else {
        try request_plain(allocator, &raw_response, stream, parsed, options);
    }

    return try parse_http_response(allocator, raw_response.items, options.max_response_bytes);
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

fn request_tls(
    allocator: std.mem.Allocator,
    raw_response: *std.ArrayListUnmanaged(u8),
    stream: std.net.Stream,
    parsed: ParsedRequest,
    options: RequestOptions,
) RequestError!void {
    const tls_buf_len = std.crypto.tls.Client.min_buffer_len;
    const read_buf = try allocator.alloc(u8, tls_buf_len);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, tls_buf_len);
    defer allocator.free(write_buf);
    const tls_read_buf = try allocator.alloc(u8, tls_buf_len);
    defer allocator.free(tls_read_buf);
    const tls_write_buf = try allocator.alloc(u8, tls_buf_len);
    defer allocator.free(tls_write_buf);

    var bundle: Certificate.Bundle = .{};
    defer bundle.deinit(allocator);
    bundle.rescan(allocator) catch return error.CaBundleLoadFailed;

    var stream_reader = stream.reader(read_buf);
    var stream_writer = stream.writer(write_buf);
    var tls_client = std.crypto.tls.Client.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = parsed.tls_host },
            .ca = .{ .bundle = bundle },
            .read_buffer = tls_read_buf,
            .write_buffer = tls_write_buf,
            .allow_truncation_attacks = true,
        },
    ) catch return error.TlsInitializationFailed;

    const request_bytes = try build_request(allocator, parsed, options);
    defer allocator.free(request_bytes);

    tls_client.writer.writeAll(request_bytes) catch return error.TlsWriteFailed;
    tls_client.writer.flush() catch return error.TlsWriteFailed;
    stream_writer.interface.flush() catch return error.TlsWriteFailed;

    try read_to_eof_tls(allocator, raw_response, &tls_client, options.max_response_bytes);

    tls_client.end() catch {};
    stream_writer.interface.flush() catch {};
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
        var vecs: [1][]u8 = .{buf[0..]};
        const n = tls_client.reader.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return error.TlsReadFailed,
        };
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
