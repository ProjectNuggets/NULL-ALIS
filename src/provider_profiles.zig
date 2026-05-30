//! Provider profile contract — pure logic for the ZAKI V2 user-managed
//! model-provider control plane (S7 follow-up).
//!
//! Lets a user register OpenAI-compatible / BYOK provider endpoints
//! (label, provider kind, base URL, auth style, model allowlist, default
//! model, policy state) with the API key held in the encrypted secret
//! vault. The control plane never returns the key value — only a
//! `secret_ref` presence flag. This module is DB/HTTP free; the gateway
//! does the vault + provider_profiles IO and delegates validation, route
//! parsing, and JSON shape here so the contract logic stays
//! unit-testable without Postgres.
//!
//! Security/scope:
//!   - Key values are write-only — never serialized after save.
//!   - base_url is validated to https:// (or http://localhost) so a
//!     profile can't be pointed at an arbitrary cleartext exfil host.
//!   - policy_state `blocked` is operator-only — a user can set
//!     active/disabled but never clear a `blocked` flag.
//!   - V1 `test` is a structural check (base_url + key present + default
//!     model in allowlist). A live provider round-trip is a documented
//!     follow-up so the contract is deterministic and offline-safe.

const std = @import("std");

pub const MAX_LABEL_LEN: usize = 128;
pub const MAX_URL_LEN: usize = 2048;
pub const MAX_MODEL_LEN: usize = 128;

// ── Enumerations / allowlists ─────────────────────────────────────────

pub const provider_kinds = [_][]const u8{
    "openai_compatible",
    "openai",
    "anthropic",
    "azure_openai",
    "gemini",
    "deepseek",
    "moonshot",
    "together",
    "openrouter",
    "groq",
    "custom",
};

pub fn isValidProviderKind(s: []const u8) bool {
    for (provider_kinds) |k| {
        if (std.mem.eql(u8, k, s)) return true;
    }
    return false;
}

pub const auth_styles = [_][]const u8{ "bearer", "api_key_header", "query_param" };

pub fn isValidAuthStyle(s: []const u8) bool {
    for (auth_styles) |a| {
        if (std.mem.eql(u8, a, s)) return true;
    }
    return false;
}

/// Policy states a USER may set. `blocked` exists in the data model but is
/// operator-only — the gateway refuses to let a user write it.
pub fn isUserSettablePolicy(s: []const u8) bool {
    return std.mem.eql(u8, s, "active") or std.mem.eql(u8, s, "disabled");
}

pub fn isKnownPolicy(s: []const u8) bool {
    return isUserSettablePolicy(s) or std.mem.eql(u8, s, "blocked");
}

// ── Field validation ──────────────────────────────────────────────────

pub fn isValidLabel(label: []const u8) bool {
    if (label.len > MAX_LABEL_LEN) return false;
    for (label) |ch| {
        if (ch == '\n' or ch == '\r' or ch == 0x00) return false;
    }
    return true;
}

/// Base URL must be a clean, bounded https URL — or http://localhost /
/// http://127.0.0.1[...] for local dev. No whitespace / control chars.
pub fn isValidBaseUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > MAX_URL_LEN) return false;
    for (url) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (std.mem.startsWith(u8, url, "http://localhost")) return true;
    if (std.mem.startsWith(u8, url, "http://127.0.0.1")) return true;
    return false;
}

pub fn isValidModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_MODEL_LEN) return false;
    for (id) |ch| {
        if (ch <= 0x20 or ch == 0x7f or ch == '"' or ch == '\\') return false;
    }
    return true;
}

/// An API key value must be non-empty, single-line, bounded.
pub fn isValidApiKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 8192) return false;
    for (key) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Profile ids are server-minted hex.
pub fn isValidProfileId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// The vault key a profile's API key is stored under.
pub const SECRET_KEY_PREFIX = "provider_";
pub const SECRET_KEY_SUFFIX = "_api_key";

// ── Route parsing ─────────────────────────────────────────────────────

pub const Route = union(enum) {
    /// providers — GET list, POST create.
    collection,
    /// providers/{id} — GET, PATCH/PUT, DELETE.
    item: []const u8,
    /// providers/{id}/test — POST.
    @"test": []const u8,
    /// Under providers/ but malformed.
    unsupported,
};

pub fn parseRoute(subpath: []const u8) ?Route {
    if (std.mem.eql(u8, subpath, "providers")) return .collection;
    if (!std.mem.startsWith(u8, subpath, "providers/")) return null;
    const rest = subpath["providers/".len..];
    if (rest.len == 0) return .unsupported;
    var it = std.mem.splitScalar(u8, rest, '/');
    const id = it.next() orelse return .unsupported;
    if (id.len == 0) return .unsupported;
    const tail = it.next();
    if (it.next() != null) return .unsupported;
    if (tail) |verb| {
        if (std.mem.eql(u8, verb, "test")) return .{ .@"test" = id };
        return .unsupported;
    }
    return .{ .item = id };
}

// ── JSON serialization ────────────────────────────────────────────────

pub const ProfileView = struct {
    id: []const u8,
    label: []const u8,
    provider_kind: []const u8,
    base_url: []const u8,
    auth_style: []const u8,
    /// Raw JSON array string (gateway-controlled, already escaped).
    model_allowlist_json: []const u8,
    default_model: ?[]const u8,
    policy_state: []const u8,
    secret_ref_key: []const u8,
    secret_present: bool,
    /// Raw JSON object string or null (gateway-controlled).
    last_test_json: ?[]const u8,
    created_at_s: i64,
    updated_at_s: i64,
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
                if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch);
            },
        }
    }
}

pub fn writeProfileJson(w: anytype, v: ProfileView) !void {
    try w.writeAll("{\"id\":\"");
    try jsonEscape(w, v.id);
    try w.writeAll("\",\"label\":\"");
    try jsonEscape(w, v.label);
    try w.writeAll("\",\"provider_kind\":\"");
    try jsonEscape(w, v.provider_kind);
    try w.writeAll("\",\"base_url\":\"");
    try jsonEscape(w, v.base_url);
    try w.writeAll("\",\"auth_style\":\"");
    try jsonEscape(w, v.auth_style);
    try w.writeAll("\",\"model_allowlist\":");
    // Raw, gateway-controlled JSON array. Fall back to [] if empty.
    if (v.model_allowlist_json.len == 0) {
        try w.writeAll("[]");
    } else {
        try w.writeAll(v.model_allowlist_json);
    }
    try w.writeAll(",\"default_model\":");
    if (v.default_model) |dm| {
        try w.writeByte('"');
        try jsonEscape(w, dm);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"policy_state\":\"");
    try jsonEscape(w, v.policy_state);
    try w.writeAll("\",\"secret_ref\":{\"key\":\"");
    try jsonEscape(w, v.secret_ref_key);
    try w.print("\",\"present\":{s}}},\"last_test\":", .{if (v.secret_present) "true" else "false"});
    if (v.last_test_json) |lt| {
        if (lt.len == 0) try w.writeAll("null") else try w.writeAll(lt);
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"created_at_s\":{d},\"updated_at_s\":{d}}}", .{ v.created_at_s, v.updated_at_s });
}

// ── Tests ─────────────────────────────────────────────────────────────

test "provider kind allowlist" {
    try std.testing.expect(isValidProviderKind("openai_compatible"));
    try std.testing.expect(isValidProviderKind("anthropic"));
    try std.testing.expect(!isValidProviderKind("skynet"));
    try std.testing.expect(!isValidProviderKind(""));
}

test "auth style + policy allowlists" {
    try std.testing.expect(isValidAuthStyle("bearer"));
    try std.testing.expect(!isValidAuthStyle("password"));
    try std.testing.expect(isUserSettablePolicy("active"));
    try std.testing.expect(isUserSettablePolicy("disabled"));
    // blocked is operator-only — not user-settable, but a known state.
    try std.testing.expect(!isUserSettablePolicy("blocked"));
    try std.testing.expect(isKnownPolicy("blocked"));
    try std.testing.expect(!isKnownPolicy("nuked"));
}

test "base_url validation: https or localhost only" {
    try std.testing.expect(isValidBaseUrl("https://api.openai.com/v1"));
    try std.testing.expect(isValidBaseUrl("http://localhost:11434/v1"));
    try std.testing.expect(isValidBaseUrl("http://127.0.0.1:1234"));
    try std.testing.expect(!isValidBaseUrl("http://evil.com/v1")); // cleartext non-local
    try std.testing.expect(!isValidBaseUrl("ftp://x"));
    try std.testing.expect(!isValidBaseUrl("https://has space.com"));
    try std.testing.expect(!isValidBaseUrl(""));
}

test "model id + api key + profile id validation" {
    try std.testing.expect(isValidModelId("gpt-4.1"));
    try std.testing.expect(!isValidModelId("bad\"id"));
    try std.testing.expect(isValidApiKey("sk-abc123"));
    try std.testing.expect(!isValidApiKey("has space"));
    try std.testing.expect(!isValidApiKey(""));
    try std.testing.expect(isValidProfileId("deadbeef01"));
    try std.testing.expect(!isValidProfileId("../x"));
}

test "parseRoute" {
    try std.testing.expectEqual(Route.collection, parseRoute("providers").?);
    try std.testing.expectEqualStrings("abc123", parseRoute("providers/abc123").?.item);
    try std.testing.expectEqualStrings("abc123", parseRoute("providers/abc123/test").?.@"test");
    try std.testing.expectEqual(Route.unsupported, parseRoute("providers/abc/frob").?);
    try std.testing.expect(parseRoute("channels") == null);
}

test "writeProfileJson never leaks the key, emits stable shape" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeProfileJson(w, .{
        .id = "abc123",
        .label = "My OpenAI",
        .provider_kind = "openai_compatible",
        .base_url = "https://api.openai.com/v1",
        .auth_style = "bearer",
        .model_allowlist_json = "[\"gpt-4.1\",\"gpt-5.2\"]",
        .default_model = "gpt-4.1",
        .policy_state = "active",
        .secret_ref_key = "provider_abc123_api_key",
        .secret_present = true,
        .last_test_json = "{\"ok\":true,\"checked_at_s\":1730000000,\"detail\":\"credentials_present\"}",
        .created_at_s = 1730000000,
        .updated_at_s = 1730000100,
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("openai_compatible", o.get("provider_kind").?.string);
    try std.testing.expectEqual(@as(usize, 2), o.get("model_allowlist").?.array.items.len);
    try std.testing.expectEqualStrings("gpt-4.1", o.get("default_model").?.string);
    // The key value is NEVER present — only a ref + presence.
    try std.testing.expect(o.get("api_key") == null);
    try std.testing.expect(o.get("key") == null);
    const ref = o.get("secret_ref").?.object;
    try std.testing.expectEqualStrings("provider_abc123_api_key", ref.get("key").?.string);
    try std.testing.expectEqual(true, ref.get("present").?.bool);
    try std.testing.expectEqual(true, o.get("last_test").?.object.get("ok").?.bool);
}

test "writeProfileJson handles null default_model + last_test + empty allowlist" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeProfileJson(w, .{
        .id = "x",
        .label = "",
        .provider_kind = "custom",
        .base_url = "https://x",
        .auth_style = "bearer",
        .model_allowlist_json = "",
        .default_model = null,
        .policy_state = "disabled",
        .secret_ref_key = "provider_x_api_key",
        .secret_present = false,
        .last_test_json = null,
        .created_at_s = 1,
        .updated_at_s = 2,
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expect(o.get("default_model").? == .null);
    try std.testing.expect(o.get("last_test").? == .null);
    try std.testing.expectEqual(@as(usize, 0), o.get("model_allowlist").?.array.items.len);
    try std.testing.expectEqual(false, o.get("secret_ref").?.object.get("present").?.bool);
}
