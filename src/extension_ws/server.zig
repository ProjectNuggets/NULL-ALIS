//! RFC 6455 §1.3 server-side WebSocket handshake + frame loop for the
//! nullalis browser extension endpoint (`/api/v1/extension/ws`).
//!
//! This module is the SERVER side of `src/websocket.zig` (which is the
//! outbound client used by Discord/Slack gateways). Three reasons to keep
//! the two split:
//!   1. Server-side frames are NOT masked when written (RFC §5.3); client
//!      frames MUST be masked. Sharing one writer would either break the
//!      RFC or carry a runtime "is_server" toggle that's easy to mis-set.
//!   2. The server-side handshake is HTTP-over-plain-TCP (the upstream
//!      TLS termination is done by the operator's reverse proxy in
//!      production). The client side is fused to a TLS state machine.
//!   3. Connection lifecycle is asymmetric: server accepts an existing
//!      `std.net.Server.Connection.stream`; client opens a fresh
//!      `std.net.tcpConnectToAddress`.
//!
//! Pure utilities (`computeAccept`, `parseUpgradeRequest`,
//! `buildAcceptResponse`) are testable without sockets. The live
//! `handleUpgrade` entry point is exercised in
//! `extension_ws/handshake_test.zig` via an in-memory bidirectional pipe.

const std = @import("std");
const websocket = @import("../websocket.zig");
const auth_mod = @import("auth.zig");
const hub_mod = @import("hub.zig");

const log = std.log.scoped(.extension_ws);

/// Parsed Upgrade request fields the server needs to validate before
/// completing the handshake. `key` and `version` borrow from the raw
/// request buffer — caller controls that buffer's lifetime.
pub const UpgradeRequest = struct {
    /// Sec-WebSocket-Key header value (24-char base64 of 16 random bytes).
    key: []const u8,
    /// Sec-WebSocket-Version header value. RFC 6455 fixes this at "13".
    version: []const u8,
    /// True iff `Upgrade: websocket` is present (case-insensitive).
    has_upgrade: bool,
};

pub const UpgradeParseError = error{
    MissingUpgradeHeader,
    MissingSecWebSocketKey,
    UnsupportedSecWebSocketVersion,
};

/// Parse an HTTP request to extract the WebSocket upgrade fields.
/// Returns an UpgradeRequest if the request is well-formed for an
/// `Upgrade: websocket` handshake. The caller has already verified
/// the request line targets `/api/v1/extension/ws`; this function
/// only validates the upgrade-relevant headers.
///
/// RFC 6455 §4.2.1 mandates `Sec-WebSocket-Version: 13`. Any other
/// version yields `UnsupportedSecWebSocketVersion` so the gateway can
/// respond `400 Bad Request` with a clear reason (the contract doc
/// references this so operators can debug stale browser builds).
pub fn parseUpgradeRequest(raw: []const u8) UpgradeParseError!UpgradeRequest {
    const upgrade_hdr = extractHeader(raw, "Upgrade") orelse return error.MissingUpgradeHeader;
    if (!asciiEqlIgnoreCase(std.mem.trim(u8, upgrade_hdr, " \t"), "websocket")) {
        return error.MissingUpgradeHeader;
    }

    const key = extractHeader(raw, "Sec-WebSocket-Key") orelse return error.MissingSecWebSocketKey;
    const key_trimmed = std.mem.trim(u8, key, " \t");
    if (key_trimmed.len == 0) return error.MissingSecWebSocketKey;

    const version = extractHeader(raw, "Sec-WebSocket-Version") orelse return error.UnsupportedSecWebSocketVersion;
    const version_trimmed = std.mem.trim(u8, version, " \t");
    if (!std.mem.eql(u8, version_trimmed, "13")) return error.UnsupportedSecWebSocketVersion;

    return UpgradeRequest{
        .key = key_trimmed,
        .version = version_trimmed,
        .has_upgrade = true,
    };
}

/// Compute `Sec-WebSocket-Accept` for a given client key (RFC 6455 §1.3).
/// Forwards to the existing `websocket.WsClient.computeAcceptKey` so the
/// server and client speak the same crypto.
pub fn computeAccept(key: []const u8) [28]u8 {
    return websocket.WsClient.computeAcceptKey(key);
}

/// Format the HTTP 101 Switching Protocols response body into `buf`.
/// Returns the populated slice (caller writes it to the socket as a
/// single `writeAll`). The fixed 256-byte buffer is sufficient: the
/// response is 4 short lines + the 28-char accept value.
pub fn buildAcceptResponse(buf: []u8, accept: [28]u8) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n",
        .{accept},
    );
}

/// Format a `400 Bad Request` rejection for malformed upgrade requests.
/// `reason` lands in the body verbatim so operators reading the
/// extension popup or proxy logs can tell why the gateway refused.
pub fn buildRejectResponse(buf: []u8, reason: []const u8) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        "HTTP/1.1 400 Bad Request\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ reason.len, reason },
    );
}

// ── Frame I/O on a raw stream (server-side, NO outbound mask) ─────────

/// Read one WebSocket frame from the stream.
/// Returns null on graceful close (close opcode). On non-payload frames
/// (ping/pong/close) the function processes them and returns null for
/// close, or a Frame{.ping/.pong} marker with empty payload so callers
/// can implement heartbeat policy. Text/binary frames return
/// heap-allocated payloads — caller frees via `allocator.free(p.payload)`
/// when `payload.len > 0`.
pub fn readFrame(allocator: std.mem.Allocator, stream: anytype) !?Frame {
    var hdr: [2]u8 = undefined;
    try readExact(stream, &hdr);

    const fin = (hdr[0] & 0x80) != 0;
    const opcode: websocket.Opcode = @enumFromInt(hdr[0] & 0x0F);
    const is_masked = (hdr[1] & 0x80) != 0;

    // RFC 6455 §5.1: client-to-server frames MUST be masked. Reject
    // unmasked frames as a protocol violation — they're either a
    // misconfigured client (server framing leaked into client code) or
    // an attack (an unmasked frame can confuse intermediaries).
    if (!is_masked) return error.UnmaskedClientFrame;

    var payload_len: u64 = hdr[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = (@as(u64, ext[0]) << 8) | ext[1];
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = 0;
        for (ext) |b| payload_len = (payload_len << 8) | b;
    }

    var mask: [4]u8 = undefined;
    try readExact(stream, &mask);

    if (payload_len > MAX_FRAME_PAYLOAD) return error.FrameTooLarge;
    const plen: usize = @intCast(payload_len);

    const payload: []u8 = if (plen > 0) blk: {
        const p = try allocator.alloc(u8, plen);
        errdefer allocator.free(p);
        try readExact(stream, p);
        websocket.applyMask(p, mask);
        break :blk p;
    } else &[_]u8{};

    return Frame{
        .opcode = opcode,
        .fin = fin,
        .payload = payload,
    };
}

/// Server-side: write a frame WITHOUT masking (RFC 6455 §5.3 — only
/// client→server frames are masked). Single contiguous write so we
/// don't interleave header and payload with another writer thread.
pub fn writeFrame(allocator: std.mem.Allocator, stream: anytype, opcode: websocket.Opcode, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var hlen: usize = 0;
    header[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    hlen = 1;

    const plen = payload.len;
    if (plen <= 125) {
        header[1] = @as(u8, @intCast(plen));
        hlen += 1;
    } else if (plen <= 65535) {
        header[1] = 126;
        header[2] = @as(u8, @intCast((plen >> 8) & 0xFF));
        header[3] = @as(u8, @intCast(plen & 0xFF));
        hlen += 3;
    } else {
        header[1] = 127;
        const p64: u64 = plen;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            header[2 + i] = @as(u8, @intCast((p64 >> @intCast((7 - i) * 8)) & 0xFF));
        }
        hlen += 9;
    }

    // Combine header + payload into one buffer so the write hits the
    // socket atomically. Avoids partial-frame interleave with the
    // hub's command dispatcher writes.
    const total = try allocator.alloc(u8, hlen + plen);
    defer allocator.free(total);
    @memcpy(total[0..hlen], header[0..hlen]);
    if (plen > 0) @memcpy(total[hlen..], payload);

    try writeAll(stream, total);
}

/// Convenience: send a UTF-8 text frame.
pub fn writeText(allocator: std.mem.Allocator, stream: anytype, text: []const u8) !void {
    return writeFrame(allocator, stream, .text, text);
}

/// RFC 6455 §5.5.1 close frame with optional close code.
/// The two-byte close code (big-endian uint16) is the first 2 bytes
/// of the close payload when present.
pub fn writeClose(allocator: std.mem.Allocator, stream: anytype, close_code: u16) !void {
    var payload: [2]u8 = .{
        @intCast((close_code >> 8) & 0xFF),
        @intCast(close_code & 0xFF),
    };
    try writeFrame(allocator, stream, .close, &payload);
}

pub const Frame = struct {
    opcode: websocket.Opcode,
    fin: bool,
    /// Heap-allocated when `payload.len > 0`. Caller frees with
    /// `allocator.free(payload)` after handling.
    payload: []u8,
};

/// Hard cap on inbound frame payload size. Larger frames are rejected
/// before the payload buffer is allocated — protects against a
/// pathological client trying to allocate gigabytes server-side.
///
/// WR-02 (v1.14.22 follow-up): raised 4 MB → 8 MB. The 4 MB cap was
/// chosen to match `websocket.zig`'s outbound client cap, but it
/// prevented full-page screenshots from `extension_screenshot` (which
/// produces base64-encoded PNGs that can run 3-5 MB after JSON envelope
/// overhead). The screenshot tool's description advertises a ~6 MB
/// cap (raised from 3 MB in v1.14.23 to match real-world page captures);
/// 8 MB on the transport gives ~1.3× headroom over the advertised tool
/// cap, enough for JSON envelope overhead. The DoS surface widens
/// proportionally but a per-connection 8 MB allocation is still a
/// reasonable server-side budget against authenticated extension peers.
///
/// MED-2 (v1.14.23 review): the prior comment still referenced the pre-
/// v1.14.23 "~3 MB" advertised cap. Updated to track the current tool
/// description.
pub const MAX_FRAME_PAYLOAD: u64 = 8 * 1024 * 1024;

// ── Header extraction (mirrors gateway.extractHeader semantics) ────────

/// Case-insensitive header lookup over a raw HTTP request buffer.
/// Mirrored from `gateway.extractHeader` to keep this module standalone
/// (no circular import into gateway.zig). A future refactor could lift
/// the helper into a shared `http_util` module — for now, two copies
/// is cheaper than introducing a new import edge.
pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + 1 < raw.len) {
        if (raw[pos] == '\r' and raw[pos + 1] == '\n') {
            pos += 2;
            break;
        }
        pos += 1;
    }
    while (pos < raw.len) {
        const line_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse break;
        const line = raw[pos .. pos + line_end];
        if (line.len == 0) break;
        if (line.len > name.len and line[name.len] == ':') {
            const header_name = line[0..name.len];
            if (asciiEqlIgnoreCase(header_name, name)) {
                var val_start: usize = name.len + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }
        pos += line_end + 2;
    }
    return null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Per-call deadline for auth-window + initial frame reads. The gateway's
/// listener socket is non-blocking; on `error.WouldBlock` we sleep
/// briefly and retry rather than fail immediately. Total wait is bounded
/// by AUTH_READ_DEADLINE_NS so a silent peer can't hold a slot forever.
const AUTH_READ_DEADLINE_NS: i128 = 30 * std.time.ns_per_s;
const READ_RETRY_SLEEP_NS: u64 = 10 * std.time.ns_per_ms;

/// META HIGH #1 (2026-05-25) — overall connection-age deadline for the
/// pre-auth window. A peer that completes the WS upgrade then sends
/// one tiny ping every 25s while never sending the auth frame would
/// otherwise hold a gateway slot forever. Track elapsed time from
/// the 101 ACK to auth_ack; if `> AUTH_WINDOW_DEADLINE_NS`, close-
/// 1008 with `auth_window_exceeded`. 60s is wide enough for slow
/// proxies + manual paste of a token, but bounded enough to defeat
/// slow-loris.
pub const AUTH_WINDOW_DEADLINE_NS: i128 = 60 * std.time.ns_per_s;

fn readExact(stream: anytype, buf: []u8) !void {
    var total: usize = 0;
    const start = std.time.nanoTimestamp();
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch |err| switch (err) {
            // 2026-05-25 (Wave 3B live-probe fix): gateway listener is
            // non-blocking; first WS frame after the 101 takes a moment
            // to arrive. Retry-with-sleep until data shows up or the
            // deadline passes, rather than fail-fast with WouldBlock.
            // Live probe caught this on every connection — auth_ack was
            // never sent because readExact returned WouldBlock on byte 0
            // of the auth frame.
            error.WouldBlock => {
                const elapsed = std.time.nanoTimestamp() - start;
                if (elapsed > AUTH_READ_DEADLINE_NS) return error.ReadDeadlineExceeded;
                std.Thread.sleep(READ_RETRY_SLEEP_NS);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

fn writeAll(stream: anytype, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try stream.write(bytes[offset..]);
        if (n == 0) return error.BrokenPipe;
        offset += n;
    }
}

// ── Live upgrade handler ──────────────────────────────────────────────

/// Generic adapter that pairs a stream of any type with an allocator
/// so the hub can invoke `writeText` / `close` through an opaque
/// pointer. Generated at comptime per stream type; the runtime cost is
/// a single indirect call per outbound frame.
///
/// The adapter is heap-allocated by `handleUpgrade` (so its address is
/// stable across the connection's lifetime) and freed when the
/// connection's defer chain runs.
pub fn StreamAdapter(comptime StreamT: type) type {
    return struct {
        const Self = @This();
        stream: StreamT,
        allocator: std.mem.Allocator,

        pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Use a write mutex via the hub — already serialized when
            // `sendCommand` holds `conn.write_mu`. Here we just emit
            // the framed bytes.
            return writeFrame(self.allocator, self.stream, .text, text);
        }

        pub fn close(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Best-effort close. `std.net.Stream.close` is infallible;
            // test streams set a flag.
            const StreamPtr = @TypeOf(self.stream);
            if (@typeInfo(StreamPtr) == .pointer) {
                if (@hasDecl(@typeInfo(StreamPtr).pointer.child, "close")) {
                    self.stream.close();
                    return;
                }
            }
            if (@hasDecl(StreamT, "close")) self.stream.close();
        }
    };
}

pub const UpgradeContext = struct {
    /// Long-lived allocator (outlives the connection) used to clone the
    /// `auth.user_id` and allocate the registered connection record. The
    /// per-frame loop uses a request-scoped allocator passed separately.
    long_allocator: std.mem.Allocator,
    /// The HTTP request bytes the gateway already read off the socket.
    raw_request: []const u8,
    /// Hub registry that will track this connection if auth succeeds.
    hub: *hub_mod.ExtensionWsHub,
    /// Token-validation policy: typically the gateway's
    /// `internal_service_tokens` slice.
    auth: auth_mod.AuthValidator,
};

pub const UpgradeOutcome = enum {
    /// Bad upgrade headers, missing/invalid SWK, or wrong version.
    /// The handler has already written a 400 response to the stream.
    bad_request,
    /// Upgrade succeeded but auth failed within the handshake window.
    /// `auth_ack{ok:false}` was sent followed by a close-1008 frame.
    auth_failed,
    /// Connection registered with the hub. The handler returned because
    /// the read loop exited (close frame, EOF, or peer disconnect).
    closed_normally,
    /// I/O error mid-handshake or mid-pump. Connection is now invalid.
    io_error,
};

/// Drive the full server-side handshake + auth + frame pump for one
/// connection. Blocks until the connection closes (close frame, EOF,
/// or write error). The caller is responsible for `conn.stream.close()`
/// after this returns — matching the existing pattern in
/// `handleAcceptedConnection`.
pub fn handleUpgrade(stream: anytype, ctx: UpgradeContext) UpgradeOutcome {
    // 1. Validate upgrade headers.
    const upgrade = parseUpgradeRequest(ctx.raw_request) catch |err| {
        var buf: [256]u8 = undefined;
        const reason: []const u8 = switch (err) {
            error.MissingUpgradeHeader => "missing Upgrade: websocket header",
            error.MissingSecWebSocketKey => "missing Sec-WebSocket-Key header",
            error.UnsupportedSecWebSocketVersion => "Sec-WebSocket-Version must be 13",
        };
        const body = buildRejectResponse(&buf, reason) catch return .io_error;
        writeAll(stream, body) catch {};
        return .bad_request;
    };

    // 2. Send 101 Switching Protocols.
    const accept = computeAccept(upgrade.key);
    var resp_buf: [256]u8 = undefined;
    const resp = buildAcceptResponse(&resp_buf, accept) catch return .io_error;
    writeAll(stream, resp) catch return .io_error;

    // 3. Auth handshake: wait for `{type:"auth", token, extension_version}`
    //    inside the contract's handshake window. Ping/pong is allowed
    //    pre-ack — auto-answered here so proxies don't drop the
    //    connection during a slow auth.
    var arena = std.heap.ArenaAllocator.init(ctx.long_allocator);
    defer arena.deinit();
    const ra = arena.allocator();

    // META HIGH #1: stamp the start of the auth window so
    // waitForAuthFrame can enforce the overall deadline.
    const auth_window_start = std.time.nanoTimestamp();
    const auth_frame = waitForAuthFrame(ra, stream, auth_window_start) catch |err| switch (err) {
        // META HIGH #1: distinguish the "we ran out the window"
        // close from the generic I/O failure. Send a close-1008
        // with a clear reason so an operator (or the extension's
        // popup) sees the diagnosis.
        error.AuthWindowExceeded => {
            log.warn("extension_ws: auth window exceeded ({d}s) — closing 1008", .{
                @divTrunc(AUTH_WINDOW_DEADLINE_NS, std.time.ns_per_s),
            });
            writeText(ra, stream, "{\"type\":\"auth_ack\",\"ok\":false,\"error\":\"auth_window_exceeded\"}") catch {};
            writeClose(ra, stream, 1008) catch {};
            return .auth_failed;
        },
        else => {
            log.warn("extension_ws: auth-window read failed: {}", .{err});
            return .io_error;
        },
    } orelse {
        // Peer closed without sending auth.
        return .closed_normally;
    };
    defer ra.free(auth_frame);

    const decision = ctx.auth.validate(auth_frame);
    if (!decision.ok) {
        // Send `auth_ack{ok:false}` then close-1008. Best-effort —
        // failures during this drain path are not interesting.
        const reason = decision.reason orelse "invalid_token";
        var ack_buf: [256]u8 = undefined;
        const ack = std.fmt.bufPrint(
            &ack_buf,
            "{{\"type\":\"auth_ack\",\"ok\":false,\"error\":\"{s}\"}}",
            .{reason},
        ) catch return .io_error;
        writeText(ra, stream, ack) catch {};
        writeClose(ra, stream, 1008) catch {};
        return .auth_failed;
    }
    const user_id = decision.user_id orelse {
        // Validator accepted token but produced no user_id — defensive
        // close so we never register a nameless connection.
        writeText(ra, stream, "{\"type\":\"auth_ack\",\"ok\":false,\"error\":\"missing_user_id\"}") catch {};
        writeClose(ra, stream, 1008) catch {};
        return .auth_failed;
    };

    // 4. Send `auth_ack{ok:true}` and register with the hub.
    writeText(ra, stream, "{\"type\":\"auth_ack\",\"ok\":true}") catch return .io_error;

    // Register: hub takes ownership of the cloned user_id; the adapter
    // captures the stream pointer + long_allocator so the hub's
    // sendCommand can write back through this very socket. The adapter
    // lives as long as the connection (kept alive by the hub) and is
    // freed by `unregister` via the hub's destroy path.
    //
    // user_id_copy is owned by us until `registerConn` clones it
    // internally — we free our copy immediately after.
    const user_id_copy = ctx.long_allocator.dupe(u8, user_id) catch return .io_error;
    defer ctx.long_allocator.free(user_id_copy);

    const Adapter = StreamAdapter(@TypeOf(stream));
    const adapter = ctx.long_allocator.create(Adapter) catch return .io_error;
    adapter.* = .{
        .stream = stream,
        .allocator = ctx.long_allocator,
    };

    const conn = ctx.hub.registerConn(
        user_id_copy,
        @ptrCast(adapter),
        Adapter.writeText,
        @ptrCast(adapter),
        Adapter.close,
    ) catch |err| {
        log.warn("extension_ws: hub register failed for user_id='{s}': {}", .{ user_id_copy, err });
        ctx.long_allocator.destroy(adapter);
        writeClose(ra, stream, 1011) catch {};
        return .io_error;
    };
    defer {
        // unregister returns true iff we were still in the map (i.e.,
        // not already evicted by a newer connection). Either way we
        // own destroy of conn + adapter — they're allocated in this
        // function's frame.
        _ = ctx.hub.unregister(user_id_copy);
        ctx.hub.destroyConn(conn);
        ctx.long_allocator.destroy(adapter);
    }

    // 5. Frame pump. Each inbound text frame is treated as a
    //    CommandResult and handed to the hub for routing by command_id.
    pumpFrames(stream, conn) catch |err| switch (err) {
        error.ConnectionClosed, error.BrokenPipe => return .closed_normally,
        else => {
            log.warn("extension_ws: pump failed: {}", .{err});
            return .io_error;
        },
    };
    return .closed_normally;
}

/// Read frames inside the pre-ack window, dropping ping (auto-pong) and
/// pong frames. Returns the first text-frame payload (heap-allocated;
/// caller frees) or null on graceful close. Errors propagate so the
/// handler can decide whether to send `auth_ack{ok:false}` vs. just close.
///
/// META HIGH #1: enforces the overall AUTH_WINDOW_DEADLINE_NS from
/// `window_start`. Returns `error.AuthWindowExceeded` when the
/// deadline elapses regardless of partial-frame progress — defeats the
/// slow-loris pattern (1-byte-per-25s, ping-every-minute, etc.) that
/// would otherwise hold a gateway thread forever.
fn waitForAuthFrame(allocator: std.mem.Allocator, stream: anytype, window_start: i128) !?[]u8 {
    while (true) {
        if (std.time.nanoTimestamp() - window_start > AUTH_WINDOW_DEADLINE_NS) {
            return error.AuthWindowExceeded;
        }
        const frame_opt = try readFrame(allocator, stream);
        const frame = frame_opt orelse return null;
        switch (frame.opcode) {
            .text => return frame.payload,
            .ping => {
                // Auto-pong with the same payload (RFC 6455 §5.5.3).
                writeFrame(allocator, stream, .pong, frame.payload) catch {};
                if (frame.payload.len > 0) allocator.free(frame.payload);
            },
            .pong => {
                if (frame.payload.len > 0) allocator.free(frame.payload);
            },
            .close => {
                if (frame.payload.len > 0) allocator.free(frame.payload);
                return null;
            },
            else => {
                // binary/continuation pre-ack — drop and continue. The
                // contract uses JSON-over-text so we'd never expect a
                // binary frame, but we don't kill the connection over it.
                if (frame.payload.len > 0) allocator.free(frame.payload);
            },
        }
    }
}

/// Per-connection read loop: parse JSON frames, route CommandResults
/// to pending commands. Heartbeat (`{type:"ping"}` / `{type:"pong"}`)
/// is handled inline. Returns when the peer closes or errors.
fn pumpFrames(stream: anytype, conn: *hub_mod.ExtensionWsConn) !void {
    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(conn.allocator);
        defer frame_arena.deinit();
        const fa = frame_arena.allocator();

        const frame_opt = try readFrame(fa, stream);
        const frame = frame_opt orelse return;
        switch (frame.opcode) {
            .text => {
                // Try interpreting as a heartbeat JSON envelope first.
                const trimmed = std.mem.trim(u8, frame.payload, " \t\r\n");
                if (std.mem.indexOf(u8, trimmed, "\"type\":\"ping\"") != null) {
                    writeText(fa, stream, "{\"type\":\"pong\"}") catch {};
                    continue;
                }
                if (std.mem.indexOf(u8, trimmed, "\"type\":\"pong\"") != null) {
                    continue;
                }
                // Otherwise: a CommandResult — hand to the hub.
                conn.deliverResult(frame.payload) catch |err| {
                    log.warn("extension_ws: deliverResult failed: {}", .{err});
                };
            },
            .ping => writeFrame(fa, stream, .pong, frame.payload) catch {},
            .pong => {},
            .close => return,
            else => {},
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "computeAccept matches RFC test vector" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = computeAccept(key);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "parseUpgradeRequest happy path" {
    const raw =
        "GET /api/v1/extension/ws HTTP/1.1\r\n" ++
        "Host: gateway.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    const req = try parseUpgradeRequest(raw);
    try std.testing.expect(req.has_upgrade);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", req.key);
    try std.testing.expectEqualStrings("13", req.version);
}

test "parseUpgradeRequest missing key returns error" {
    const raw =
        "GET /api/v1/extension/ws HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    try std.testing.expectError(error.MissingSecWebSocketKey, parseUpgradeRequest(raw));
}

test "parseUpgradeRequest wrong version returns error" {
    const raw =
        "GET /api/v1/extension/ws HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n" ++
        "Sec-WebSocket-Version: 8\r\n" ++
        "\r\n";
    try std.testing.expectError(error.UnsupportedSecWebSocketVersion, parseUpgradeRequest(raw));
}

test "parseUpgradeRequest missing upgrade header returns error" {
    const raw =
        "GET /api/v1/extension/ws HTTP/1.1\r\n" ++
        "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    try std.testing.expectError(error.MissingUpgradeHeader, parseUpgradeRequest(raw));
}

test "parseUpgradeRequest case-insensitive Upgrade value" {
    const raw =
        "GET /api/v1/extension/ws HTTP/1.1\r\n" ++
        "Upgrade: WebSocket\r\n" ++
        "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    const req = try parseUpgradeRequest(raw);
    try std.testing.expect(req.has_upgrade);
}

test "buildAcceptResponse produces well-formed 101" {
    var buf: [256]u8 = undefined;
    const accept = computeAccept("dGhlIHNhbXBsZSBub25jZQ==");
    const resp = try buildAcceptResponse(&buf, accept);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 101 Switching Protocols\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n"));
}

test "buildRejectResponse includes reason in body" {
    var buf: [256]u8 = undefined;
    const resp = try buildRejectResponse(&buf, "no good");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 400 Bad Request\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 7\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\nno good"));
}

test "extractHeader case-insensitive header lookup" {
    const raw =
        "GET / HTTP/1.1\r\n" ++
        "X-Foo: bar\r\n" ++
        "X-BAR: baz\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings("bar", extractHeader(raw, "x-foo").?);
    try std.testing.expectEqualStrings("baz", extractHeader(raw, "X-Bar").?);
    try std.testing.expect(extractHeader(raw, "X-Missing") == null);
}

test "writeFrame server-side does NOT mask" {
    // Round-trip: server writes a text frame, "client" reads bytes and
    // verifies the MASK bit (0x80 on byte[1]) is OFF.
    const TestStream = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,

        pub fn write(self: *@This(), bytes: []const u8) !usize {
            try self.buf.appendSlice(std.testing.allocator, bytes);
            return bytes.len;
        }
    };
    var sink = TestStream{};
    defer sink.buf.deinit(std.testing.allocator);

    try writeFrame(std.testing.allocator, &sink, .text, "hi");
    // Header byte 0: FIN=1 + text(1) = 0x81
    try std.testing.expectEqual(@as(u8, 0x81), sink.buf.items[0]);
    // Header byte 1: MASK=0 + len=2 = 0x02 (server frames are unmasked)
    try std.testing.expectEqual(@as(u8, 0x02), sink.buf.items[1]);
    // Payload follows directly (no 4-byte mask key)
    try std.testing.expectEqual(@as(u8, 'h'), sink.buf.items[2]);
    try std.testing.expectEqual(@as(u8, 'i'), sink.buf.items[3]);
    try std.testing.expectEqual(@as(usize, 4), sink.buf.items.len);
}

test "writeFrame extended length 126 uses 2-byte size field" {
    const TestStream = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,
        pub fn write(self: *@This(), bytes: []const u8) !usize {
            try self.buf.appendSlice(std.testing.allocator, bytes);
            return bytes.len;
        }
    };
    var sink = TestStream{};
    defer sink.buf.deinit(std.testing.allocator);

    var payload: [200]u8 = undefined;
    @memset(&payload, 'A');
    try writeFrame(std.testing.allocator, &sink, .text, &payload);
    try std.testing.expectEqual(@as(u8, 0x81), sink.buf.items[0]);
    try std.testing.expectEqual(@as(u8, 126), sink.buf.items[1]); // 126 sentinel
    try std.testing.expectEqual(@as(u8, 0), sink.buf.items[2]); // high byte
    try std.testing.expectEqual(@as(u8, 200), sink.buf.items[3]); // low byte
}

// ── META HIGH #1 regression test ─────────────────────────────────────

test "META HIGH #1: waitForAuthFrame returns AuthWindowExceeded after deadline" {
    // A peer that never sends a text frame (just keeps the stream
    // open) used to hold the read loop forever. Now: the overall
    // window-age check fires `error.AuthWindowExceeded` and
    // handleUpgrade closes-1008 with that reason.
    //
    // Test pattern: a stream whose `read` returns WouldBlock every
    // call (the same shape as a silent peer). We claim the window
    // started "infinity ago" so the very first deadline check
    // trips, regardless of what readFrame does next.
    const SilentStream = struct {
        pub fn read(_: *@This(), _: []u8) !usize {
            return error.WouldBlock;
        }
        pub fn write(_: *@This(), bytes: []const u8) !usize {
            return bytes.len; // never called in this test, but the
            // comptime duck-typed `writeFrame` requires the method
            // to exist for type-check.
        }
    };
    var s = SilentStream{};
    // window_start = 0 (epoch); nanoTimestamp - 0 always > deadline.
    const r = waitForAuthFrame(std.testing.allocator, &s, 0);
    try std.testing.expectError(error.AuthWindowExceeded, r);
}

test "META HIGH #1: waitForAuthFrame admits frames within deadline" {
    // Sanity check: the deadline doesn't fire for frames that arrive
    // promptly. A stream that returns a complete text frame on the
    // first read should produce the payload without tripping the
    // deadline. window_start = now (the deadline is 60s out).
    const TextStream = struct {
        buf: []const u8,
        pos: usize = 0,
        pub fn read(self: *@This(), out: []u8) !usize {
            const remaining = self.buf[self.pos..];
            const n = @min(remaining.len, out.len);
            @memcpy(out[0..n], remaining[0..n]);
            self.pos += n;
            return n;
        }
        pub fn write(_: *@This(), bytes: []const u8) !usize {
            return bytes.len;
        }
    };
    // A minimal RFC-6455-shaped text frame: FIN+text(0x81), masked
    // len=4 (0x84), mask 4 bytes, payload "hi" (xored with mask).
    var s = TextStream{ .buf = &.{
        0x81, 0x84, // FIN+text, MASK+len=4
        0x01, 0x02, 0x03, 0x04, // mask
        // payload "test" XOR mask:
        't' ^ 0x01, 'e' ^ 0x02, 's' ^ 0x03, 't' ^ 0x04,
    } };
    const r = try waitForAuthFrame(std.testing.allocator, &s, std.time.nanoTimestamp());
    defer std.testing.allocator.free(r.?);
    try std.testing.expectEqualStrings("test", r.?);
}

test "writeClose includes close code in payload" {
    const TestStream = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,
        pub fn write(self: *@This(), bytes: []const u8) !usize {
            try self.buf.appendSlice(std.testing.allocator, bytes);
            return bytes.len;
        }
    };
    var sink = TestStream{};
    defer sink.buf.deinit(std.testing.allocator);

    try writeClose(std.testing.allocator, &sink, 1008);
    // Header: 0x88 (FIN+close), 0x02 (MASK=0 + len=2)
    try std.testing.expectEqual(@as(u8, 0x88), sink.buf.items[0]);
    try std.testing.expectEqual(@as(u8, 0x02), sink.buf.items[1]);
    // Payload: 1008 = 0x03F0
    try std.testing.expectEqual(@as(u8, 0x03), sink.buf.items[2]);
    try std.testing.expectEqual(@as(u8, 0xF0), sink.buf.items[3]);
}
