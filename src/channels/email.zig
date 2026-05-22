const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const http_native = @import("../http_native/root.zig");

const log = std.log.scoped(.email);

/// Email channel — bidirectional SMTP + IMAP.
///
/// Outbound: `sendMessage` connects to the SMTP server. When `smtp_tls` is
/// set it negotiates TLS — implicit TLS on port 465, STARTTLS upgrade on
/// port 587 (and anything else). Plaintext SMTP is used only when
/// `smtp_tls=false`.
///
/// Inbound: `pollMessages` opens an implicit-TLS connection to the IMAP
/// server (port 993), runs LOGIN → SELECT → SEARCH UNSEEN → FETCH, parses
/// each unseen message (RFC 2047 headers, HTML-stripped body), filters by
/// the `allow_from` allowlist, de-dups via a `BoundedSeenSet`, and marks the
/// fetched messages `\Seen`. The channel catalog classifies email as
/// `.polling`; `channel_loop.runEmailLoop` drives `pollMessages` on a thread,
/// exactly like Telegram/Signal/Matrix.
pub const EmailChannel = struct {
    allocator: std.mem.Allocator,
    config: config_types.EmailConfig,
    /// Tracks last Message-ID per sender for In-Reply-To/References headers.
    reply_message_ids: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// De-dup set for inbound messages keyed by IMAP UID (string form).
    seen: BoundedSeenSet,
    /// IMAP command tag counter — incremented per command for unique tags.
    imap_tag: u32 = 0,
    running: bool = false,

    /// Capacity of the inbound de-dup set.
    pub const SEEN_CAPACITY: usize = 1024;

    /// Heap-allocated TLS state wrapping a TCP stream with encryption.
    /// Heap allocation keeps the reader/writer pointers stable for the
    /// TLS client, which holds interface pointers into this struct.
    /// Mirrors the `irc.zig` TlsState pattern.
    pub const TlsState = struct {
        stream: std.net.Stream,
        stream_reader: std.net.Stream.Reader,
        stream_writer: std.net.Stream.Writer,
        tls_client: std.crypto.tls.Client,
        read_buf: []u8,
        write_buf: []u8,
        tls_read_buf: []u8,
        tls_write_buf: []u8,

        pub fn deinit(self: *TlsState, allocator: std.mem.Allocator) void {
            allocator.free(self.read_buf);
            allocator.free(self.write_buf);
            allocator.free(self.tls_read_buf);
            allocator.free(self.tls_write_buf);
            allocator.destroy(self);
        }

        pub fn writeAll(self: *TlsState, data: []const u8) !void {
            try self.tls_client.writer.writeAll(data);
            try self.tls_client.writer.flush();
            try self.stream_writer.interface.flush();
        }

        pub fn read(self: *TlsState, out: []u8) !usize {
            var rd: [1][]u8 = .{out};
            return self.tls_client.reader.readVec(&rd) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => err,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: config_types.EmailConfig) EmailChannel {
        return .{
            .allocator = allocator,
            .config = config,
            .reply_message_ids = .empty,
            .seen = BoundedSeenSet.init(allocator, SEEN_CAPACITY),
        };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.EmailConfig) EmailChannel {
        return init(allocator, cfg);
    }

    pub fn deinit(self: *EmailChannel) void {
        var it = self.reply_message_ids.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.reply_message_ids.deinit(self.allocator);
        self.seen.deinit();
    }

    fn nextTag(self: *EmailChannel) u32 {
        self.imap_tag +%= 1;
        return self.imap_tag;
    }

    /// Record a Message-ID for a sender (for threading replies).
    pub fn trackMessageId(self: *EmailChannel, sender: []const u8, message_id: []const u8) !void {
        const gop = try self.reply_message_ids.getOrPut(self.allocator, sender);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = try self.allocator.dupe(u8, message_id);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, sender);
            gop.value_ptr.* = try self.allocator.dupe(u8, message_id);
        }
    }

    pub fn channelName(_: *EmailChannel) []const u8 {
        return "email";
    }

    /// Check if a sender email is in the allowlist.
    /// Supports full addresses, @domain, or bare domain matching.
    pub fn isSenderAllowed(self: *const EmailChannel, email_addr: []const u8) bool {
        if (self.config.allow_from.len == 0) return false;

        for (self.config.allow_from) |allowed| {
            if (std.mem.eql(u8, allowed, "*")) return true;

            if (allowed.len > 0 and allowed[0] == '@') {
                // Domain match with @ prefix: "@example.com"
                if (std.ascii.endsWithIgnoreCase(email_addr, allowed)) return true;
            } else if (std.mem.indexOf(u8, allowed, "@") != null) {
                // Full email address match
                if (std.ascii.eqlIgnoreCase(allowed, email_addr)) return true;
            } else {
                // Domain match without @: "example.com" -> match @example.com
                if (email_addr.len > allowed.len + 1) {
                    const suffix_start = email_addr.len - allowed.len - 1;
                    if (email_addr[suffix_start] == '@' and
                        std.ascii.eqlIgnoreCase(email_addr[suffix_start + 1 ..], allowed))
                    {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// Health probe. Email has no persistent connection (SMTP connects
    /// per-send, IMAP per-poll), so "healthy" simply means the channel has
    /// been started and not stopped — the polling supervisor pairs this
    /// with a thread-staleness check.
    pub fn healthCheck(self: *EmailChannel) bool {
        return self.running;
    }

    // ── Channel vtable ──────────────────────────────────────────────

    /// SMTP TLS transport mode for a given config.
    /// - `.plain`     — no TLS (smtp_tls=false).
    /// - `.implicit`  — TLS from connect (port 465 — SMTPS).
    /// - `.starttls`  — plaintext connect, STARTTLS upgrade (port 587 / other).
    pub const SmtpTlsMode = enum { plain, implicit, starttls };

    /// Select the SMTP TLS mode from the config.
    /// Port 465 is the historical implicit-TLS (SMTPS) port; every other
    /// port with TLS enabled (587 submission, 25, …) uses STARTTLS.
    pub fn smtpTlsMode(cfg: config_types.EmailConfig) SmtpTlsMode {
        if (!cfg.smtp_tls) return .plain;
        if (cfg.smtp_port == 465) return .implicit;
        return .starttls;
    }

    /// Send an email via SMTP.
    /// If message starts with "Subject: <line>\n", extracts the subject.
    /// Otherwise uses a default subject.
    ///
    /// Honours `smtp_tls`: implicit TLS on 465, STARTTLS on 587/other,
    /// plaintext only when `smtp_tls=false`.
    pub fn sendMessage(self: *EmailChannel, recipient: []const u8, message: []const u8) !void {
        if (!self.config.consent_granted) return error.ConsentNotGranted;

        // Extract subject if present
        var subject: []const u8 = "nullalis Message";
        var body = message;
        if (std.mem.startsWith(u8, message, "Subject: ")) {
            if (std.mem.indexOf(u8, message, "\n")) |nl_pos| {
                subject = message[9..nl_pos];
                body = std.mem.trimLeft(u8, message[nl_pos + 1 ..], " \t\r\n");
            }
        }

        const mode = smtpTlsMode(self.config);

        // Connect to SMTP server via TCP
        const addr = std.net.Address.resolveIp(self.config.smtp_host, self.config.smtp_port) catch return error.SmtpConnectError;
        const stream = std.net.tcpConnectToAddress(addr) catch return error.SmtpConnectError;
        var stream_closed = false;
        defer if (!stream_closed) stream.close();

        var tls_state: ?*TlsState = null;
        defer if (tls_state) |tls| {
            tls.tls_client.end() catch {};
            tls.deinit(self.allocator);
        };

        var greeting_buf: [2048]u8 = undefined;

        // ── Implicit TLS: wrap the socket before reading the greeting ──
        if (mode == .implicit) {
            tls_state = try self.initTls(stream, self.config.smtp_host);
        }

        // Read server greeting (220).
        _ = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;

        // EHLO — expect 250.
        try self.smtpWrite(stream, tls_state, "EHLO nullalis\r\n");
        {
            const n = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (!smtpCodeIs(greeting_buf[0..n], 250)) {
                log.warn("SMTP EHLO rejected: {s}", .{greeting_buf[0..@min(n, 256)]});
                return error.SmtpEhloRejected;
            }
        }

        // ── STARTTLS upgrade ───────────────────────────────────────
        if (mode == .starttls) {
            try self.smtpWrite(stream, tls_state, "STARTTLS\r\n");
            const n = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (!smtpCodeIs(greeting_buf[0..n], 220)) {
                return error.SmtpStartTlsRejected;
            }
            tls_state = try self.initTls(stream, self.config.smtp_host);
            // Re-issue EHLO over the encrypted channel — expect 250.
            try self.smtpWrite(stream, tls_state, "EHLO nullalis\r\n");
            const n2 = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (!smtpCodeIs(greeting_buf[0..n2], 250)) {
                log.warn("SMTP EHLO (post-STARTTLS) rejected: {s}", .{greeting_buf[0..@min(n2, 256)]});
                return error.SmtpEhloRejected;
            }
        }

        // ── AUTH LOGIN (when credentials are configured) ───────────
        if (self.config.username.len > 0 and self.config.password.len > 0) {
            try self.smtpWrite(stream, tls_state, "AUTH LOGIN\r\n");
            _ = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;

            var b64_buf: [512]u8 = undefined;
            const enc_user = std.base64.standard.Encoder.encode(&b64_buf, self.config.username);
            try self.smtpWrite(stream, tls_state, enc_user);
            try self.smtpWrite(stream, tls_state, "\r\n");
            _ = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;

            const enc_pass = std.base64.standard.Encoder.encode(&b64_buf, self.config.password);
            try self.smtpWrite(stream, tls_state, enc_pass);
            try self.smtpWrite(stream, tls_state, "\r\n");
            const an = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (an < 3 or !std.mem.startsWith(u8, greeting_buf[0..an], "235")) {
                return error.SmtpAuthFailed;
            }
        }

        // MAIL FROM — expect 250.
        var from_buf: [512]u8 = undefined;
        const from_line = try std.fmt.bufPrint(&from_buf, "MAIL FROM:<{s}>\r\n", .{self.config.from_address});
        try self.smtpWrite(stream, tls_state, from_line);
        {
            const n = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (!smtpCodeIs(greeting_buf[0..n], 250)) {
                log.warn("SMTP MAIL FROM rejected: {s}", .{greeting_buf[0..@min(n, 256)]});
                return error.SmtpMailFromRejected;
            }
        }

        // RCPT TO — expect 250.
        var rcpt_buf: [512]u8 = undefined;
        const rcpt_line = try std.fmt.bufPrint(&rcpt_buf, "RCPT TO:<{s}>\r\n", .{recipient});
        try self.smtpWrite(stream, tls_state, rcpt_line);
        {
            const n = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (!smtpCodeIs(greeting_buf[0..n], 250)) {
                log.warn("SMTP RCPT TO rejected: {s}", .{greeting_buf[0..@min(n, 256)]});
                return error.SmtpRcptToRejected;
            }
        }

        // DATA — expect 354 (server ready to receive the message body).
        try self.smtpWrite(stream, tls_state, "DATA\r\n");
        {
            const n = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (!smtpCodeIs(greeting_buf[0..n], 354)) {
                log.warn("SMTP DATA rejected (no 354): {s}", .{greeting_buf[0..@min(n, 256)]});
                return error.SmtpDataRejected;
            }
        }

        // Build email headers + body in a growable heap buffer — a reply
        // longer than any fixed buffer must still send.
        var data: std.ArrayListUnmanaged(u8) = .empty;
        defer data.deinit(self.allocator);
        const dw = data.writer(self.allocator);
        try dw.print("From: {s}\r\n", .{self.config.from_address});
        try dw.print("To: {s}\r\n", .{recipient});
        try dw.print("Subject: {s}\r\n", .{subject});

        // Add In-Reply-To/References headers if we have a tracked message-id
        if (self.reply_message_ids.get(recipient)) |msg_id| {
            try dw.print("In-Reply-To: <{s}>\r\n", .{msg_id});
            try dw.print("References: <{s}>\r\n", .{msg_id});
        }

        try dw.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
        try dw.writeAll("\r\n");
        try dw.writeAll(body);
        try dw.writeAll("\r\n.\r\n");
        try self.smtpWrite(stream, tls_state, data.items);
        // Final dot — expect 250 (message accepted for delivery).
        {
            const n = self.smtpRead(stream, tls_state, &greeting_buf) catch return error.SmtpError;
            if (!smtpCodeIs(greeting_buf[0..n], 250)) {
                log.warn("SMTP message rejected after DATA: {s}", .{greeting_buf[0..@min(n, 256)]});
                return error.SmtpMessageRejected;
            }
        }

        // QUIT
        try self.smtpWrite(stream, tls_state, "QUIT\r\n");

        // Close the TLS session and socket cleanly before the defers run
        // (defer-order is fine, but be explicit about ownership here).
        if (tls_state) |tls| {
            tls.tls_client.end() catch {};
            tls.deinit(self.allocator);
            tls_state = null;
        }
        stream.close();
        stream_closed = true;
    }

    /// Write to an SMTP connection — through TLS when wrapped, else plain TCP.
    fn smtpWrite(self: *EmailChannel, stream: std.net.Stream, tls: ?*TlsState, data: []const u8) !void {
        _ = self;
        if (tls) |t| {
            try t.writeAll(data);
        } else {
            try stream.writeAll(data);
        }
    }

    /// Read from an SMTP connection — through TLS when wrapped, else plain TCP.
    fn smtpRead(self: *EmailChannel, stream: std.net.Stream, tls: ?*TlsState, out: []u8) !usize {
        _ = self;
        if (tls) |t| {
            return t.read(out);
        }
        return stream.read(out);
    }

    /// Initialize implicit TLS over an established TCP stream.
    ///
    /// `server_name` is used both for SNI and for certificate hostname
    /// verification. The connection carries the mailbox password (IMAP
    /// `LOGIN`, SMTP `AUTH LOGIN`), so the certificate chain is verified
    /// against the process-wide system CA bundle — an unverified
    /// connection here would let an active MITM harvest credentials.
    ///
    /// FAIL-CLOSED: if the system CA bundle cannot be loaded, or if no
    /// `server_name` is supplied (hostname verification would be
    /// impossible), this returns an error and refuses the connection.
    /// There is deliberately no `.no_verification` fallback.
    ///
    /// `allow_truncation_attacks = true` is retained: a truncation attack
    /// can only cut a session short (a denial-of-service the polling loop
    /// already tolerates by retrying), it cannot forge or read traffic,
    /// so it is a far lesser concern than certificate verification.
    fn initTls(self: *EmailChannel, stream: std.net.Stream, server_name: []const u8) !*TlsState {
        if (server_name.len == 0) return error.TlsInitializationFailed;

        // Verified system trust anchor — fail closed if it cannot load.
        const ca_bundle = http_native.sharedCaBundle() catch return error.TlsInitializationFailed;

        const tls_buf_len = std.crypto.tls.Client.min_buffer_len;

        const read_buf = try self.allocator.alloc(u8, tls_buf_len);
        errdefer self.allocator.free(read_buf);
        const write_buf = try self.allocator.alloc(u8, tls_buf_len);
        errdefer self.allocator.free(write_buf);
        const tls_read_buf = try self.allocator.alloc(u8, tls_buf_len);
        errdefer self.allocator.free(tls_read_buf);
        const tls_write_buf = try self.allocator.alloc(u8, tls_buf_len);
        errdefer self.allocator.free(tls_write_buf);

        const tls = try self.allocator.create(TlsState);
        errdefer self.allocator.destroy(tls);

        tls.stream = stream;
        tls.read_buf = read_buf;
        tls.write_buf = write_buf;
        tls.tls_read_buf = tls_read_buf;
        tls.tls_write_buf = tls_write_buf;
        tls.stream_reader = stream.reader(read_buf);
        tls.stream_writer = stream.writer(write_buf);

        tls.tls_client = std.crypto.tls.Client.init(
            tls.stream_reader.interface(),
            &tls.stream_writer.interface,
            .{
                .host = .{ .explicit = server_name },
                .ca = .{ .bundle = ca_bundle },
                .read_buffer = tls_read_buf,
                .write_buffer = tls_write_buf,
                .allow_truncation_attacks = true,
            },
        ) catch return error.TlsInitializationFailed;

        return tls;
    }

    /// Send a reply email — applies Re: prefix to subject and includes
    /// threading headers. The subject+body is assembled in a growable heap
    /// buffer so a reply longer than any fixed buffer still sends.
    pub fn sendReply(self: *EmailChannel, recipient: []const u8, original_subject: []const u8, message: []const u8) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        if (hasReplyPrefix(original_subject)) {
            try w.print("Subject: {s}\n{s}", .{ original_subject, message });
        } else {
            try w.print("Subject: Re: {s}\n{s}", .{ original_subject, message });
        }
        try self.sendMessage(recipient, buf.items);
    }

    /// Send an IMAP `UID STORE +FLAGS (\Seen)` command on an already-open
    /// connection and consume the tagged response. `stream`/`tls` is the
    /// active IMAP connection; exactly one is non-null.
    pub fn markMessageSeen(self: *EmailChannel, stream: std.net.Stream, tls: ?*TlsState, uid: []const u8) !void {
        const tag = self.nextTag();
        var cmd_buf: [256]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "A{d:0>4} UID STORE {s} +FLAGS (\\Seen)\r\n", .{ tag, uid });
        try self.smtpWrite(stream, tls, cmd);
        var resp_buf: [2048]u8 = undefined;
        _ = self.smtpRead(stream, tls, &resp_buf) catch return error.ImapError;
    }

    /// Hard cap on a single IMAP response read. IMAP framing means we read
    /// exactly the bytes the server frames (literal lengths + protocol
    /// lines), so this only bounds a pathological / hostile server. A few
    /// MiB comfortably covers a stripped-text message body; whole-MIME
    /// messages with attachments are never fetched (BODY.PEEK[TEXT]).
    pub const IMAP_RESPONSE_CAP: usize = 4 * 1024 * 1024;

    /// Send an IMAP command with the given tag and read the framed response
    /// into a heap-allocated, growable buffer. The returned slice is owned
    /// by `allocator` — the caller must free it. Reading is IMAP-framing
    /// aware: `{LEN}` literal markers are honoured (exactly `LEN` octets are
    /// consumed as opaque literal data), so a tagged-completion-looking line
    /// inside an email body cannot terminate the read early, and a message
    /// larger than any fixed buffer is read in full up to `IMAP_RESPONSE_CAP`.
    fn imapCommand(
        self: *EmailChannel,
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        tls: ?*TlsState,
        tag: u32,
        cmd: []const u8,
    ) ![]u8 {
        try self.smtpWrite(stream, tls, cmd);
        return self.imapReadResponse(allocator, stream, tls, tag);
    }

    /// Read an IMAP server response until the tagged completion line for
    /// `tag` is seen, honouring `{LEN}` literal framing. Accumulates into a
    /// growable heap buffer owned by `allocator` (caller frees). Stops at
    /// `IMAP_RESPONSE_CAP` to bound a hostile server.
    fn imapReadResponse(
        self: *EmailChannel,
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        tls: ?*TlsState,
        tag: u32,
    ) ![]u8 {
        var tag_buf: [8]u8 = undefined;
        const tag_str = std.fmt.bufPrint(&tag_buf, "A{d:0>4}", .{tag}) catch return error.ImapError;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        var chunk: [16 * 1024]u8 = undefined;
        while (buf.items.len < IMAP_RESPONSE_CAP) {
            // If the response is already framed-complete, stop before
            // blocking on another read.
            if (imapResponseComplete(buf.items, tag_str)) break;

            const n = self.smtpRead(stream, tls, &chunk) catch return error.ImapError;
            if (n == 0) break;
            try buf.appendSlice(allocator, chunk[0..n]);
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Run one IMAP poll cycle: connect, LOGIN, SELECT, SEARCH UNSEEN,
    /// FETCH each unseen UID, parse, allowlist-filter, de-dup, mark \Seen.
    /// Returns owned ChannelMessages on `allocator`.
    ///
    /// This is the method `channel_loop.runEmailLoop` calls each cycle.
    pub fn pollMessages(self: *EmailChannel, allocator: std.mem.Allocator) ![]root.ChannelMessage {
        if (builtin.is_test) return &.{};
        if (!self.config.consent_granted) return &.{};
        if (self.config.imap_host.len == 0) return &.{};

        const addr = std.net.Address.resolveIp(self.config.imap_host, self.config.imap_port) catch return error.ImapConnectError;
        const stream = std.net.tcpConnectToAddress(addr) catch return error.ImapConnectError;
        defer stream.close();

        // IMAP on port 993 is implicit TLS.
        const tls = try self.initTls(stream, self.config.imap_host);
        defer {
            tls.tls_client.end() catch {};
            tls.deinit(self.allocator);
        }

        var greeting_buf: [4096]u8 = undefined;

        // Server greeting (untagged "* OK ...").
        _ = self.smtpRead(stream, tls, &greeting_buf) catch return error.ImapError;

        // LOGIN
        {
            const tag = self.nextTag();
            var cmd_buf: [768]u8 = undefined;
            const cmd = try std.fmt.bufPrint(&cmd_buf, "A{d:0>4} LOGIN {s} {s}\r\n", .{ tag, self.config.username, self.config.password });
            const resp = try self.imapCommand(allocator, stream, tls, tag, cmd);
            defer allocator.free(resp);
            if (!responseIsOk(resp, tag)) return error.ImapLoginFailed;
        }

        // SELECT folder
        {
            const tag = self.nextTag();
            var cmd_buf: [512]u8 = undefined;
            const cmd = try std.fmt.bufPrint(&cmd_buf, "A{d:0>4} SELECT {s}\r\n", .{ tag, self.config.imap_folder });
            const resp = try self.imapCommand(allocator, stream, tls, tag, cmd);
            defer allocator.free(resp);
            if (!responseIsOk(resp, tag)) return error.ImapSelectFailed;
        }

        // SEARCH UNSEEN
        var uid_storage: [256]u8 = undefined;
        var uids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer uids.deinit(allocator);
        {
            const tag = self.nextTag();
            var cmd_buf: [64]u8 = undefined;
            const cmd = try std.fmt.bufPrint(&cmd_buf, "A{d:0>4} UID SEARCH UNSEEN\r\n", .{tag});
            const resp = try self.imapCommand(allocator, stream, tls, tag, cmd);
            defer allocator.free(resp);
            if (!responseIsOk(resp, tag)) return error.ImapSearchFailed;
            parseSearchUids(resp, &uid_storage, &uids, allocator) catch {};
        }

        var messages: std.ArrayListUnmanaged(root.ChannelMessage) = .empty;
        errdefer {
            for (messages.items) |msg| msg.deinit(allocator);
            messages.deinit(allocator);
        }

        // FETCH each unseen UID. Cap per-cycle work to keep latency bounded.
        const MAX_PER_CYCLE: usize = 32;
        var fetched: usize = 0;
        for (uids.items) |uid| {
            if (fetched >= MAX_PER_CYCLE) break;
            if (self.seen.contains(uid)) continue;

            const tag = self.nextTag();
            var cmd_buf: [128]u8 = undefined;
            // BODY.PEEK[HEADER] + BODY.PEEK[TEXT]: the agent only consumes
            // the stripped text (plus the From/Subject/Message-ID headers
            // for allowlisting + threading) — fetching the whole raw MIME
            // with BODY.PEEK[] is waste. PEEK leaves \Seen for us to set.
            const cmd = std.fmt.bufPrint(&cmd_buf, "A{d:0>4} UID FETCH {s} (BODY.PEEK[HEADER] BODY.PEEK[TEXT])\r\n", .{ tag, uid }) catch continue;
            const resp = self.imapCommand(allocator, stream, tls, tag, cmd) catch continue;
            defer allocator.free(resp);

            // A response that never reached the tagged completion within the
            // cap is an oversized message (the literal is larger than
            // IMAP_RESPONSE_CAP). Mark it \Seen so it is not re-fetched every
            // cycle forever, then move on.
            var tag_buf: [8]u8 = undefined;
            const tag_str = std.fmt.bufPrint(&tag_buf, "A{d:0>4}", .{tag}) catch continue;
            if (!imapResponseComplete(resp, tag_str)) {
                log.warn("IMAP message uid={s} exceeds {d}-byte cap — marking \\Seen and skipping", .{ uid, IMAP_RESPONSE_CAP });
                _ = self.seen.insert(uid) catch {};
                self.markMessageSeen(stream, tls, uid) catch {};
                continue;
            }
            if (!responseIsOk(resp, tag)) continue;

            // Reassemble "header\r\nbody" from the two fetched literals so
            // parseEmailMessage sees a normal RFC 5322 message. A FETCH with
            // no literal at all (e.g. the UID vanished) is skipped.
            const raw = joinFetchLiterals(allocator, resp) catch continue orelse continue;
            defer allocator.free(raw);
            const parsed = parseEmailMessage(allocator, raw) catch continue;
            defer parsed.deinit(allocator);

            // Allowlist filter on the parsed sender address.
            if (!self.isSenderAllowed(parsed.from_addr)) {
                // Still mark seen so a disallowed sender is not re-fetched
                // every cycle forever.
                _ = self.seen.insert(uid) catch {};
                self.markMessageSeen(stream, tls, uid) catch {};
                continue;
            }

            const msg = self.buildChannelMessage(allocator, uid, parsed) catch continue;
            messages.append(allocator, msg) catch {
                msg.deinit(allocator);
                continue;
            };

            // Track the Message-ID for reply threading.
            if (parsed.message_id.len > 0) {
                self.trackMessageId(parsed.from_addr, parsed.message_id) catch {};
            }

            _ = self.seen.insert(uid) catch {};
            self.markMessageSeen(stream, tls, uid) catch {};
            fetched += 1;
        }

        // LOGOUT — drain the tagged response best-effort, mirroring
        // sendMessage's clean SMTP shutdown.
        {
            const tag = self.nextTag();
            var cmd_buf: [32]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "A{d:0>4} LOGOUT\r\n", .{tag}) catch return toOwnedMessages(allocator, &messages);
            if (self.imapCommand(allocator, stream, tls, tag, cmd)) |resp| {
                allocator.free(resp);
            } else |_| {}
        }

        return toOwnedMessages(allocator, &messages);
    }

    /// Build a ChannelMessage from a parsed email. `uid` becomes the message
    /// id; the reply target is the sender address so the agent can reply.
    fn buildChannelMessage(self: *EmailChannel, allocator: std.mem.Allocator, uid: []const u8, parsed: ParsedEmail) !root.ChannelMessage {
        _ = self;
        // Prepend the subject so the agent sees the email's topic in context.
        const content = if (parsed.subject.len > 0)
            try std.fmt.allocPrint(allocator, "Subject: {s}\n\n{s}", .{ parsed.subject, parsed.body })
        else
            try allocator.dupe(u8, parsed.body);
        errdefer allocator.free(content);

        const id = try allocator.dupe(u8, uid);
        errdefer allocator.free(id);

        const sender = try allocator.dupe(u8, parsed.from_addr);
        errdefer allocator.free(sender);

        const reply_target = try allocator.dupe(u8, parsed.from_addr);

        return .{
            .id = id,
            .sender = sender,
            .content = content,
            .channel = "email",
            .timestamp = root.nowEpochSecs(),
            .reply_target = reply_target,
            .is_group = false,
        };
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *EmailChannel = @ptrCast(@alignCast(ptr));
        self.running = true;
        // No persistent connection: SMTP connects per-send, IMAP per-poll.
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *EmailChannel = @ptrCast(@alignCast(ptr));
        self.running = false;
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *EmailChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *EmailChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *EmailChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *EmailChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// IMAP response parsing (pure functions — unit-tested without a live server)
// ════════════════════════════════════════════════════════════════════════════

/// A parsed inbound email. Slices are heap-owned; free via `deinit`.
pub const ParsedEmail = struct {
    from_addr: []const u8,
    subject: []const u8,
    body: []const u8,
    message_id: []const u8,

    pub fn deinit(self: *const ParsedEmail, allocator: std.mem.Allocator) void {
        allocator.free(self.from_addr);
        allocator.free(self.subject);
        allocator.free(self.body);
        allocator.free(self.message_id);
    }
};

/// Convert an ArrayList of ChannelMessages to an owned slice, freeing the
/// list. Returns an empty slice (no allocation) when the list is empty.
fn toOwnedMessages(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(root.ChannelMessage),
) ![]root.ChannelMessage {
    if (list.items.len == 0) {
        list.deinit(allocator);
        return &.{};
    }
    return list.toOwnedSlice(allocator);
}

/// True when the accumulated IMAP response contains a line that starts with
/// the command tag — the IMAP tagged completion ("<tag> OK|NO|BAD ...").
pub fn responseHasTaggedCompletion(resp: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, resp, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, tag)) return true;
    }
    return false;
}

/// If `line` (a single CRLF-stripped protocol line) ends with an IMAP
/// literal marker `{NNN}` — optionally `{NNN+}` for a non-synchronizing
/// literal — return `NNN`. Otherwise null. The literal's `NNN` octets
/// follow the line's terminating CRLF as opaque data.
fn imapLiteralLen(line: []const u8) ?usize {
    if (line.len < 3 or line[line.len - 1] != '}') return null;
    const open = std.mem.lastIndexOfScalar(u8, line, '{') orelse return null;
    var digits = line[open + 1 .. line.len - 1];
    // Tolerate the LITERAL+ non-synchronizing form "{NNN+}".
    if (digits.len > 0 and digits[digits.len - 1] == '+') digits = digits[0 .. digits.len - 1];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// True when `resp` holds a complete IMAP response for `tag` — i.e. the
/// tagged completion line ("<tag> OK|NO|BAD ...") has been received.
///
/// Unlike `responseHasTaggedCompletion`, this walks the response with IMAP
/// literal framing: when a protocol line ends in a `{LEN}` literal marker,
/// exactly `LEN` octets following the CRLF are skipped as opaque literal
/// data. This is what prevents two false matches:
///  - an email body that contains a line like "A0042 OK ..." is inside a
///    literal block and is therefore never scanned as a protocol line;
///  - the read does not stop until the *real* tagged completion arrives,
///    so a message larger than any single buffer is still read in full.
///
/// If the buffer ends partway through a literal (the declared `LEN` octets
/// have not all arrived yet) the response is treated as incomplete.
pub fn imapResponseComplete(resp: []const u8, tag: []const u8) bool {
    var i: usize = 0;
    while (i < resp.len) {
        // Find the end of the current protocol line.
        const nl_rel = std.mem.indexOfScalarPos(u8, resp, i, '\n') orelse {
            // No complete line yet — response cannot be complete.
            return false;
        };
        const line = std.mem.trimRight(u8, resp[i..nl_rel], "\r");

        if (std.mem.startsWith(u8, line, tag)) return true;

        // Advance past the CRLF.
        var next = nl_rel + 1;

        // A trailing literal marker means the next LEN octets are opaque.
        if (imapLiteralLen(line)) |lit_len| {
            if (next + lit_len > resp.len) return false; // literal incomplete
            next += lit_len;
        }
        i = next;
    }
    return false;
}

/// True when the IMAP response's tagged completion line for `tag` is `OK`.
pub fn responseIsOk(resp: []const u8, tag: u32) bool {
    var tag_buf: [8]u8 = undefined;
    const tag_str = std.fmt.bufPrint(&tag_buf, "A{d:0>4}", .{tag}) catch return false;

    var it = std.mem.splitScalar(u8, resp, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, tag_str)) continue;
        // "<tag> OK ..." — the status word follows the tag + a space.
        const rest = std.mem.trimLeft(u8, line[tag_str.len..], " ");
        return std.mem.startsWith(u8, rest, "OK");
    }
    return false;
}

/// Parse the UID list from an IMAP `UID SEARCH` response.
/// The untagged response line is: `* SEARCH 1 4 7 ...`.
/// UID strings are copied into `storage`; slices into `storage` are pushed
/// onto `uids`. A UID is dropped silently if `storage` runs out of room.
pub fn parseSearchUids(
    resp: []const u8,
    storage: []u8,
    uids: *std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,
) !void {
    var write_pos: usize = 0;
    var line_it = std.mem.splitScalar(u8, resp, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        // Untagged search result: "* SEARCH ..." (case-insensitive keyword).
        if (line.len < 2 or line[0] != '*') continue;
        const after_star = std.mem.trimLeft(u8, line[1..], " ");
        if (!std.ascii.startsWithIgnoreCase(after_star, "SEARCH")) continue;

        const ids_part = std.mem.trimLeft(u8, after_star[6..], " ");
        var num_it = std.mem.tokenizeAny(u8, ids_part, " \t");
        while (num_it.next()) |tok| {
            // Validate it's all digits — IMAP UIDs are decimal.
            var all_digits = tok.len > 0;
            for (tok) |c| {
                if (!std.ascii.isDigit(c)) {
                    all_digits = false;
                    break;
                }
            }
            if (!all_digits) continue;
            if (write_pos + tok.len > storage.len) return;
            @memcpy(storage[write_pos..][0..tok.len], tok);
            try uids.append(allocator, storage[write_pos..][0..tok.len]);
            write_pos += tok.len;
        }
    }
}

/// Extract the first message literal from an IMAP `UID FETCH` response.
///
/// IMAP framing: a protocol line ending in `{LEN}` declares that the next
/// `LEN` octets (after the line's CRLF) are opaque literal data. This walks
/// the response line-by-line with that framing — it only treats a `{LEN}`
/// at the *end of a protocol line* as a literal marker, so a `{` inside the
/// literal body cannot false-match. Returns the first literal's bytes, or
/// null if the response carries no literal.
pub fn extractFetchLiteral(resp: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < resp.len) {
        const nl_rel = std.mem.indexOfScalarPos(u8, resp, i, '\n') orelse return null;
        const line = std.mem.trimRight(u8, resp[i..nl_rel], "\r");
        const data_start = nl_rel + 1;
        if (imapLiteralLen(line)) |lit_len| {
            const avail = resp.len - data_start;
            const take = @min(lit_len, avail);
            return resp[data_start .. data_start + take];
        }
        i = data_start;
    }
    return null;
}

/// Concatenate every literal block in an IMAP `UID FETCH` response, in
/// order, into one heap-allocated buffer (caller frees). For a
/// `(BODY.PEEK[HEADER] BODY.PEEK[TEXT])` fetch this yields `header ++ text`
/// — a complete RFC 5322 message ready for `parseEmailMessage` (IMAP's
/// `[HEADER]` section already includes the blank line that separates
/// headers from body). Returns null when the response carries no literal.
pub fn joinFetchLiterals(allocator: std.mem.Allocator, resp: []const u8) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var found = false;
    var i: usize = 0;
    while (i < resp.len) {
        const nl_rel = std.mem.indexOfScalarPos(u8, resp, i, '\n') orelse break;
        const line = std.mem.trimRight(u8, resp[i..nl_rel], "\r");
        var next = nl_rel + 1;
        if (imapLiteralLen(line)) |lit_len| {
            const avail = resp.len - next;
            const take = @min(lit_len, avail);
            try out.appendSlice(allocator, resp[next .. next + take]);
            found = true;
            next += take;
        }
        i = next;
    }

    if (!found) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

/// Parse the 3-digit reply code from an SMTP response.
///
/// An SMTP reply is one or more lines: `NNN-text` for continuation lines
/// and `NNN text` (space after the code) for the final line. Every line of
/// one reply carries the same code, so the leading 3 digits of the buffer
/// are sufficient. Returns null if the buffer does not begin with a
/// 3-digit code.
pub fn smtpReplyCode(resp: []const u8) ?u16 {
    if (resp.len < 3) return null;
    for (resp[0..3]) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u16, resp[0..3], 10) catch null;
}

/// True when an SMTP reply code is the one expected for a command stage.
pub fn smtpCodeIs(resp: []const u8, expected: u16) bool {
    return (smtpReplyCode(resp) orelse return false) == expected;
}

/// Parse a raw RFC 5322 message into a `ParsedEmail`.
/// - Headers are the lines before the first blank line; continuation lines
///   (leading whitespace) are folded.
/// - `From:` is decoded (RFC 2047) and the bare `<addr>` extracted.
/// - `Subject:` is RFC 2047-decoded.
/// - The body is HTML-stripped when the Content-Type is text/html.
/// All four fields are heap-owned on `allocator`.
pub fn parseEmailMessage(allocator: std.mem.Allocator, raw: []const u8) !ParsedEmail {
    // Split headers / body at the first blank line (CRLF or LF).
    const header_end = blk: {
        if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |p| break :blk .{ p, p + 4 };
        if (std.mem.indexOf(u8, raw, "\n\n")) |p| break :blk .{ p, p + 2 };
        break :blk .{ raw.len, raw.len };
    };
    const header_block = raw[0..header_end[0]];
    const body_block = raw[header_end[1]..];

    // Collect folded header values.
    const from_raw = try extractHeader(allocator, header_block, "from");
    defer allocator.free(from_raw);
    const subject_raw = try extractHeader(allocator, header_block, "subject");
    defer allocator.free(subject_raw);
    const msgid_raw = try extractHeader(allocator, header_block, "message-id");
    defer allocator.free(msgid_raw);
    const content_type = try extractHeader(allocator, header_block, "content-type");
    defer allocator.free(content_type);

    // Decode From and pull the address out of "Name <addr>".
    const from_decoded = try decodeRfc2047(allocator, from_raw);
    defer allocator.free(from_decoded);
    const from_addr = try allocator.dupe(u8, extractAddress(from_decoded));
    errdefer allocator.free(from_addr);

    const subject = try decodeRfc2047(allocator, subject_raw);
    errdefer allocator.free(subject);

    const message_id = try allocator.dupe(u8, stripAngleBrackets(std.mem.trim(u8, msgid_raw, " \t")));
    errdefer allocator.free(message_id);

    // Body: strip HTML when the message is text/html.
    const is_html = std.ascii.indexOfIgnoreCase(content_type, "text/html") != null;
    const body_trimmed = std.mem.trim(u8, body_block, " \t\r\n");
    const body = if (is_html)
        try stripHtml(allocator, body_trimmed)
    else
        try allocator.dupe(u8, body_trimmed);
    errdefer allocator.free(body);

    return .{
        .from_addr = from_addr,
        .subject = subject,
        .body = body,
        .message_id = message_id,
    };
}

/// Extract a (case-insensitive) header value from a header block, folding
/// continuation lines. Returns an owned, allocator-backed string (empty if
/// the header is absent).
pub fn extractHeader(allocator: std.mem.Allocator, header_block: []const u8, name: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var capturing = false;
    var line_it = std.mem.splitScalar(u8, header_block, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (capturing) {
            // Continuation line: starts with SP or TAB.
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                try result.append(allocator, ' ');
                try result.appendSlice(allocator, std.mem.trimLeft(u8, line, " \t"));
                continue;
            }
            // A non-continuation line ends the captured header.
            break;
        }
        // Header line: "Name: value".
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const this_name = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, this_name, " \t"), name)) continue;
        capturing = true;
        try result.appendSlice(allocator, std.mem.trimLeft(u8, line[colon + 1 ..], " \t"));
    }

    return result.toOwnedSlice(allocator);
}

/// Extract a bare email address from a "Display Name <addr@host>" header.
/// When no angle brackets are present, the whole trimmed string is returned.
pub fn extractAddress(from_value: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, from_value, '<')) |lt| {
        if (std.mem.indexOfScalarPos(u8, from_value, lt + 1, '>')) |gt| {
            return std.mem.trim(u8, from_value[lt + 1 .. gt], " \t");
        }
    }
    return std.mem.trim(u8, from_value, " \t");
}

/// Strip surrounding `<` `>` from a Message-ID value, if present.
pub fn stripAngleBrackets(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '<' and s[s.len - 1] == '>') return s[1 .. s.len - 1];
    return s;
}

/// Bounded dedup set that evicts oldest entries when capacity is reached.
pub const BoundedSeenSet = struct {
    allocator: std.mem.Allocator,
    set: std.StringHashMapUnmanaged(void),
    order: std.ArrayListUnmanaged([]const u8),
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) BoundedSeenSet {
        return .{
            .allocator = allocator,
            .set = .empty,
            .order = .empty,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *BoundedSeenSet) void {
        for (self.order.items) |key| self.allocator.free(key);
        self.order.deinit(self.allocator);
        self.set.deinit(self.allocator);
    }

    pub fn contains(self: *const BoundedSeenSet, id: []const u8) bool {
        return self.set.get(id) != null;
    }

    pub fn insert(self: *BoundedSeenSet, id: []const u8) !bool {
        if (self.set.get(id) != null) return false;

        if (self.order.items.len >= self.capacity) {
            const oldest = self.order.orderedRemove(0);
            _ = self.set.remove(oldest);
            self.allocator.free(oldest);
        }

        const duped = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(duped);
        try self.set.put(self.allocator, duped, {});
        try self.order.append(self.allocator, duped);
        return true;
    }

    pub fn len(self: *const BoundedSeenSet) usize {
        return self.set.count();
    }
};

/// Strip HTML tags from content (basic).
pub fn stripHtml(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var in_tag = false;
    for (html) |c| {
        switch (c) {
            '<' => in_tag = true,
            '>' => in_tag = false,
            else => {
                if (!in_tag) try result.append(allocator, c);
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Check if subject already has a "Re:" prefix (case-insensitive).
pub fn hasReplyPrefix(subject: []const u8) bool {
    return subject.len >= 3 and std.ascii.eqlIgnoreCase(subject[0..3], "Re:");
}

/// Return the reply subject: if it already starts with "Re:" (case-insensitive),
/// return as-is; otherwise return as-is (callers should use replySubjectAlloc for prefix).
/// This non-allocating version is used when the subject is written via format string.
pub fn replySubject(original: []const u8) []const u8 {
    return original;
}

/// Allocating version of replySubject — always returns "Re: <subject>" if not already prefixed.
pub fn replySubjectAlloc(allocator: std.mem.Allocator, original: []const u8) ![]u8 {
    if (original.len >= 3 and std.ascii.eqlIgnoreCase(original[0..3], "Re:")) {
        return allocator.dupe(u8, original);
    }
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "Re: ");
    try result.appendSlice(allocator, original);
    return result.toOwnedSlice(allocator);
}

/// Decode RFC 2047 encoded-word headers.
/// Supports =?CHARSET?B?BASE64?= and =?CHARSET?Q?QUOTED-PRINTABLE?=.
/// Non-encoded text is passed through as-is.
pub fn decodeRfc2047(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) {
        // Look for =? start of encoded-word
        if (i + 1 < encoded.len and encoded[i] == '=' and encoded[i + 1] == '?') {
            if (parseEncodedWord(encoded[i..])) |ew| {
                // Decode the payload
                if (std.ascii.eqlIgnoreCase(ew.encoding, "B")) {
                    // Base64 decode
                    const out_size = std.base64.standard.Decoder.calcSizeForSlice(ew.payload) catch {
                        try result.appendSlice(allocator, encoded[i .. i + ew.total_len]);
                        i += ew.total_len;
                        continue;
                    };
                    const start_len = result.items.len;
                    try result.resize(allocator, start_len + out_size);
                    std.base64.standard.Decoder.decode(result.items[start_len..][0..out_size], ew.payload) catch {
                        // Invalid base64 — pass through raw
                        result.shrinkRetainingCapacity(start_len);
                        try result.appendSlice(allocator, encoded[i .. i + ew.total_len]);
                        i += ew.total_len;
                        continue;
                    };
                } else if (std.ascii.eqlIgnoreCase(ew.encoding, "Q")) {
                    // Quoted-printable (index-based for =XX lookahead)
                    var qi: usize = 0;
                    while (qi < ew.payload.len) {
                        const qc = ew.payload[qi];
                        if (qc == '_') {
                            try result.append(allocator, ' ');
                            qi += 1;
                        } else if (qc == '=' and qi + 2 < ew.payload.len) {
                            const hi = hexDigit(ew.payload[qi + 1]) orelse {
                                try result.append(allocator, qc);
                                qi += 1;
                                continue;
                            };
                            const lo = hexDigit(ew.payload[qi + 2]) orelse {
                                try result.append(allocator, qc);
                                qi += 1;
                                continue;
                            };
                            try result.append(allocator, (hi << 4) | lo);
                            qi += 3;
                        } else {
                            try result.append(allocator, qc);
                            qi += 1;
                        }
                    }
                } else {
                    // Unknown encoding — pass through
                    try result.appendSlice(allocator, encoded[i .. i + ew.total_len]);
                }
                i += ew.total_len;
            } else {
                try result.append(allocator, encoded[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, encoded[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

const EncodedWord = struct {
    encoding: []const u8, // "B" or "Q"
    payload: []const u8,
    total_len: usize,
};

/// Parse an RFC 2047 encoded-word starting at the given slice.
/// Format: =?charset?encoding?payload?=
fn parseEncodedWord(s: []const u8) ?EncodedWord {
    if (s.len < 6 or s[0] != '=' or s[1] != '?') return null;

    // Find charset end (second ?)
    const charset_end = std.mem.indexOf(u8, s[2..], "?") orelse return null;
    const enc_start = 2 + charset_end + 1;
    if (enc_start >= s.len) return null;

    // Find encoding end (third ?)
    const enc_end_rel = std.mem.indexOf(u8, s[enc_start..], "?") orelse return null;
    const encoding = s[enc_start .. enc_start + enc_end_rel];
    const payload_start = enc_start + enc_end_rel + 1;
    if (payload_start >= s.len) return null;

    // Find ?= terminator
    const term_pos = std.mem.indexOf(u8, s[payload_start..], "?=") orelse return null;
    const payload = s[payload_start .. payload_start + term_pos];
    const total_len = payload_start + term_pos + 2;

    return .{
        .encoding = encoding,
        .payload = payload,
        .total_len = total_len,
    };
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "bounded seen set insert and contains" {
    const allocator = std.testing.allocator;
    var set = BoundedSeenSet.init(allocator, 10);
    defer set.deinit();
    try std.testing.expect(try set.insert("a"));
    try std.testing.expect(set.contains("a"));
    try std.testing.expect(!set.contains("b"));
}

test "bounded seen set rejects duplicates" {
    const allocator = std.testing.allocator;
    var set = BoundedSeenSet.init(allocator, 10);
    defer set.deinit();
    try std.testing.expect(try set.insert("a"));
    try std.testing.expect(!(try set.insert("a")));
    try std.testing.expectEqual(@as(usize, 1), set.len());
}

test "bounded seen set evicts oldest at capacity" {
    const allocator = std.testing.allocator;
    var set = BoundedSeenSet.init(allocator, 3);
    defer set.deinit();
    _ = try set.insert("a");
    _ = try set.insert("b");
    _ = try set.insert("c");
    try std.testing.expectEqual(@as(usize, 3), set.len());

    _ = try set.insert("d");
    try std.testing.expectEqual(@as(usize, 3), set.len());
    try std.testing.expect(!set.contains("a"));
    try std.testing.expect(set.contains("b"));
    try std.testing.expect(set.contains("c"));
    try std.testing.expect(set.contains("d"));
}

test "bounded seen set capacity one" {
    const allocator = std.testing.allocator;
    var set = BoundedSeenSet.init(allocator, 1);
    defer set.deinit();
    _ = try set.insert("a");
    try std.testing.expect(set.contains("a"));
    _ = try set.insert("b");
    try std.testing.expect(!set.contains("a"));
    try std.testing.expect(set.contains("b"));
    try std.testing.expectEqual(@as(usize, 1), set.len());
}

test "strip html basic" {
    const allocator = std.testing.allocator;
    const result = try stripHtml(allocator, "<p>Hello <b>world</b>!</p>");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello world!", result);
}

test "strip html no tags" {
    const allocator = std.testing.allocator;
    const result = try stripHtml(allocator, "plain text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

// ════════════════════════════════════════════════════════════════════════════
// Additional Email Tests (ported from ZeroClaw Rust)
// ════════════════════════════════════════════════════════════════════════════

test "bounded seen set evicts in fifo order" {
    const allocator = std.testing.allocator;
    var set = BoundedSeenSet.init(allocator, 2);
    defer set.deinit();
    _ = try set.insert("first");
    _ = try set.insert("second");
    _ = try set.insert("third");
    try std.testing.expect(!set.contains("first"));
    try std.testing.expect(set.contains("second"));
    try std.testing.expect(set.contains("third"));

    _ = try set.insert("fourth");
    try std.testing.expect(!set.contains("second"));
    try std.testing.expect(set.contains("third"));
    try std.testing.expect(set.contains("fourth"));
}

test "email sender allowed case insensitive full address" {
    const senders = [_][]const u8{"User@Example.COM"};
    const ch = EmailChannel.init(std.testing.allocator, .{ .allow_from = &senders });
    try std.testing.expect(ch.isSenderAllowed("user@example.com"));
    try std.testing.expect(ch.isSenderAllowed("USER@EXAMPLE.COM"));
}

test "email sender domain with @ case insensitive" {
    const senders = [_][]const u8{"@Example.Com"};
    const ch = EmailChannel.init(std.testing.allocator, .{ .allow_from = &senders });
    try std.testing.expect(ch.isSenderAllowed("anyone@example.com"));
    try std.testing.expect(ch.isSenderAllowed("USER@EXAMPLE.COM"));
}

test "email sender multiple senders" {
    const senders = [_][]const u8{ "alice@example.com", "bob@test.com" };
    const ch = EmailChannel.init(std.testing.allocator, .{ .allow_from = &senders });
    try std.testing.expect(ch.isSenderAllowed("alice@example.com"));
    try std.testing.expect(ch.isSenderAllowed("bob@test.com"));
    try std.testing.expect(!ch.isSenderAllowed("eve@evil.com"));
}

test "email config defaults" {
    const config = config_types.EmailConfig{};
    try std.testing.expectEqual(@as(u16, 993), config.imap_port);
    try std.testing.expectEqualStrings("INBOX", config.imap_folder);
    try std.testing.expectEqual(@as(u16, 587), config.smtp_port);
    try std.testing.expect(config.smtp_tls);
    try std.testing.expectEqual(@as(u64, 60), config.poll_interval_secs);
}

test "strip html nested tags" {
    const allocator = std.testing.allocator;
    const result = try stripHtml(allocator, "<div><p>Hello</p><br/><p>World</p></div>");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("HelloWorld", result);
}

test "strip html empty input" {
    const allocator = std.testing.allocator;
    const result = try stripHtml(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "strip html only tags" {
    const allocator = std.testing.allocator;
    const result = try stripHtml(allocator, "<br/><hr/><img src=\"x\"/>");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "bounded seen set empty contains false" {
    const allocator = std.testing.allocator;
    var set = BoundedSeenSet.init(allocator, 10);
    defer set.deinit();
    try std.testing.expect(!set.contains("anything"));
    try std.testing.expectEqual(@as(usize, 0), set.len());
}

test "bounded seen set large capacity" {
    const allocator = std.testing.allocator;
    var set = BoundedSeenSet.init(allocator, 100);
    defer set.deinit();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [20]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "key_{d}", .{i}) catch unreachable;
        _ = try set.insert(key);
    }
    try std.testing.expectEqual(@as(usize, 50), set.len());
}

test "email sender wildcard with specific" {
    const senders = [_][]const u8{ "alice@example.com", "*" };
    const ch = EmailChannel.init(std.testing.allocator, .{ .allow_from = &senders });
    try std.testing.expect(ch.isSenderAllowed("anyone@anything.com"));
}

test "email sender short address not domain match" {
    // An address shorter than the domain should not match
    const senders = [_][]const u8{"example.com"};
    const ch = EmailChannel.init(std.testing.allocator, .{ .allow_from = &senders });
    try std.testing.expect(!ch.isSenderAllowed("@example.com")); // needs local part > 0
}

// ════════════════════════════════════════════════════════════════════════════
// Consent Gates Tests
// ════════════════════════════════════════════════════════════════════════════

test "consent granted default is true" {
    const config = config_types.EmailConfig{};
    try std.testing.expect(config.consent_granted);
}

test "consent not granted blocks send" {
    var ch = EmailChannel.init(std.testing.allocator, .{ .consent_granted = false });
    defer ch.deinit();
    const result = ch.sendMessage("test@example.com", "hello");
    try std.testing.expectError(error.ConsentNotGranted, result);
}

test "consent granted allows send attempt" {
    // With consent but invalid host, we expect SmtpConnectError (not ConsentNotGranted)
    var ch = EmailChannel.init(std.testing.allocator, .{
        .consent_granted = true,
        .smtp_host = "999.999.999.999",
    });
    defer ch.deinit();
    const result = ch.sendMessage("test@example.com", "hello");
    try std.testing.expectError(error.SmtpConnectError, result);
}

// ════════════════════════════════════════════════════════════════════════════
// In-Reply-To / References Tests
// ════════════════════════════════════════════════════════════════════════════

test "track message id stores and retrieves" {
    const allocator = std.testing.allocator;
    var ch = EmailChannel.init(allocator, .{});
    defer ch.deinit();

    try ch.trackMessageId("alice@example.com", "msg-001");
    const got = ch.reply_message_ids.get("alice@example.com");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("msg-001", got.?);
}

test "track message id overwrites previous" {
    const allocator = std.testing.allocator;
    var ch = EmailChannel.init(allocator, .{});
    defer ch.deinit();

    try ch.trackMessageId("alice@example.com", "msg-001");
    try ch.trackMessageId("alice@example.com", "msg-002");
    const got = ch.reply_message_ids.get("alice@example.com");
    try std.testing.expectEqualStrings("msg-002", got.?);
}

test "track message id multiple senders" {
    const allocator = std.testing.allocator;
    var ch = EmailChannel.init(allocator, .{});
    defer ch.deinit();

    try ch.trackMessageId("alice@example.com", "msg-a");
    try ch.trackMessageId("bob@example.com", "msg-b");
    try std.testing.expectEqualStrings("msg-a", ch.reply_message_ids.get("alice@example.com").?);
    try std.testing.expectEqualStrings("msg-b", ch.reply_message_ids.get("bob@example.com").?);
}

// ════════════════════════════════════════════════════════════════════════════
// Subject Tracking Tests
// ════════════════════════════════════════════════════════════════════════════

test "hasReplyPrefix detects Re prefix" {
    try std.testing.expect(hasReplyPrefix("Re: Hello"));
    try std.testing.expect(hasReplyPrefix("re: Hello"));
    try std.testing.expect(hasReplyPrefix("RE: Hello"));
    try std.testing.expect(hasReplyPrefix("Re:no space"));
}

test "hasReplyPrefix rejects non-Re" {
    try std.testing.expect(!hasReplyPrefix("Hello"));
    try std.testing.expect(!hasReplyPrefix("Fwd: Hello"));
    try std.testing.expect(!hasReplyPrefix(""));
    try std.testing.expect(!hasReplyPrefix("Re"));
}

test "replySubjectAlloc adds prefix" {
    const allocator = std.testing.allocator;
    const result = try replySubjectAlloc(allocator, "Hello World");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Re: Hello World", result);
}

test "replySubjectAlloc preserves existing Re" {
    const allocator = std.testing.allocator;
    const result = try replySubjectAlloc(allocator, "Re: Hello World");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Re: Hello World", result);
}

test "replySubjectAlloc empty subject" {
    const allocator = std.testing.allocator;
    const result = try replySubjectAlloc(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Re: ", result);
}

test "replySubjectAlloc case insensitive RE" {
    const allocator = std.testing.allocator;
    const result = try replySubjectAlloc(allocator, "RE: Already");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("RE: Already", result);
}

// ════════════════════════════════════════════════════════════════════════════
// RFC 2047 Decoding Tests
// ════════════════════════════════════════════════════════════════════════════

test "decodeRfc2047 base64 utf8" {
    const allocator = std.testing.allocator;
    // "Hello" in base64 = "SGVsbG8="
    const result = try decodeRfc2047(allocator, "=?UTF-8?B?SGVsbG8=?=");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeRfc2047 quoted printable" {
    const allocator = std.testing.allocator;
    const result = try decodeRfc2047(allocator, "=?UTF-8?Q?Hello_World?=");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "decodeRfc2047 quoted printable hex escape" {
    const allocator = std.testing.allocator;
    const result = try decodeRfc2047(allocator, "=?UTF-8?Q?caf=C3=A9?=");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("caf\xc3\xa9", result);
}

test "decodeRfc2047 plain text passthrough" {
    const allocator = std.testing.allocator;
    const result = try decodeRfc2047(allocator, "Just plain text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Just plain text", result);
}

test "decodeRfc2047 mixed encoded and plain" {
    const allocator = std.testing.allocator;
    const result = try decodeRfc2047(allocator, "Hello =?UTF-8?B?V29ybGQ=?= !");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World !", result);
}

test "decodeRfc2047 empty input" {
    const allocator = std.testing.allocator;
    const result = try decodeRfc2047(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "decodeRfc2047 case insensitive encoding" {
    const allocator = std.testing.allocator;
    const result = try decodeRfc2047(allocator, "=?utf-8?b?SGVsbG8=?=");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeRfc2047 quoted printable underscore to space" {
    const allocator = std.testing.allocator;
    const result = try decodeRfc2047(allocator, "=?UTF-8?Q?Re:_Your_Order?=");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Re: Your Order", result);
}

test "parseEncodedWord valid base64" {
    const ew = parseEncodedWord("=?UTF-8?B?SGVsbG8=?=").?;
    try std.testing.expectEqualStrings("B", ew.encoding);
    try std.testing.expectEqualStrings("SGVsbG8=", ew.payload);
    try std.testing.expectEqual(@as(usize, 20), ew.total_len);
}

test "parseEncodedWord invalid returns null" {
    try std.testing.expect(parseEncodedWord("not encoded") == null);
    try std.testing.expect(parseEncodedWord("=?") == null);
    try std.testing.expect(parseEncodedWord("") == null);
}

test "hexDigit valid digits" {
    try std.testing.expectEqual(@as(u8, 0), hexDigit('0').?);
    try std.testing.expectEqual(@as(u8, 9), hexDigit('9').?);
    try std.testing.expectEqual(@as(u8, 10), hexDigit('A').?);
    try std.testing.expectEqual(@as(u8, 15), hexDigit('F').?);
    try std.testing.expectEqual(@as(u8, 10), hexDigit('a').?);
    try std.testing.expectEqual(@as(u8, 15), hexDigit('f').?);
}

test "hexDigit invalid returns null" {
    try std.testing.expect(hexDigit('G') == null);
    try std.testing.expect(hexDigit(' ') == null);
    try std.testing.expect(hexDigit('z') == null);
}

// ════════════════════════════════════════════════════════════════════════════
// Mark-as-Seen Test
// ════════════════════════════════════════════════════════════════════════════

test "markMessageSeen method exists and is live" {
    // markMessageSeen is now wired — pollMessages calls it after each FETCH
    // to flag the message \Seen on the IMAP server. Guard the signature.
    var ch = EmailChannel.init(std.testing.allocator, .{});
    defer ch.deinit();
    const info = @typeInfo(@TypeOf(EmailChannel.markMessageSeen));
    try std.testing.expect(info == .@"fn");
}

test "nextTag increments and wraps" {
    var ch = EmailChannel.init(std.testing.allocator, .{});
    defer ch.deinit();
    try std.testing.expectEqual(@as(u32, 1), ch.nextTag());
    try std.testing.expectEqual(@as(u32, 2), ch.nextTag());
    try std.testing.expectEqual(@as(u32, 3), ch.nextTag());
}

// ════════════════════════════════════════════════════════════════════════════
// Channel Activation Contract Tests
// ════════════════════════════════════════════════════════════════════════════
//
// channel_manager.collectConfiguredChannels picks up Email through the generic
// path: it requires initFromConfig + channel(). Email is classified `.polling`
// in channel_catalog, so channel_loop.runEmailLoop drives pollMessages on a
// thread. These tests pin that contract so the channel cannot silently drift
// out of the generic registration / polling path.

test "email exposes initFromConfig + channel for generic registration" {
    // channelTypeForModule in channel_manager.zig selects the channel type by
    // looking for these two decls — guard them here.
    try std.testing.expect(@hasDecl(EmailChannel, "initFromConfig"));
    try std.testing.expect(@hasDecl(EmailChannel, "channel"));
}

test "email exposes pollMessages for the polling listener contract" {
    // channel_loop.runEmailLoop calls pollMessages each cycle, exactly like
    // telegram.pollUpdates / signal.pollMessages / matrix.pollMessages.
    try std.testing.expect(@hasDecl(EmailChannel, "pollMessages"));
    const info = @typeInfo(@TypeOf(EmailChannel.pollMessages));
    try std.testing.expect(info == .@"fn");
}

test "email channel vtable name reports email" {
    var ch = EmailChannel.initFromConfig(std.testing.allocator, .{
        .account_id = "main",
        .from_address = "bot@example.com",
    });
    defer ch.deinit();
    const c = ch.channel();
    try std.testing.expectEqualStrings("email", c.name());
}

test "email channel start and stop drive the running flag" {
    // channel_manager's polling path calls channel.start() then channel.stop().
    var ch = EmailChannel.initFromConfig(std.testing.allocator, .{
        .account_id = "main",
        .from_address = "bot@example.com",
    });
    defer ch.deinit();
    const c = ch.channel();
    try std.testing.expect(!ch.healthCheck());
    try c.start();
    try std.testing.expect(ch.healthCheck());
    c.stop();
    try std.testing.expect(!ch.healthCheck());
}

test "email pollMessages returns empty in test build" {
    // builtin.is_test short-circuits pollMessages — no live network in CI.
    var ch = EmailChannel.initFromConfig(std.testing.allocator, .{
        .account_id = "main",
        .imap_host = "imap.example.com",
        .username = "u",
        .password = "p",
    });
    defer ch.deinit();
    const msgs = try ch.pollMessages(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}

// ════════════════════════════════════════════════════════════════════════════
// SMTP TLS Path Selection Tests
// ════════════════════════════════════════════════════════════════════════════

test "smtpTlsMode plain when tls disabled" {
    try std.testing.expectEqual(
        EmailChannel.SmtpTlsMode.plain,
        EmailChannel.smtpTlsMode(.{ .smtp_tls = false, .smtp_port = 587 }),
    );
    try std.testing.expectEqual(
        EmailChannel.SmtpTlsMode.plain,
        EmailChannel.smtpTlsMode(.{ .smtp_tls = false, .smtp_port = 465 }),
    );
}

test "smtpTlsMode implicit on port 465" {
    try std.testing.expectEqual(
        EmailChannel.SmtpTlsMode.implicit,
        EmailChannel.smtpTlsMode(.{ .smtp_tls = true, .smtp_port = 465 }),
    );
}

test "smtpTlsMode starttls on port 587" {
    try std.testing.expectEqual(
        EmailChannel.SmtpTlsMode.starttls,
        EmailChannel.smtpTlsMode(.{ .smtp_tls = true, .smtp_port = 587 }),
    );
}

test "smtpTlsMode starttls on non-standard tls port" {
    // Anything that isn't 465 with TLS on uses STARTTLS (e.g. port 25).
    try std.testing.expectEqual(
        EmailChannel.SmtpTlsMode.starttls,
        EmailChannel.smtpTlsMode(.{ .smtp_tls = true, .smtp_port = 25 }),
    );
    try std.testing.expectEqual(
        EmailChannel.SmtpTlsMode.starttls,
        EmailChannel.smtpTlsMode(.{ .smtp_tls = true, .smtp_port = 2525 }),
    );
}

// ════════════════════════════════════════════════════════════════════════════
// SMTP Reply Code Parsing Tests
// ════════════════════════════════════════════════════════════════════════════

test "smtpReplyCode parses single-line reply" {
    try std.testing.expectEqual(@as(?u16, 250), smtpReplyCode("250 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 354), smtpReplyCode("354 Start mail input\r\n"));
    try std.testing.expectEqual(@as(?u16, 550), smtpReplyCode("550 No such user\r\n"));
}

test "smtpReplyCode parses multiline reply (continuation form)" {
    // EHLO replies are multiline: "250-..." lines then a final "250 ..." line.
    const ehlo = "250-mail.example.com\r\n250-SIZE 35882577\r\n250 STARTTLS\r\n";
    try std.testing.expectEqual(@as(?u16, 250), smtpReplyCode(ehlo));
}

test "smtpReplyCode rejects malformed input" {
    try std.testing.expect(smtpReplyCode("") == null);
    try std.testing.expect(smtpReplyCode("OK") == null);
    try std.testing.expect(smtpReplyCode("2x0 OK") == null);
    try std.testing.expect(smtpReplyCode("\r\n") == null);
}

test "smtpCodeIs matches expected stage codes" {
    try std.testing.expect(smtpCodeIs("250 OK\r\n", 250));
    try std.testing.expect(smtpCodeIs("354 go ahead\r\n", 354));
    try std.testing.expect(!smtpCodeIs("550 rejected\r\n", 250));
    try std.testing.expect(!smtpCodeIs("250 OK\r\n", 354));
    // A non-2xx/3xx reject is not the expected code.
    try std.testing.expect(!smtpCodeIs("421 Service not available\r\n", 250));
    // Garbage never matches.
    try std.testing.expect(!smtpCodeIs("", 250));
}

// ════════════════════════════════════════════════════════════════════════════
// IMAP Response Parsing Tests
// ════════════════════════════════════════════════════════════════════════════

test "responseHasTaggedCompletion detects tag line" {
    const resp = "* 3 EXISTS\r\nA0001 OK SELECT completed\r\n";
    try std.testing.expect(responseHasTaggedCompletion(resp, "A0001"));
    try std.testing.expect(!responseHasTaggedCompletion(resp, "A0002"));
}

test "responseHasTaggedCompletion false on untagged-only response" {
    const resp = "* OK greeting\r\n* CAPABILITY IMAP4rev1\r\n";
    try std.testing.expect(!responseHasTaggedCompletion(resp, "A0001"));
}

test "responseIsOk true for OK completion" {
    const resp = "* 3 EXISTS\r\nA0007 OK SELECT completed\r\n";
    try std.testing.expect(responseIsOk(resp, 7));
}

test "responseIsOk false for NO completion" {
    const resp = "A0007 NO LOGIN failed\r\n";
    try std.testing.expect(!responseIsOk(resp, 7));
}

test "responseIsOk false for BAD completion" {
    const resp = "A0007 BAD command unknown\r\n";
    try std.testing.expect(!responseIsOk(resp, 7));
}

test "responseIsOk false when tag absent" {
    const resp = "* OK still going\r\n";
    try std.testing.expect(!responseIsOk(resp, 7));
}

test "parseSearchUids extracts uid list" {
    const allocator = std.testing.allocator;
    var storage: [256]u8 = undefined;
    var uids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer uids.deinit(allocator);
    const resp = "* SEARCH 1 4 7 99\r\nA0003 OK SEARCH completed\r\n";
    try parseSearchUids(resp, &storage, &uids, allocator);
    try std.testing.expectEqual(@as(usize, 4), uids.items.len);
    try std.testing.expectEqualStrings("1", uids.items[0]);
    try std.testing.expectEqualStrings("4", uids.items[1]);
    try std.testing.expectEqualStrings("7", uids.items[2]);
    try std.testing.expectEqualStrings("99", uids.items[3]);
}

test "parseSearchUids empty search result" {
    const allocator = std.testing.allocator;
    var storage: [256]u8 = undefined;
    var uids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer uids.deinit(allocator);
    const resp = "* SEARCH\r\nA0003 OK SEARCH completed\r\n";
    try parseSearchUids(resp, &storage, &uids, allocator);
    try std.testing.expectEqual(@as(usize, 0), uids.items.len);
}

test "parseSearchUids ignores non-digit tokens" {
    const allocator = std.testing.allocator;
    var storage: [256]u8 = undefined;
    var uids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer uids.deinit(allocator);
    const resp = "* SEARCH 12 abc 34\r\n";
    try parseSearchUids(resp, &storage, &uids, allocator);
    try std.testing.expectEqual(@as(usize, 2), uids.items.len);
    try std.testing.expectEqualStrings("12", uids.items[0]);
    try std.testing.expectEqualStrings("34", uids.items[1]);
}

test "parseSearchUids case insensitive SEARCH keyword" {
    const allocator = std.testing.allocator;
    var storage: [256]u8 = undefined;
    var uids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer uids.deinit(allocator);
    const resp = "* search 5\r\n";
    try parseSearchUids(resp, &storage, &uids, allocator);
    try std.testing.expectEqual(@as(usize, 1), uids.items.len);
    try std.testing.expectEqualStrings("5", uids.items[0]);
}

test "extractFetchLiteral pulls body from FETCH response" {
    const resp = "* 1 FETCH (UID 7 BODY[] {11}\r\nHello World)\r\nA0004 OK\r\n";
    const lit = extractFetchLiteral(resp).?;
    try std.testing.expectEqualStrings("Hello World", lit);
}

test "extractFetchLiteral returns null without literal" {
    const resp = "* 1 FETCH (UID 7 FLAGS (\\Seen))\r\nA0004 OK\r\n";
    try std.testing.expect(extractFetchLiteral(resp) == null);
}

test "extractFetchLiteral truncated literal returns available bytes" {
    // Server claims 50 bytes but only 5 are present — return what we have.
    const resp = "* 1 FETCH (BODY[] {50}\r\nshort";
    const lit = extractFetchLiteral(resp).?;
    try std.testing.expectEqualStrings("short", lit);
}

test "extractFetchLiteral ignores a brace inside the literal body" {
    // The literal body itself contains "{99}" — must NOT be re-interpreted
    // as a second literal marker; the framed read returns the first literal.
    const resp = "* 1 FETCH (BODY[] {18}\r\nbody has a {99} ok)\r\nA0004 OK\r\n";
    const lit = extractFetchLiteral(resp).?;
    try std.testing.expectEqualStrings("body has a {99} ok", lit);
}

// ── imapLiteralLen ──────────────────────────────────────────────────────────

test "imapLiteralLen parses trailing literal marker" {
    try std.testing.expectEqual(@as(?usize, 11), imapLiteralLen("* 1 FETCH (BODY[] {11}"));
    try std.testing.expectEqual(@as(?usize, 0), imapLiteralLen("x {0}"));
}

test "imapLiteralLen accepts non-synchronizing literal form" {
    try std.testing.expectEqual(@as(?usize, 42), imapLiteralLen("a {42+}"));
}

test "imapLiteralLen rejects non-literal lines" {
    try std.testing.expect(imapLiteralLen("A0004 OK FETCH completed") == null);
    try std.testing.expect(imapLiteralLen("* 1 FETCH (UID 7)") == null);
    try std.testing.expect(imapLiteralLen("{12} not at end") == null);
    try std.testing.expect(imapLiteralLen("{}") == null);
    try std.testing.expect(imapLiteralLen("") == null);
}

// ── imapResponseComplete (literal-length-aware framing) ─────────────────────

test "imapResponseComplete true when tagged completion present" {
    const resp = "* 1 FETCH (FLAGS (\\Seen))\r\nA0004 OK FETCH completed\r\n";
    try std.testing.expect(imapResponseComplete(resp, "A0004"));
}

test "imapResponseComplete false before tagged completion arrives" {
    const resp = "* 1 FETCH (FLAGS (\\Seen))\r\n";
    try std.testing.expect(!imapResponseComplete(resp, "A0004"));
}

test "imapResponseComplete ignores tagged-completion-looking line inside a literal" {
    // The email body literal contains a line that looks exactly like a
    // tagged completion. Literal framing must skip it — the read is NOT
    // complete until the real A0042 line outside the literal.
    const body = "X-Header: hi\r\nA0042 OK this is inside the body\r\n";
    const resp = std.fmt.comptimePrint(
        "* 1 FETCH (BODY[] {{{d}}}\r\n{s})\r\n",
        .{ body.len, body },
    );
    // No real tagged completion yet — must report incomplete.
    try std.testing.expect(!imapResponseComplete(resp, "A0042"));
    // Append the genuine tagged completion: now complete.
    const full = resp ++ "A0042 OK FETCH completed\r\n";
    try std.testing.expect(imapResponseComplete(full, "A0042"));
}

test "imapResponseComplete false when literal is not yet fully received" {
    // Server declared {100} but only 4 octets arrived — incomplete.
    const resp = "* 1 FETCH (BODY[] {100}\r\nfour";
    try std.testing.expect(!imapResponseComplete(resp, "A0004"));
}

test "imapResponseComplete handles literal then tagged completion" {
    const resp = "* 1 FETCH (BODY[] {5}\r\nhello)\r\nA0007 OK done\r\n";
    try std.testing.expect(imapResponseComplete(resp, "A0007"));
}

// ── joinFetchLiterals (HEADER + TEXT reassembly) ────────────────────────────

test "joinFetchLiterals concatenates header and text literals" {
    const allocator = std.testing.allocator;
    const header = "From: a@b.com\r\nSubject: Hi\r\n\r\n";
    const text = "the body text";
    const resp = std.fmt.comptimePrint(
        "* 1 FETCH (BODY[HEADER] {{{d}}}\r\n{s} BODY[TEXT] {{{d}}}\r\n{s})\r\nA0009 OK\r\n",
        .{ header.len, header, text.len, text },
    );
    const joined = (try joinFetchLiterals(allocator, resp)).?;
    defer allocator.free(joined);
    try std.testing.expectEqualStrings(header ++ text, joined);
}

test "joinFetchLiterals returns null when no literal present" {
    const allocator = std.testing.allocator;
    const resp = "* 1 FETCH (UID 7 FLAGS (\\Seen))\r\nA0009 OK\r\n";
    try std.testing.expect((try joinFetchLiterals(allocator, resp)) == null);
}

test "joinFetchLiterals output round-trips through parseEmailMessage" {
    const allocator = std.testing.allocator;
    const header = "From: Alice <alice@example.com>\r\nSubject: Reassembled\r\n\r\n";
    const text = "literal-framed body";
    const resp = std.fmt.comptimePrint(
        "* 1 FETCH (BODY[HEADER] {{{d}}}\r\n{s} BODY[TEXT] {{{d}}}\r\n{s})\r\nA0011 OK\r\n",
        .{ header.len, header, text.len, text },
    );
    const joined = (try joinFetchLiterals(allocator, resp)).?;
    defer allocator.free(joined);
    const parsed = try parseEmailMessage(allocator, joined);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("alice@example.com", parsed.from_addr);
    try std.testing.expectEqualStrings("Reassembled", parsed.subject);
    try std.testing.expectEqualStrings("literal-framed body", parsed.body);
}

// ════════════════════════════════════════════════════════════════════════════
// Email Message Parsing Tests
// ════════════════════════════════════════════════════════════════════════════

test "extractHeader pulls simple header" {
    const allocator = std.testing.allocator;
    const headers = "From: alice@example.com\r\nSubject: Hello\r\nDate: today";
    const from = try extractHeader(allocator, headers, "from");
    defer allocator.free(from);
    try std.testing.expectEqualStrings("alice@example.com", from);
}

test "extractHeader is case insensitive" {
    const allocator = std.testing.allocator;
    const headers = "FROM: bob@example.com\r\nSUBJECT: Hi";
    const subj = try extractHeader(allocator, headers, "subject");
    defer allocator.free(subj);
    try std.testing.expectEqualStrings("Hi", subj);
}

test "extractHeader folds continuation lines" {
    const allocator = std.testing.allocator;
    const headers = "Subject: This is a long\r\n subject line\r\nFrom: x@y.com";
    const subj = try extractHeader(allocator, headers, "subject");
    defer allocator.free(subj);
    try std.testing.expectEqualStrings("This is a long subject line", subj);
}

test "extractHeader absent header returns empty" {
    const allocator = std.testing.allocator;
    const headers = "From: a@b.com\r\nSubject: Hi";
    const cc = try extractHeader(allocator, headers, "cc");
    defer allocator.free(cc);
    try std.testing.expectEqualStrings("", cc);
}

test "extractAddress pulls bare address from display name" {
    try std.testing.expectEqualStrings(
        "alice@example.com",
        extractAddress("Alice Smith <alice@example.com>"),
    );
}

test "extractAddress passthrough when no angle brackets" {
    try std.testing.expectEqualStrings(
        "bob@example.com",
        extractAddress("bob@example.com"),
    );
}

test "stripAngleBrackets removes message id wrapping" {
    try std.testing.expectEqualStrings("abc@host", stripAngleBrackets("<abc@host>"));
    try std.testing.expectEqualStrings("abc@host", stripAngleBrackets("abc@host"));
}

test "parseEmailMessage plain text" {
    const allocator = std.testing.allocator;
    const raw =
        "From: Alice <alice@example.com>\r\n" ++
        "Subject: Test Subject\r\n" ++
        "Message-ID: <msg-001@example.com>\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Hello, this is the body.\r\n";
    const parsed = try parseEmailMessage(allocator, raw);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("alice@example.com", parsed.from_addr);
    try std.testing.expectEqualStrings("Test Subject", parsed.subject);
    try std.testing.expectEqualStrings("msg-001@example.com", parsed.message_id);
    try std.testing.expectEqualStrings("Hello, this is the body.", parsed.body);
}

test "parseEmailMessage html body is stripped" {
    const allocator = std.testing.allocator;
    const raw =
        "From: bob@example.com\r\n" ++
        "Subject: HTML mail\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "\r\n" ++
        "<html><body><p>Hi <b>there</b></p></body></html>\r\n";
    const parsed = try parseEmailMessage(allocator, raw);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("Hi there", parsed.body);
}

test "parseEmailMessage rfc2047 encoded subject" {
    const allocator = std.testing.allocator;
    const raw =
        "From: =?UTF-8?B?QWxpY2U=?= <alice@example.com>\r\n" ++
        "Subject: =?UTF-8?B?SGVsbG8=?=\r\n" ++
        "\r\n" ++
        "body text";
    const parsed = try parseEmailMessage(allocator, raw);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("alice@example.com", parsed.from_addr);
    try std.testing.expectEqualStrings("Hello", parsed.subject);
}

test "parseEmailMessage malformed missing blank line" {
    const allocator = std.testing.allocator;
    // No header/body separator — everything is treated as headers, body empty.
    const raw = "From: a@b.com\r\nSubject: only headers\r\n";
    const parsed = try parseEmailMessage(allocator, raw);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("a@b.com", parsed.from_addr);
    try std.testing.expectEqualStrings("only headers", parsed.subject);
    try std.testing.expectEqualStrings("", parsed.body);
}

test "parseEmailMessage malformed empty input" {
    const allocator = std.testing.allocator;
    const parsed = try parseEmailMessage(allocator, "");
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("", parsed.from_addr);
    try std.testing.expectEqualStrings("", parsed.subject);
    try std.testing.expectEqualStrings("", parsed.body);
    try std.testing.expectEqualStrings("", parsed.message_id);
}

test "parseEmailMessage LF-only line endings" {
    const allocator = std.testing.allocator;
    const raw = "From: c@d.com\nSubject: lf test\n\nbody here";
    const parsed = try parseEmailMessage(allocator, raw);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("c@d.com", parsed.from_addr);
    try std.testing.expectEqualStrings("lf test", parsed.subject);
    try std.testing.expectEqualStrings("body here", parsed.body);
}

// ════════════════════════════════════════════════════════════════════════════
// Allowlist Filtering for Inbound (pollMessages path)
// ════════════════════════════════════════════════════════════════════════════

test "inbound allowlist accepts parsed sender" {
    const senders = [_][]const u8{"alice@example.com"};
    var ch = EmailChannel.init(std.testing.allocator, .{ .allow_from = &senders });
    defer ch.deinit();
    // Sender extracted from a "Name <addr>" From header must match.
    const addr = extractAddress("Alice <alice@example.com>");
    try std.testing.expect(ch.isSenderAllowed(addr));
}

test "inbound allowlist rejects non-listed sender" {
    const senders = [_][]const u8{"alice@example.com"};
    var ch = EmailChannel.init(std.testing.allocator, .{ .allow_from = &senders });
    defer ch.deinit();
    const addr = extractAddress("Eve <eve@evil.com>");
    try std.testing.expect(!ch.isSenderAllowed(addr));
}

test "inbound allowlist empty denies all" {
    var ch = EmailChannel.init(std.testing.allocator, .{});
    defer ch.deinit();
    try std.testing.expect(!ch.isSenderAllowed("anyone@anywhere.com"));
}

// ════════════════════════════════════════════════════════════════════════════
// Inbound De-dup Set Integration
// ════════════════════════════════════════════════════════════════════════════

test "email channel seen set de-dups uids" {
    var ch = EmailChannel.init(std.testing.allocator, .{});
    defer ch.deinit();
    try std.testing.expect(try ch.seen.insert("100"));
    try std.testing.expect(!ch.seen.contains("101"));
    try std.testing.expect(ch.seen.contains("100"));
    // Re-inserting the same UID is a no-op (already seen).
    try std.testing.expect(!(try ch.seen.insert("100")));
}

test "email channel seen capacity constant" {
    try std.testing.expectEqual(@as(usize, 1024), EmailChannel.SEEN_CAPACITY);
}
