//! URL sanitization — SSRF defense for the gateway-side `extension_*`
//! tool family.
//!
//! Implements the deny classes specified in `docs/ssrf-blocklist.md`
//! (the single authoritative source). The in-cluster orchestrator lane
//! (`services/browser-orchestrator/urlguard.go`) implements the same
//! classes for the server-side browser. Same threat model: an attacker
//! prompt (or upstream prompt-injection) can drive the tool dispatcher
//! to navigate the user's REAL browser at `http://169.254.169.254/`,
//! RFC1918, loopback, IPv6 link-local / unique-local, or DNS aliases
//! that resolve to any of the above. Any change to the deny classes MUST
//! update both sanitizers and their parity tests (see docs/ssrf-blocklist.md).
//!
//! Default-deny matches AGENTS.md §3.5 (secure-by-default, least
//! privilege). Operators with a legitimate need to drive a LAN service
//! (kiosk deploys, internal staging hosts) opt in via the
//! `extension_browser_allowlist` field on `GatewayConfig` — a hostname
//! in the allowlist skips the deny check.
//!
//! Coverage classes (each pinned by a regression test below):
//!   1. Scheme: only http:/https:/ accepted; file://, javascript:,
//!      chrome://, data: etc. → `scheme_blocked`.
//!   2. IPv4 loopback (127/8), RFC1918 (10/8, 172.16/12, 192.168/16),
//!      link-local (169.254/16 — special-cases 169.254.169.254 as
//!      metadata), unspecified (0.0.0.0, bare `0`).
//!   3. IPv6 loopback (::1), link-local (fe80::/10), unique-local
//!      (fc00::/7 — covers fd00::ec2:254 / fd00:ec2::254 AWS metadata
//!      aliases), unspecified (::).
//!   4. IPv4-mapped IPv6 (`::ffff:169.254.169.254`,
//!      `::ffff:7f00:1`, `::ffff:a00:1`) → recurse through the IPv4
//!      classifier so we don't have to duplicate the deny logic.
//!   5. Decimal-encoded IPv4 (`http://3232235521/` →
//!      192.168.0.1) and hex-encoded (`http://0xC0A80001/`) — both
//!      canonicalize via `parseInt(host, 0)` and re-check.
//!   6. DNS aliases: `localhost`, `localhost.` (trailing dot),
//!      `metadata.google.internal`, `metadata.google.internal.`,
//!      bare `metadata`. The trailing-dot variant DNS-resolves the
//!      same as the bare form — Chrome strips the dot before lookup,
//!      so the deny check has to match it explicitly.
//!
//! Surface: a single `sanitize(allocator, url, allowlist)` function
//! returning `SanitizeResult`. The `extension_navigate` tool calls it
//! FIRST, before any hub dispatch. On reject, the tool surfaces the
//! `reason` code verbatim in its ToolResult error_msg so operators
//! debugging a blocked navigation get an actionable diagnosis.

const std = @import("std");

/// Machine-readable rejection reasons. Lands in the tool's error_msg
/// surface so an operator (or the agent itself, scanning for a known
/// reason) can route the rejection accordingly.
pub const RejectionReason = enum {
    invalid_url,
    scheme_blocked,
    loopback_blocked,
    link_local_blocked,
    private_ip_blocked,
    metadata_endpoint_blocked,
    unspecified_address_blocked,
    reserved_address_blocked,

    pub fn toString(self: RejectionReason) []const u8 {
        return switch (self) {
            .invalid_url => "invalid_url",
            .scheme_blocked => "scheme_blocked",
            .loopback_blocked => "loopback_blocked",
            .link_local_blocked => "link_local_blocked",
            .private_ip_blocked => "private_ip_blocked",
            .metadata_endpoint_blocked => "metadata_endpoint_blocked",
            .unspecified_address_blocked => "unspecified_address_blocked",
            .reserved_address_blocked => "reserved_address_blocked",
        };
    }
};

pub const SanitizeResult = union(enum) {
    ok: void,
    reject: struct {
        reason: RejectionReason,
        /// Short human-readable detail for the tool's error_msg. Borrows
        /// from a static string table; no allocation.
        detail: []const u8,
    },
};

/// Validate a URL before handing it to the `extension_navigate` tool.
///
/// `allowlist` (operator-controlled, comes from
/// `GatewayConfig.extension_browser_allowlist`) lets a hostname bypass
/// the deny checks. Empty allowlist means default-deny applies to all
/// non-public hosts. Comparison is case-insensitive on the bare
/// hostname (trailing dot stripped, `[...]` brackets stripped for IPv6).
pub fn sanitize(url: []const u8, allowlist: []const []const u8) SanitizeResult {
    // 1. Scheme check. Mirrors the existing inline check in
    //    `extension_navigate.execute` but centralizes the rejection
    //    code so the tool surface can scan for `scheme_blocked`.
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return .{ .reject = .{
            .reason = .scheme_blocked,
            .detail = "scheme not allowed; only http:// and https:// are accepted",
        } };
    }

    // 2. Extract the host portion. We tolerate optional :port and
    //    optional path. The URI structure after the scheme is
    //    `//host[:port]/path?query#fragment`.
    const after_scheme_idx: usize = if (std.mem.startsWith(u8, url, "https://")) 8 else 7;
    if (after_scheme_idx >= url.len) {
        return .{ .reject = .{ .reason = .invalid_url, .detail = "url missing host component" } };
    }
    const rest = url[after_scheme_idx..];

    // Find the end of the host: '/', '?', '#', or end-of-string.
    var host_end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            host_end = i;
            break;
        }
    }
    var host_with_port = rest[0..host_end];

    // Strip @userinfo if present.
    if (std.mem.indexOfScalar(u8, host_with_port, '@')) |at_idx| {
        host_with_port = host_with_port[at_idx + 1 ..];
    }

    if (host_with_port.len == 0) {
        return .{ .reject = .{ .reason = .invalid_url, .detail = "url has empty host" } };
    }

    // Split off port. IPv6 literals are `[...]:port` — the bracket
    // wrapper protects the colons inside the address.
    var bare_host: []const u8 = undefined;
    if (host_with_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_with_port, ']') orelse {
            return .{ .reject = .{ .reason = .invalid_url, .detail = "ipv6 literal missing ']'" } };
        };
        bare_host = host_with_port[1..close];
    } else {
        const colon_idx = std.mem.indexOfScalar(u8, host_with_port, ':');
        bare_host = if (colon_idx) |i| host_with_port[0..i] else host_with_port;
    }

    if (bare_host.len == 0) {
        return .{ .reject = .{ .reason = .invalid_url, .detail = "empty host" } };
    }

    // 3. Lowercase + strip trailing dot. Both happen at the DNS layer;
    //    if we don't match here, an attacker bypasses with `LocalHost.`
    //    or similar.
    var host_buf: [256]u8 = undefined;
    if (bare_host.len > host_buf.len) {
        return .{ .reject = .{ .reason = .invalid_url, .detail = "hostname too long" } };
    }
    var host_len = bare_host.len;
    for (bare_host, 0..) |c, i| {
        host_buf[i] = std.ascii.toLower(c);
    }
    // Strip a single trailing dot.
    if (host_len > 0 and host_buf[host_len - 1] == '.') {
        host_len -= 1;
    }
    const normalized_host = host_buf[0..host_len];

    if (normalized_host.len == 0) {
        return .{ .reject = .{ .reason = .invalid_url, .detail = "empty host after normalization" } };
    }

    // 4. Operator allowlist — if the hostname matches (case-insensitive
    //    after normalization), bypass the deny check. Lets an operator
    //    permit `gitea.lan` or `192.168.1.10` for trusted deployments.
    for (allowlist) |allowed| {
        if (asciiEqlIgnoreCase(allowed, normalized_host)) return .{ .ok = {} };
        // Also tolerate operator entries that include the trailing dot
        // or IPv6 brackets; normalize the comparison from the operator
        // side. HI-08: stripIPv6Brackets makes `["[::1]"]` actually
        // match the bracket-stripped `::1` host produced by parseHost.
        const trimmed = stripIPv6Brackets(trimTrailingDot(allowed));
        if (asciiEqlIgnoreCase(trimmed, normalized_host)) return .{ .ok = {} };
    }

    // 5. DNS-alias deny. These hostnames don't parse as IPs but DNS-
    //    resolve to loopback / metadata. Listed BEFORE the IP parsing
    //    so the rejection reason is descriptive ("metadata_endpoint" vs
    //    "loopback").
    if (asciiEqlIgnoreCase(normalized_host, "localhost") or
        endsWithIgnoreCase(normalized_host, ".localhost"))
    {
        return .{ .reject = .{
            .reason = .loopback_blocked,
            .detail = "loopback hostname blocked — add to extension_browser_allowlist to permit",
        } };
    }
    if (asciiEqlIgnoreCase(normalized_host, "metadata") or
        asciiEqlIgnoreCase(normalized_host, "metadata.google.internal"))
    {
        return .{ .reject = .{
            .reason = .metadata_endpoint_blocked,
            .detail = "cloud metadata endpoint blocked",
        } };
    }

    // 6. Numeric-IP parsing. Try IPv6 (only if the original host was
    //    bracketed), then IPv4, then decimal/hex-encoded IPv4.
    if (host_with_port.len > 0 and host_with_port[0] == '[') {
        // IPv6 literal. parseIp6 handles the canonical forms including
        // IPv4-mapped addresses (`::ffff:X.X.X.X`).
        if (parseIPv6(normalized_host)) |v6| {
            return classifyIPv6(v6);
        } else |_| {
            return .{ .reject = .{ .reason = .invalid_url, .detail = "malformed IPv6 literal" } };
        }
    }

    // IPv4 dotted-decimal.
    if (parseIPv4Dotted(normalized_host)) |v4| {
        return classifyIPv4(v4);
    } else |_| {}

    // Decimal-encoded IPv4 (e.g. `3232235521` = 192.168.0.1) or
    // hex-encoded (`0xC0A80001`). std.fmt.parseInt supports `0x` /
    // `0o` / `0b` prefixes when base=0.
    if (allDigitsOrHex(normalized_host)) {
        const v: u32 = std.fmt.parseInt(u32, normalized_host, 0) catch {
            // Not a valid u32; let the normal hostname path apply.
            return .{ .ok = {} };
        };
        const v4: [4]u8 = .{
            @intCast((v >> 24) & 0xFF),
            @intCast((v >> 16) & 0xFF),
            @intCast((v >> 8) & 0xFF),
            @intCast(v & 0xFF),
        };
        return classifyIPv4(v4);
    }

    // Otherwise: a normal DNS hostname. We don't resolve it ourselves
    // (that would be a network call from the validator); a malicious
    // hostname that DNS-resolves to a private IP would still be
    // dispatched. That's a known v2 hardening — DNS rebinding defense
    // would require either pre-resolving + pinning or a `Host:` header
    // override, neither of which is in v1 scope. The symmetric server-
    // side orchestrator-lane `urlguard.go` defense also doesn't pre-
    // resolve (it relies on the pod NetworkPolicy as the enforced backstop);
    // the gateway-side equivalent would be intercepting in the extension's
    // `cmdNavigate` — out of scope for this CRIT 1 fix.
    return .{ .ok = {} };
}

// ── IP classification ────────────────────────────────────────────────

/// Classify an IPv4 address. Returns `.ok` if the address is in the
/// "unicast" range (the open internet) or rejects with a specific
/// reason. See `docs/ssrf-blocklist.md` §3–6 for the deny-class spec.
fn classifyIPv4(v4: [4]u8) SanitizeResult {
    // 0.0.0.0/8 - "this network" / unspecified
    if (v4[0] == 0) {
        return .{ .reject = .{
            .reason = .unspecified_address_blocked,
            .detail = "unspecified IPv4 address routes to local interfaces",
        } };
    }
    // 127.0.0.0/8 - loopback
    if (v4[0] == 127) {
        return .{ .reject = .{
            .reason = .loopback_blocked,
            .detail = "loopback IPv4 blocked — add to extension_browser_allowlist to permit",
        } };
    }
    // 10.0.0.0/8 - RFC1918
    if (v4[0] == 10) {
        return .{ .reject = .{
            .reason = .private_ip_blocked,
            .detail = "RFC1918 private IPv4 blocked",
        } };
    }
    // 172.16.0.0/12 - RFC1918
    if (v4[0] == 172 and v4[1] >= 16 and v4[1] <= 31) {
        return .{ .reject = .{
            .reason = .private_ip_blocked,
            .detail = "RFC1918 private IPv4 blocked",
        } };
    }
    // 192.168.0.0/16 - RFC1918
    if (v4[0] == 192 and v4[1] == 168) {
        return .{ .reject = .{
            .reason = .private_ip_blocked,
            .detail = "RFC1918 private IPv4 blocked",
        } };
    }
    // 169.254.0.0/16 - link-local. Special-case 169.254.169.254 as
    // metadata for a more actionable error.
    if (v4[0] == 169 and v4[1] == 254) {
        if (v4[2] == 169 and v4[3] == 254) {
            return .{ .reject = .{
                .reason = .metadata_endpoint_blocked,
                .detail = "cloud metadata endpoint 169.254.169.254 blocked",
            } };
        }
        return .{ .reject = .{
            .reason = .link_local_blocked,
            .detail = "link-local IPv4 (169.254.0.0/16) blocked",
        } };
    }
    // 100.64.0.0/10 - carrier-grade NAT (RFC6598)
    if (v4[0] == 100 and v4[1] >= 64 and v4[1] <= 127) {
        return .{ .reject = .{
            .reason = .private_ip_blocked,
            .detail = "carrier-grade NAT IPv4 (RFC6598) blocked",
        } };
    }
    // 224.0.0.0/4 - multicast
    if (v4[0] >= 224 and v4[0] <= 239) {
        return .{ .reject = .{
            .reason = .reserved_address_blocked,
            .detail = "multicast IPv4 blocked",
        } };
    }
    // 240.0.0.0/4 - reserved
    if (v4[0] >= 240) {
        return .{ .reject = .{
            .reason = .reserved_address_blocked,
            .detail = "reserved IPv4 blocked",
        } };
    }
    return .{ .ok = {} };
}

/// Classify an IPv6 address. IPv4-mapped addresses recurse through the
/// IPv4 classifier. Mirrors the JS `classifyIPv6`.
fn classifyIPv6(v6: [16]u8) SanitizeResult {
    // IPv4-mapped: ::ffff:X.X.X.X = 00:00:00:00:00:00:00:00:00:00:ff:ff:X:X:X:X
    const is_ipv4_mapped = blk: {
        for (v6[0..10]) |b| if (b != 0) break :blk false;
        break :blk v6[10] == 0xFF and v6[11] == 0xFF;
    };
    if (is_ipv4_mapped) {
        return classifyIPv4(.{ v6[12], v6[13], v6[14], v6[15] });
    }

    // Unspecified :: (all zeros)
    var all_zero = true;
    for (v6) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    if (all_zero) {
        return .{ .reject = .{
            .reason = .unspecified_address_blocked,
            .detail = "IPv6 unspecified :: routes to local interfaces",
        } };
    }

    // Loopback ::1
    var is_loopback = true;
    for (v6[0..15]) |b| if (b != 0) {
        is_loopback = false;
        break;
    };
    if (is_loopback and v6[15] == 1) {
        return .{ .reject = .{
            .reason = .loopback_blocked,
            .detail = "IPv6 loopback ::1 blocked — add to extension_browser_allowlist to permit",
        } };
    }

    // Link-local fe80::/10 — high 10 bits = 1111111010 = 0xFE80..0xFEBF
    if (v6[0] == 0xFE and (v6[1] & 0xC0) == 0x80) {
        return .{ .reject = .{
            .reason = .link_local_blocked,
            .detail = "IPv6 link-local (fe80::/10) blocked",
        } };
    }

    // Unique-local fc00::/7 — high 7 bits = 1111110 = 0xFC..0xFD.
    // This covers AWS IPv6 metadata aliases like fd00::ec2:254.
    if ((v6[0] & 0xFE) == 0xFC) {
        return .{ .reject = .{
            .reason = .private_ip_blocked,
            .detail = "IPv6 unique-local (fc00::/7) blocked (includes AWS IPv6 metadata fd00::ec2:254)",
        } };
    }

    // Multicast ff00::/8
    if (v6[0] == 0xFF) {
        return .{ .reject = .{
            .reason = .reserved_address_blocked,
            .detail = "IPv6 multicast blocked",
        } };
    }

    return .{ .ok = {} };
}

// ── Parsing helpers ──────────────────────────────────────────────────

/// Parse a dotted-decimal IPv4 string (e.g. "192.168.1.1") into 4 octets.
/// Returns error.InvalidIPv4 on any malformed input (including
/// leading-zero octets, since those can be interpreted as octal by
/// some legacy clients — we reject them here so the deny check applies
/// to the canonical form).
fn parseIPv4Dotted(s: []const u8) ![4]u8 {
    var octets: [4]u8 = undefined;
    var idx: usize = 0;
    var part_start: usize = 0;
    var dot_count: usize = 0;

    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '.') {
            if (i == part_start) return error.InvalidIPv4;
            if (dot_count >= 4) return error.InvalidIPv4;
            const part = s[part_start..i];
            if (part.len > 3) return error.InvalidIPv4;
            const n = std.fmt.parseInt(u16, part, 10) catch return error.InvalidIPv4;
            if (n > 255) return error.InvalidIPv4;
            octets[idx] = @intCast(n);
            idx += 1;
            dot_count += 1;
            part_start = i + 1;
        } else if (!std.ascii.isDigit(s[i])) {
            return error.InvalidIPv4;
        }
    }
    if (idx != 4) return error.InvalidIPv4;
    return octets;
}

/// Parse an IPv6 literal (the inner bytes between `[` and `]`, with
/// the brackets already stripped). Handles `::`, `::ffff:X.X.X.X`,
/// and the canonical 8-group form.
fn parseIPv6(s: []const u8) ![16]u8 {
    // Defer to std.net.Address.parseIp6 which handles all the canonical
    // forms (including ::ffff:X.X.X.X). We extract the raw 16 bytes
    // from the resulting sockaddr_in6.
    const addr = try std.net.Ip6Address.parse(s, 0);
    return @as([16]u8, @bitCast(addr.sa.addr));
}

fn allDigitsOrHex(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        if (s.len == 2) return false;
        for (s[2..]) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    const tail = haystack[haystack.len - suffix.len ..];
    return asciiEqlIgnoreCase(tail, suffix);
}

fn trimTrailingDot(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '.') return s[0 .. s.len - 1];
    return s;
}

/// HI-08 (v1.14.22, 2026-05-25) — strip enclosing brackets from an
/// IPv6 literal in operator allowlist entries. The URL host parser
/// already canonicalises `[::1]` → `::1` (bracket-free), so an
/// operator who writes the natural bracketed form in their
/// `extension_browser_allowlist` list (e.g. `["[::1]"]`) gets a
/// mismatch and the allowlist silently fails. Mirror the
/// `trimTrailingDot` pattern.
fn stripIPv6Brackets(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') {
        return s[1 .. s.len - 1];
    }
    return s;
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

fn expectReject(r: SanitizeResult, expected: RejectionReason) !void {
    switch (r) {
        .ok => return error.TestUnexpectedOk,
        .reject => |rj| try t.expectEqual(expected, rj.reason),
    }
}

fn expectOk(r: SanitizeResult) !void {
    switch (r) {
        .ok => {},
        .reject => |rj| {
            std.debug.print("expected ok, got reject {s}: {s}\n", .{ rj.reason.toString(), rj.detail });
            return error.TestUnexpectedReject;
        },
    }
}

test "scheme: file:// is rejected" {
    try expectReject(sanitize("file:///etc/passwd", &.{}), .scheme_blocked);
}

test "scheme: javascript: is rejected" {
    try expectReject(sanitize("javascript:alert(1)", &.{}), .scheme_blocked);
}

test "scheme: chrome:// is rejected" {
    try expectReject(sanitize("chrome://settings", &.{}), .scheme_blocked);
}

test "scheme: data: is rejected" {
    try expectReject(sanitize("data:text/html,<script>...</script>", &.{}), .scheme_blocked);
}

test "scheme: http public is ok" {
    try expectOk(sanitize("http://example.com/foo", &.{}));
}

test "scheme: https public is ok" {
    try expectOk(sanitize("https://example.com/", &.{}));
}

test "IPv4: 169.254.169.254 (metadata) is rejected with metadata_endpoint" {
    try expectReject(sanitize("http://169.254.169.254/latest/meta-data/", &.{}), .metadata_endpoint_blocked);
}

test "IPv4: 169.254.0.1 (link-local non-metadata) is link_local_blocked" {
    try expectReject(sanitize("http://169.254.0.1/", &.{}), .link_local_blocked);
}

test "IPv4: 127.0.0.1 loopback is rejected" {
    try expectReject(sanitize("http://127.0.0.1/", &.{}), .loopback_blocked);
}

test "IPv4: 127.7.7.7 (anywhere in 127/8) is rejected" {
    try expectReject(sanitize("http://127.7.7.7/", &.{}), .loopback_blocked);
}

test "IPv4: 10.0.0.1 RFC1918 is rejected" {
    try expectReject(sanitize("http://10.0.0.1/", &.{}), .private_ip_blocked);
}

test "IPv4: 172.20.5.5 RFC1918 is rejected" {
    try expectReject(sanitize("http://172.20.5.5/", &.{}), .private_ip_blocked);
}

test "IPv4: 172.15.0.1 OUTSIDE RFC1918 is ok" {
    // 172.16/12 is 172.16.0.0 - 172.31.255.255 — 172.15.x is public.
    try expectOk(sanitize("http://172.15.0.1/", &.{}));
}

test "IPv4: 172.32.0.1 OUTSIDE RFC1918 is ok" {
    try expectOk(sanitize("http://172.32.0.1/", &.{}));
}

test "IPv4: 192.168.1.1 RFC1918 is rejected" {
    try expectReject(sanitize("http://192.168.1.1/", &.{}), .private_ip_blocked);
}

test "IPv4: 0.0.0.0 unspecified is rejected" {
    try expectReject(sanitize("http://0.0.0.0/", &.{}), .unspecified_address_blocked);
}

test "IPv4: bare 0 (decimal-encoded 0.0.0.0) is rejected" {
    try expectReject(sanitize("http://0/", &.{}), .unspecified_address_blocked);
}

test "IPv4: 100.64.0.1 carrier-grade NAT is rejected" {
    try expectReject(sanitize("http://100.64.0.1/", &.{}), .private_ip_blocked);
}

test "DNS alias: localhost is rejected" {
    try expectReject(sanitize("http://localhost:8080/admin", &.{}), .loopback_blocked);
}

test "DNS alias: localhost. (trailing dot) is rejected" {
    try expectReject(sanitize("http://localhost./admin", &.{}), .loopback_blocked);
}

test "DNS alias: foo.localhost is rejected" {
    try expectReject(sanitize("http://foo.localhost/", &.{}), .loopback_blocked);
}

test "DNS alias: metadata is rejected" {
    try expectReject(sanitize("http://metadata/computeMetadata/v1/", &.{}), .metadata_endpoint_blocked);
}

test "DNS alias: metadata.google.internal is rejected" {
    try expectReject(sanitize("http://metadata.google.internal/computeMetadata/v1/", &.{}), .metadata_endpoint_blocked);
}

test "DNS alias: metadata.google.internal. (trailing dot) is rejected" {
    try expectReject(sanitize("http://metadata.google.internal./computeMetadata/v1/", &.{}), .metadata_endpoint_blocked);
}

test "IPv6: ::1 loopback is rejected" {
    try expectReject(sanitize("http://[::1]/", &.{}), .loopback_blocked);
}

test "IPv6: fe80::1 link-local is rejected" {
    try expectReject(sanitize("http://[fe80::1]/", &.{}), .link_local_blocked);
}

test "IPv6: fd00::ec2:254 (AWS IPv6 metadata alias) is rejected" {
    try expectReject(sanitize("http://[fd00::ec2:254]/", &.{}), .private_ip_blocked);
}

test "IPv6: fd00:ec2::254 is rejected" {
    try expectReject(sanitize("http://[fd00:ec2::254]/", &.{}), .private_ip_blocked);
}

test "IPv6: :: unspecified is rejected" {
    try expectReject(sanitize("http://[::]/", &.{}), .unspecified_address_blocked);
}

test "IPv6: ::ffff:169.254.169.254 (IPv4-mapped metadata) is rejected" {
    try expectReject(sanitize("http://[::ffff:169.254.169.254]/", &.{}), .metadata_endpoint_blocked);
}

test "IPv6: ::ffff:7f00:1 (IPv4-mapped loopback) is rejected" {
    try expectReject(sanitize("http://[::ffff:7f00:1]/", &.{}), .loopback_blocked);
}

test "IPv6: ::ffff:a00:1 (IPv4-mapped RFC1918) is rejected" {
    try expectReject(sanitize("http://[::ffff:a00:1]/", &.{}), .private_ip_blocked);
}

test "IPv6: 2001:db8::1 (documentation prefix) is ok by deny-list" {
    // Documentation prefix (RFC3849) isn't in our deny list — it's not
    // routable in practice but a v1 sanitizer doesn't try to catch it.
    try expectOk(sanitize("http://[2001:db8::1]/", &.{}));
}

test "decimal-encoded: 3232235521 → 192.168.0.1 is rejected" {
    try expectReject(sanitize("http://3232235521/", &.{}), .private_ip_blocked);
}

test "decimal-encoded: 2130706433 → 127.0.0.1 is rejected" {
    try expectReject(sanitize("http://2130706433/", &.{}), .loopback_blocked);
}

test "hex-encoded: 0xC0A80001 → 192.168.0.1 is rejected" {
    try expectReject(sanitize("http://0xC0A80001/", &.{}), .private_ip_blocked);
}

test "hex-encoded: 0x7F000001 → 127.0.0.1 is rejected" {
    try expectReject(sanitize("http://0x7F000001/", &.{}), .loopback_blocked);
}

test "allowlist: localhost in allowlist is accepted" {
    try expectOk(sanitize("http://localhost:8080/admin", &.{"localhost"}));
}

test "allowlist: 127.0.0.1 in allowlist is accepted" {
    try expectOk(sanitize("http://127.0.0.1/", &.{"127.0.0.1"}));
}

test "allowlist: case-insensitive match" {
    try expectOk(sanitize("http://LocalHost/", &.{"localhost"}));
}

test "allowlist: operator trailing dot tolerated" {
    try expectOk(sanitize("http://internal.lan/", &.{"internal.lan."}));
}

test "allowlist: operator bracketed IPv6 literal tolerated (HI-08)" {
    // The URL host parser canonicalises `[::1]` → `::1` (bracket-free).
    // An operator who writes the natural bracketed form must still match.
    // (Use https — the sanitizer's scheme allowlist is http/https only,
    // so we exercise the allowlist comparison path through a permitted
    // scheme. wss is rejected by scheme_blocked before reaching the host
    // comparison, which would mask the HI-08 fix we're testing.)
    try expectOk(sanitize("https://[::1]:8080/x", &.{"[::1]"}));
    // The bare form also works (back-compat).
    try expectOk(sanitize("https://[::1]:8080/x", &.{"::1"}));
    // Bracket-form on a public IPv6 literal also works.
    try expectOk(sanitize("https://[2001:db8::1]/x", &.{"[2001:db8::1]"}));
}

test "allowlist does NOT bypass scheme check (file:// still rejected)" {
    try expectReject(sanitize("file:///etc/passwd", &.{"any.host"}), .scheme_blocked);
}

test "malformed: ipv6 missing closing bracket" {
    try expectReject(sanitize("http://[::1/foo", &.{}), .invalid_url);
}

test "malformed: empty host" {
    try expectReject(sanitize("http:///path", &.{}), .invalid_url);
}

test "malformed: just the scheme" {
    try expectReject(sanitize("http://", &.{}), .invalid_url);
}

test "url with port: 192.168.1.1:8080 is rejected" {
    try expectReject(sanitize("http://192.168.1.1:8080/", &.{}), .private_ip_blocked);
}

test "url with userinfo: user:pass@127.0.0.1 is rejected" {
    try expectReject(sanitize("http://user:pass@127.0.0.1/", &.{}), .loopback_blocked);
}

test "public host with trailing dot is ok" {
    try expectOk(sanitize("http://example.com./foo", &.{}));
}
