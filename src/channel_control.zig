//! Channel control-plane descriptors + pure logic for the ZAKI V2
//! user-facing channel activation contract (S7).
//!
//! This module owns the *stable, user-safe* shape of the per-user
//! channel control plane the ZAKI UI binds to. It is intentionally free
//! of any DB / HTTP / network dependency so the contract logic stays
//! unit-testable without Postgres or a live gateway. `src/gateway.zig`
//! does the JSON field extraction + vault/channel-state IO and delegates
//! descriptor lookup, validation, status resolution, and JSON
//! serialization here.
//!
//! Surfaced channels (V1 launch set): slack, discord, email, whatsapp.
//! Telegram keeps connect/disconnect on the dedicated
//! `channels/telegram/*` routes while sharing the generic read-only test
//! action. This preserves the shipped webhook flow while allowing bounded
//! provider liveness checks.
//!
//! Every other adapter in the catalog (signal, matrix, irc, line, lark,
//! onebot, qq, nostr, maixcam, teams, imessage, webhook, cli) is
//! deliberately NOT surfaced — `fromKey` returns null so the gateway
//! answers `404 channel_not_supported` and hidden channels stay hidden.
//!
//! Security invariants enforced here:
//!   - Secret *values* are never serialized. The control-plane JSON only
//!     ever reports a `present: bool` per vault key (a "secret ref").
//!   - Only non-secret config (host/port/account ids) is echoed back.
//!   - The surfaced channel set is a fixed allowlist; unknown keys 404.

const std = @import("std");
const telegram_token = @import("telegram_token.zig");

/// The user-surfaced channel set. Anything not in this enum is hidden
/// from the control plane on purpose (see module doc).
pub const Channel = enum {
    slack,
    discord,
    email,
    whatsapp,
    telegram,

    pub fn key(self: Channel) []const u8 {
        return switch (self) {
            .slack => "slack",
            .discord => "discord",
            .email => "email",
            .whatsapp => "whatsapp",
            .telegram => "telegram",
        };
    }

    pub fn label(self: Channel) []const u8 {
        return switch (self) {
            .slack => "Slack",
            .discord => "Discord",
            .email => "Email",
            .whatsapp => "WhatsApp",
            .telegram => "Telegram",
        };
    }

    /// True when connect/test/disconnect flow through the generic
    /// control-plane handler. Telegram is false: it keeps its dedicated
    /// `channels/telegram/connect|disconnect` routes so the shipped flow
    /// is never destabilised.
    pub fn userManaged(self: Channel) bool {
        return self != .telegram;
    }
};

/// The channels the aggregate `GET /channels` listing walks, in display
/// order. Telegram is last and read-only.
pub const listed_channels = [_]Channel{ .slack, .discord, .email, .whatsapp, .telegram };

/// Map a URL path segment to a surfaced channel. Returns null for hidden
/// / unknown channels so the gateway can answer 404 without leaking the
/// existence of internal adapters.
pub fn fromKey(k: []const u8) ?Channel {
    inline for (@typeInfo(Channel).@"enum".fields) |field| {
        const ch: Channel = @enumFromInt(field.value);
        if (std.mem.eql(u8, k, ch.key())) return ch;
    }
    return null;
}

// ── Descriptors: which vault secret refs + non-secret config each
//    channel needs ───────────────────────────────────────────────────

/// A vault-backed secret the channel needs. The control plane stores the
/// *value* in the encrypted secret vault (`zaki_state.putSecret`) and
/// only ever reports `present` back to the client — never the value.
pub const SecretRef = struct {
    /// Canonical vault key (also the disconnect delete target).
    key: []const u8,
    /// Human label for the UI form field.
    label: []const u8,
    /// Whether the channel counts as "connected" without it.
    required: bool,
};

/// A non-secret config field. Stored in `channel_state.channels` JSON and
/// safe to echo back for display (host names, account ids, ports).
pub const ConfigField = struct {
    key: []const u8,
    label: []const u8,
    required: bool,
    /// Validate as a decimal port (1..65535) on connect.
    is_port: bool = false,
    /// Validate as a digits-only id on connect.
    is_digits: bool = false,
};

pub const Descriptor = struct {
    channel: Channel,
    secrets: []const SecretRef,
    config_fields: []const ConfigField,

    /// Count of required secret refs — the denominator for the
    /// connected/partial status calculation.
    pub fn requiredSecretCount(self: Descriptor) usize {
        var n: usize = 0;
        for (self.secrets) |s| {
            if (s.required) n += 1;
        }
        return n;
    }
};

const slack_secrets = [_]SecretRef{
    .{ .key = "slack_bot_token", .label = "Bot token (xoxb-…)", .required = true },
    .{ .key = "slack_signing_secret", .label = "Signing secret", .required = true },
    .{ .key = "slack_app_token", .label = "App-level token (xapp-…, optional)", .required = false },
};
const slack_config = [_]ConfigField{
    .{ .key = "team_id", .label = "Workspace / team ID", .required = false },
};

const discord_secrets = [_]SecretRef{
    .{ .key = "discord_bot_token", .label = "Bot token", .required = true },
};
const discord_config = [_]ConfigField{
    .{ .key = "guild_id", .label = "Guild ID", .required = false, .is_digits = true },
};

const email_secrets = [_]SecretRef{
    .{ .key = "email_imap_password", .label = "IMAP password", .required = true },
    .{ .key = "email_smtp_password", .label = "SMTP password (optional, defaults to IMAP)", .required = false },
};
const email_config = [_]ConfigField{
    .{ .key = "imap_host", .label = "IMAP host", .required = true },
    .{ .key = "imap_port", .label = "IMAP port", .required = false, .is_port = true },
    .{ .key = "smtp_host", .label = "SMTP host", .required = true },
    .{ .key = "smtp_port", .label = "SMTP port", .required = false, .is_port = true },
    .{ .key = "username", .label = "Mailbox username", .required = true },
    .{ .key = "from_address", .label = "From address", .required = false },
};

const whatsapp_secrets = [_]SecretRef{
    .{ .key = "whatsapp_access_token", .label = "Access token", .required = true },
    .{ .key = "whatsapp_verify_token", .label = "Webhook verify token", .required = true },
    .{ .key = "whatsapp_app_secret", .label = "App secret (optional, webhook signature)", .required = false },
};
const whatsapp_config = [_]ConfigField{
    .{ .key = "phone_number_id", .label = "Phone number ID", .required = true, .is_digits = true },
    .{ .key = "business_account_id", .label = "Business account ID", .required = false, .is_digits = true },
};

const telegram_secrets = [_]SecretRef{
    .{ .key = "telegram_bot_token", .label = "Bot token", .required = true },
};
const telegram_config = [_]ConfigField{};

pub fn descriptor(ch: Channel) Descriptor {
    return switch (ch) {
        .slack => .{ .channel = .slack, .secrets = &slack_secrets, .config_fields = &slack_config },
        .discord => .{ .channel = .discord, .secrets = &discord_secrets, .config_fields = &discord_config },
        .email => .{ .channel = .email, .secrets = &email_secrets, .config_fields = &email_config },
        .whatsapp => .{ .channel = .whatsapp, .secrets = &whatsapp_secrets, .config_fields = &whatsapp_config },
        .telegram => .{ .channel = .telegram, .secrets = &telegram_secrets, .config_fields = &telegram_config },
    };
}

// ── Route parsing ─────────────────────────────────────────────────────

pub const Action = enum {
    connect,
    @"test",
    disconnect,

    pub fn fromSlice(s: []const u8) ?Action {
        if (std.mem.eql(u8, s, "connect")) return .connect;
        if (std.mem.eql(u8, s, "test")) return .@"test";
        if (std.mem.eql(u8, s, "disconnect")) return .disconnect;
        return null;
    }
};

/// Telegram's shipped connect/disconnect flow performs webhook-specific
/// work on dedicated routes. Its read-only liveness check is safe to share
/// with the generic control plane.
pub fn usesDedicatedMutationRoute(ch: Channel, action: Action) bool {
    return ch == .telegram and action != .@"test";
}

pub const Route = union(enum) {
    /// GET /channels — aggregate listing.
    list,
    /// GET /channels/{channel} — single channel status.
    item: Channel,
    /// POST /channels/{channel}/{action}.
    mutate: struct { channel: Channel, action: Action },
    /// Path is under `channels/` but the channel key is hidden/unknown,
    /// or the action is unrecognized. The gateway answers 404.
    unsupported,
};

/// Parse a user-scoped subpath (already stripped of the
/// `/api/v1/users/{id}/` prefix) into a channel-control Route, or null if
/// the subpath is not part of the channel control plane at all (so the
/// gateway keeps matching other routes).
///
/// NOTE: callers run this AFTER the dedicated `channels/telegram/connect`,
/// `channels/telegram/disconnect`, and `channels/{ch}/bindings` matchers,
/// so those never reach here.
pub fn parseRoute(subpath: []const u8) ?Route {
    if (std.mem.eql(u8, subpath, "channels")) return .list;
    if (!std.mem.startsWith(u8, subpath, "channels/")) return null;

    const rest = subpath["channels/".len..];
    if (rest.len == 0) return .unsupported;

    // bindings routes are handled upstream; never claim them here.
    var it = std.mem.splitScalar(u8, rest, '/');
    const ch_key = it.next() orelse return .unsupported;
    const maybe_action = it.next();
    // Reject anything deeper than channels/{ch}/{action}.
    if (it.next() != null) return null;

    const ch = fromKey(ch_key) orelse return .unsupported;

    if (maybe_action) |action_str| {
        // Guard against re-claiming the upstream bindings collection.
        if (std.mem.eql(u8, action_str, "bindings")) return null;
        const action = Action.fromSlice(action_str) orelse return .unsupported;
        return .{ .mutate = .{ .channel = ch, .action = action } };
    }
    return .{ .item = ch };
}

// ── Validation ────────────────────────────────────────────────────────

const MAX_SECRET_LEN: usize = 8192;
const MAX_CONFIG_LEN: usize = 2048;

/// A vault secret value must be non-empty, free of whitespace/control
/// characters (these are tokens, not free text), and within a sane bound.
pub fn isCleanToken(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_SECRET_LEN) return false;
    for (value) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    return true;
}

pub fn isDigits(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

pub fn isValidPort(value: []const u8) bool {
    if (!isDigits(value)) return false;
    const port = std.fmt.parseInt(u32, value, 10) catch return false;
    return port >= 1 and port <= 65535;
}

/// Non-secret config values are displayed back to the user, so they must
/// be single-line and bounded, but may contain spaces (e.g. a display
/// name is not expected here, but be lenient on punctuation).
pub fn isCleanConfigValue(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_CONFIG_LEN) return false;
    for (value) |ch| {
        // Reject control chars (newlines, etc.) that could break the
        // JSON line / log lines; printable ASCII + UTF-8 bytes are fine.
        if (ch == '\n' or ch == '\r' or ch == 0x00) return false;
    }
    return true;
}

/// Per-channel, per-key secret format check. Returns false when the value
/// is structurally implausible for that credential — lets the gateway
/// answer `400 invalid_secret` instead of silently storing garbage.
pub fn validateSecretValue(secret_key: []const u8, value: []const u8) bool {
    if (!isCleanToken(value)) return false;
    if (std.mem.eql(u8, secret_key, "slack_bot_token")) {
        return std.mem.startsWith(u8, value, "xoxb-") and value.len > 10;
    }
    if (std.mem.eql(u8, secret_key, "slack_app_token")) {
        return std.mem.startsWith(u8, value, "xapp-") and value.len > 10;
    }
    if (std.mem.eql(u8, secret_key, "telegram_bot_token")) {
        return telegram_token.is_bot_token_shape(value);
    }
    if (std.mem.eql(u8, secret_key, "discord_bot_token")) {
        return value.len >= 24;
    }
    if (std.mem.eql(u8, secret_key, "whatsapp_access_token")) {
        return value.len >= 16;
    }
    return true;
}

/// Validate a config field value against its declared format.
pub fn validateConfigValue(field: ConfigField, value: []const u8) bool {
    if (!isCleanConfigValue(value)) return false;
    if (field.is_port) return isValidPort(value);
    if (field.is_digits) return isDigits(value);
    return true;
}

// ── Status resolution ─────────────────────────────────────────────────

pub const Status = enum {
    /// Build flag off — adapter not compiled in.
    disabled_in_build,
    /// All required secret refs present for this user.
    connected,
    /// Some but not all required secret refs present (mid-setup or a
    /// rotated/partially-deleted credential).
    partial,
    /// No user credentials, but the operator configured this channel at
    /// the deployment level — usable but not user-self-service.
    operator_managed,
    /// No credentials and no operator config.
    not_connected,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .disabled_in_build => "disabled_in_build",
            .connected => "connected",
            .partial => "partial",
            .operator_managed => "operator_managed",
            .not_connected => "not_connected",
        };
    }
};

pub fn resolveStatus(
    build_enabled: bool,
    operator_configured: bool,
    required_present: usize,
    required_total: usize,
) Status {
    if (!build_enabled) return .disabled_in_build;
    if (required_total > 0 and required_present >= required_total) return .connected;
    if (required_present > 0) return .partial;
    if (operator_configured) return .operator_managed;
    return .not_connected;
}

// ── JSON serialization (the exact shape the UI binds to) ──────────────

pub const SecretRefView = struct {
    key: []const u8,
    label: []const u8,
    required: bool,
    present: bool,
};

pub const ConfigEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const TestResult = struct {
    ok: bool,
    checked_at_s: i64,
    detail: []const u8,
};

pub const Endpoints = struct {
    self: []const u8,
    connect: []const u8,
    @"test": []const u8,
    disconnect: []const u8,
};

pub const ChannelView = struct {
    channel: Channel,
    build_enabled: bool,
    operator_configured: bool,
    user_managed: bool,
    status: Status,
    secret_refs: []const SecretRefView,
    config: []const ConfigEntry,
    last_test: ?TestResult,
    endpoints: Endpoints,
};

fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

/// Serialize one channel's control-plane status. This is the canonical
/// per-channel object the UI binds to; the aggregate listing wraps an
/// array of these under `{"channels":[...]}`.
pub fn writeChannelJson(w: anytype, view: ChannelView) !void {
    try w.writeAll("{\"channel\":\"");
    try jsonEscape(w, view.channel.key());
    try w.writeAll("\",\"label\":\"");
    try jsonEscape(w, view.channel.label());
    try w.writeAll("\",\"build_enabled\":");
    try w.writeAll(if (view.build_enabled) "true" else "false");
    try w.writeAll(",\"operator_configured\":");
    try w.writeAll(if (view.operator_configured) "true" else "false");
    try w.writeAll(",\"user_managed\":");
    try w.writeAll(if (view.user_managed) "true" else "false");
    try w.writeAll(",\"user_connected\":");
    try w.writeAll(if (view.status == .connected) "true" else "false");
    try w.writeAll(",\"status\":\"");
    try jsonEscape(w, view.status.label());
    try w.writeAll("\",\"secret_refs\":[");
    for (view.secret_refs, 0..) |ref, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"key\":\"");
        try jsonEscape(w, ref.key);
        try w.writeAll("\",\"label\":\"");
        try jsonEscape(w, ref.label);
        try w.writeAll("\",\"required\":");
        try w.writeAll(if (ref.required) "true" else "false");
        try w.writeAll(",\"present\":");
        try w.writeAll(if (ref.present) "true" else "false");
        try w.writeByte('}');
    }
    try w.writeAll("],\"config\":{");
    for (view.config, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try jsonEscape(w, entry.key);
        try w.writeAll("\":\"");
        try jsonEscape(w, entry.value);
        try w.writeByte('"');
    }
    try w.writeAll("},\"last_test\":");
    if (view.last_test) |lt| {
        try w.writeAll("{\"ok\":");
        try w.writeAll(if (lt.ok) "true" else "false");
        try w.print(",\"checked_at_s\":{d},\"detail\":\"", .{lt.checked_at_s});
        try jsonEscape(w, lt.detail);
        try w.writeAll("\"}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"endpoints\":{\"self\":\"");
    try jsonEscape(w, view.endpoints.self);
    try w.writeAll("\",\"connect\":\"");
    try jsonEscape(w, view.endpoints.connect);
    try w.writeAll("\",\"test\":\"");
    try jsonEscape(w, view.endpoints.@"test");
    try w.writeAll("\",\"disconnect\":\"");
    try jsonEscape(w, view.endpoints.disconnect);
    try w.writeAll("\"}}");
}

// ── Tests ─────────────────────────────────────────────────────────────

test "fromKey surfaces only the launch set + telegram, hides the rest" {
    try std.testing.expectEqual(Channel.slack, fromKey("slack").?);
    try std.testing.expectEqual(Channel.discord, fromKey("discord").?);
    try std.testing.expectEqual(Channel.email, fromKey("email").?);
    try std.testing.expectEqual(Channel.whatsapp, fromKey("whatsapp").?);
    try std.testing.expectEqual(Channel.telegram, fromKey("telegram").?);
    // Hidden adapters must stay hidden.
    try std.testing.expect(fromKey("signal") == null);
    try std.testing.expect(fromKey("matrix") == null);
    try std.testing.expect(fromKey("irc") == null);
    try std.testing.expect(fromKey("nostr") == null);
    try std.testing.expect(fromKey("teams") == null);
    try std.testing.expect(fromKey("maixcam") == null);
    try std.testing.expect(fromKey("webhook") == null);
    try std.testing.expect(fromKey("cli") == null);
    try std.testing.expect(fromKey("") == null);
    try std.testing.expect(fromKey("SLACK") == null); // case-sensitive
}

test "telegram is read-only via the generic plane" {
    try std.testing.expect(!Channel.telegram.userManaged());
    try std.testing.expect(Channel.slack.userManaged());
    try std.testing.expect(Channel.whatsapp.userManaged());
}

test "parseRoute: list / item / mutate" {
    try std.testing.expectEqual(Route.list, parseRoute("channels").?);

    const item = parseRoute("channels/slack").?;
    try std.testing.expectEqual(Channel.slack, item.item);

    const mutate = parseRoute("channels/whatsapp/connect").?;
    try std.testing.expectEqual(Channel.whatsapp, mutate.mutate.channel);
    try std.testing.expectEqual(Action.connect, mutate.mutate.action);

    const test_route = parseRoute("channels/email/test").?;
    try std.testing.expectEqual(Action.@"test", test_route.mutate.action);

    const disc = parseRoute("channels/discord/disconnect").?;
    try std.testing.expectEqual(Action.disconnect, disc.mutate.action);
}

test "parseRoute: hidden channel + unknown action are unsupported, not silently routed" {
    try std.testing.expectEqual(Route.unsupported, parseRoute("channels/signal").?);
    try std.testing.expectEqual(Route.unsupported, parseRoute("channels/signal/connect").?);
    try std.testing.expectEqual(Route.unsupported, parseRoute("channels/slack/frobnicate").?);
}

test "telegram keeps dedicated connect routes but uses generic liveness test" {
    try std.testing.expect(usesDedicatedMutationRoute(.telegram, .connect));
    try std.testing.expect(!usesDedicatedMutationRoute(.telegram, .@"test"));
    try std.testing.expect(usesDedicatedMutationRoute(.telegram, .disconnect));
    try std.testing.expect(!usesDedicatedMutationRoute(.slack, .@"test"));
}

test "parseRoute: non-channel + bindings + deep paths fall through" {
    try std.testing.expect(parseRoute("voice/transcribe") == null);
    try std.testing.expect(parseRoute("settings") == null);
    // bindings are owned by the upstream matcher — never claimed here.
    try std.testing.expect(parseRoute("channels/slack/bindings") == null);
    try std.testing.expect(parseRoute("channels/slack/bindings/bnd_1") == null);
    // deeper than {ch}/{action}
    try std.testing.expect(parseRoute("channels/slack/connect/extra") == null);
}

test "validateSecretValue enforces provider token shapes" {
    try std.testing.expect(validateSecretValue("slack_bot_token", "xoxb-123456789"));
    try std.testing.expect(!validateSecretValue("slack_bot_token", "nope"));
    try std.testing.expect(!validateSecretValue("slack_bot_token", "xoxp-123456789")); // user token, not bot
    try std.testing.expect(validateSecretValue("slack_app_token", "xapp-1-abcdefgh"));
    try std.testing.expect(!validateSecretValue("slack_app_token", "xoxb-123456789"));
    try std.testing.expect(validateSecretValue("discord_bot_token", "MTAxMjM0NTY3ODkwMTIzNDU2Nzg5MA.abc"));
    try std.testing.expect(!validateSecretValue("discord_bot_token", "short"));
    try std.testing.expect(validateSecretValue("whatsapp_access_token", "EAAabcdefgh12345"));
    try std.testing.expect(!validateSecretValue("whatsapp_access_token", "tiny"));
    // generic secret: any clean token
    try std.testing.expect(validateSecretValue("slack_signing_secret", "abc123def456"));
    // whitespace / control chars are always rejected
    try std.testing.expect(!validateSecretValue("slack_signing_secret", "has space"));
    try std.testing.expect(!validateSecretValue("slack_signing_secret", "line\nbreak"));
    try std.testing.expect(!validateSecretValue("slack_signing_secret", ""));
    try std.testing.expect(validateSecretValue("telegram_bot_token", "8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA"));
    try std.testing.expect(!validateSecretValue("telegram_bot_token", "123456:bad/path"));
}

test "config validation: ports, digit ids, hosts" {
    const port_field = ConfigField{ .key = "imap_port", .label = "p", .required = false, .is_port = true };
    try std.testing.expect(validateConfigValue(port_field, "993"));
    try std.testing.expect(!validateConfigValue(port_field, "0"));
    try std.testing.expect(!validateConfigValue(port_field, "70000"));
    try std.testing.expect(!validateConfigValue(port_field, "abc"));

    const id_field = ConfigField{ .key = "phone_number_id", .label = "id", .required = true, .is_digits = true };
    try std.testing.expect(validateConfigValue(id_field, "123456789012345"));
    try std.testing.expect(!validateConfigValue(id_field, "12a45"));

    const host_field = ConfigField{ .key = "imap_host", .label = "h", .required = true };
    try std.testing.expect(validateConfigValue(host_field, "imap.gmail.com"));
    try std.testing.expect(!validateConfigValue(host_field, "bad\nhost"));
    try std.testing.expect(!validateConfigValue(host_field, ""));
}

test "requiredSecretCount matches descriptors" {
    try std.testing.expectEqual(@as(usize, 2), descriptor(.slack).requiredSecretCount());
    try std.testing.expectEqual(@as(usize, 1), descriptor(.discord).requiredSecretCount());
    try std.testing.expectEqual(@as(usize, 1), descriptor(.email).requiredSecretCount());
    try std.testing.expectEqual(@as(usize, 2), descriptor(.whatsapp).requiredSecretCount());
}

test "discord descriptor exposes the runtime guild id field" {
    const fields = descriptor(.discord).config_fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("guild_id", fields[0].key);
    try std.testing.expectEqualStrings("Guild ID", fields[0].label);
    try std.testing.expect(!fields[0].required);
    try std.testing.expect(fields[0].is_digits);
}

test "resolveStatus transitions" {
    try std.testing.expectEqual(Status.disabled_in_build, resolveStatus(false, true, 2, 2));
    try std.testing.expectEqual(Status.connected, resolveStatus(true, false, 2, 2));
    try std.testing.expectEqual(Status.partial, resolveStatus(true, false, 1, 2));
    try std.testing.expectEqual(Status.operator_managed, resolveStatus(true, true, 0, 2));
    try std.testing.expectEqual(Status.not_connected, resolveStatus(true, false, 0, 2));
}

test "writeChannelJson emits a stable, secret-free shape" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    const refs = [_]SecretRefView{
        .{ .key = "slack_bot_token", .label = "Bot token", .required = true, .present = true },
        .{ .key = "slack_signing_secret", .label = "Signing secret", .required = true, .present = false },
    };
    const cfg = [_]ConfigEntry{.{ .key = "team_id", .value = "T123" }};
    try writeChannelJson(w, .{
        .channel = .slack,
        .build_enabled = true,
        .operator_configured = false,
        .user_managed = true,
        .status = .partial,
        .secret_refs = &refs,
        .config = &cfg,
        .last_test = .{ .ok = false, .checked_at_s = 1730000000, .detail = "missing_required_secret" },
        .endpoints = .{
            .self = "/api/v1/users/42/channels/slack",
            .connect = "/api/v1/users/42/channels/slack/connect",
            .@"test" = "/api/v1/users/42/channels/slack/test",
            .disconnect = "/api/v1/users/42/channels/slack/disconnect",
        },
    });

    const out = buf.items;
    // Parses as valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("slack", obj.get("channel").?.string);
    try std.testing.expectEqualStrings("partial", obj.get("status").?.string);
    try std.testing.expectEqual(false, obj.get("user_connected").?.bool);
    // secret_refs report presence, never values.
    const secret_refs = obj.get("secret_refs").?.array;
    try std.testing.expectEqual(@as(usize, 2), secret_refs.items.len);
    try std.testing.expectEqual(true, secret_refs.items[0].object.get("present").?.bool);
    try std.testing.expectEqual(false, secret_refs.items[1].object.get("present").?.bool);
    // No "value" field is ever present on a secret ref.
    try std.testing.expect(secret_refs.items[0].object.get("value") == null);
    try std.testing.expectEqualStrings("T123", obj.get("config").?.object.get("team_id").?.string);
}

test "writeChannelJson escapes user-controlled config values" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    const cfg = [_]ConfigEntry{.{ .key = "from_address", .value = "a\"b\\c" }};
    try writeChannelJson(w, .{
        .channel = .email,
        .build_enabled = true,
        .operator_configured = false,
        .user_managed = true,
        .status = .not_connected,
        .secret_refs = &.{},
        .config = &cfg,
        .last_test = null,
        .endpoints = .{ .self = "s", .connect = "c", .@"test" = "t", .disconnect = "d" },
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\\c", parsed.value.object.get("config").?.object.get("from_address").?.string);
    // last_test serializes as a JSON null (present key, null value).
    try std.testing.expect(parsed.value.object.get("last_test").? == .null);
}
