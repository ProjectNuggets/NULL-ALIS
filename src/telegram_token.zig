const std = @import("std");

fn is_bot_token_char(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_' or
        ch == '-';
}

pub fn is_bot_token_shape(value: []const u8) bool {
    if (value.len < 16) return false;
    const colon_idx = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (colon_idx == 0 or colon_idx + 1 >= value.len) return false;

    for (value[0..colon_idx]) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    for (value[colon_idx + 1 ..]) |ch| {
        if (!is_bot_token_char(ch)) return false;
    }
    return true;
}

pub fn find_bot_token_candidate(value: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < value.len) : (idx += 1) {
        if (value[idx] != ':') continue;
        if (idx == 0 or idx + 1 >= value.len) continue;

        var left_start = idx;
        while (left_start > 0) {
            const ch = value[left_start - 1];
            if (ch < '0' or ch > '9') break;
            left_start -= 1;
        }
        if (idx - left_start < 5) continue;

        var right_end = idx + 1;
        while (right_end < value.len and is_bot_token_char(value[right_end])) {
            right_end += 1;
        }
        if (right_end - (idx + 1) < 10) continue;

        const candidate = value[left_start..right_end];
        if (is_bot_token_shape(candidate)) return candidate;
    }
    return null;
}

pub fn normalize_bot_token(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            trimmed = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        }
    }
    if (is_bot_token_shape(trimmed)) return trimmed;
    if (find_bot_token_candidate(trimmed)) |candidate| return candidate;
    return trimmed;
}

pub fn is_likely_bot_token(value: []const u8) bool {
    return is_bot_token_shape(normalize_bot_token(value));
}

test "telegram_token normalize unwraps quoted token" {
    const token = normalize_bot_token(" \"8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA\" ");
    try std.testing.expectEqualStrings("8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA", token);
    try std.testing.expect(is_likely_bot_token(token));
}

test "telegram_token normalize extracts token from wrapped json-like string" {
    const wrapped = "{\"key\":\"telegram_bot_token\",\"value\":\"8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA\"}";
    const token = normalize_bot_token(wrapped);
    try std.testing.expectEqualStrings("8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA", token);
    try std.testing.expect(is_likely_bot_token(token));
}

test "telegram_token rejects malformed token" {
    try std.testing.expect(!is_likely_bot_token("abc"));
    try std.testing.expect(!is_likely_bot_token("123456:bad token with spaces"));
}
