//! Human-readable, SAFE one-line summaries for tool-approval cards.
//!
//! When a supervised/mutating tool needs user approval, the UI renders an
//! approval card showing `{risk} · {reason}`. Historically `reason` was the
//! static string `"supervised_mutating_requires_approval"`, which told the
//! user the *risk* but never *what* they were approving.
//!
//! `buildApprovalReason` turns a `ParsedToolCall` (tool name + raw JSON args)
//! into a short, redacted, action-first description — e.g.
//!   `Open web page: https://example.com`
//!   `Run a shell command: rm -rf ./build`
//!   `Schedule a recurring task (*/2 * * * *)`
//!
//! ## Safety contract (this event was deliberately arg-free before)
//! * **Redact** any value whose KEY matches (case-insensitive)
//!   token|secret|password|passwd|api_key|apikey|key|authorization|auth|
//!   credential|cookie|bearer → rendered as `[redacted]` (or the key omitted).
//! * Never dump full raw argument values — summarize / truncate.
//! * Cap the TOTAL reason at `max_reason_len` chars (truncated with `…`).
//! * Strip newlines / control chars — always single line.
//!
//! ## Failure posture
//! Fully **fail-soft**: any JSON parse error, unexpected shape, or empty input
//! returns a safe generic summary. The function only returns an error on
//! allocation failure (the caller degrades that to a static literal). It must
//! NEVER crash or fail the turn.

const std = @import("std");
const dispatcher = @import("dispatcher.zig");
const tool_metadata = @import("../tools/metadata.zig");

const ParsedToolCall = dispatcher.ParsedToolCall;
const ToolMetadata = tool_metadata.ToolMetadata;

/// Hard cap on the total reason length (UTF-8 bytes, pre-ellipsis budget).
/// Matches the ~160 char ceiling the approval card can comfortably render.
pub const max_reason_len: usize = 160;

/// Last-resort summary when nothing better can be derived. Returned (as an
/// owned dupe) on empty input; also the conceptual fallback the CALLER uses
/// as a static literal if this function fails to allocate.
pub const generic_fallback: []const u8 = "supervised mutating tool requires approval";

/// Build a SAFE, single-line, human-readable description of `call` for the
/// approval card. Returns an allocator-owned slice the caller must free.
///
/// Fail-soft: never returns an error except on allocation failure (OOM).
pub fn buildApprovalReason(
    allocator: std.mem.Allocator,
    call: ParsedToolCall,
    meta: ToolMetadata,
) ![]const u8 {
    _ = meta; // risk is rendered separately by the FE; reserved for future use.

    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    // Parse the args object up-front. Any failure → tool-name-only summary.
    // Use an arena so the parsed tree + any scratch is freed in one shot and
    // we never leak on the many early-return branches below.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const args_obj: ?std.json.ObjectMap = blk: {
        if (call.arguments_json.len == 0) break :blk null;
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            aa,
            call.arguments_json,
            .{},
        ) catch break :blk null;
        // Parsed tree is arena-owned; no separate deinit needed.
        break :blk switch (parsed.value) {
            .object => |obj| obj,
            else => null,
        };
    };

    try appendSummary(&buf, allocator, call.name, args_obj);

    // Defensive: never hand back an empty reason.
    if (buf.items.len == 0) {
        try buf.appendSlice(allocator, call.name);
        if (buf.items.len == 0) try buf.appendSlice(allocator, generic_fallback);
    }

    return buf.toOwnedSlice(allocator);
}

/// Route to a tool-aware builder, else the generic key-listing fallback.
/// `args` is null when arguments were absent / malformed / non-object.
fn appendSummary(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    tool: []const u8,
    args: ?std.json.ObjectMap,
) !void {
    const eq = std.mem.eql;

    // ── Scheduling ────────────────────────────────────────────────
    if (eq(u8, tool, "schedule") or eq(u8, tool, "cron_add") or
        eq(u8, tool, "cron_update") or eq(u8, tool, "cron_remove") or
        eq(u8, tool, "cron_run"))
    {
        try buf.appendSlice(gpa, "Schedule a recurring task");
        if (args) |a| {
            // Prefer an explicit cron expression; fall back to a delay.
            if (safeStr(a, "expression")) |expr| {
                try appendParen(buf, gpa, expr);
            } else if (safeStr(a, "delay")) |delay| {
                try appendParen(buf, gpa, delay);
            }
        }
        return;
    }

    // ── Browser / extension navigation ────────────────────────────
    if (eq(u8, tool, "browser_navigate") or eq(u8, tool, "extension_navigate") or
        eq(u8, tool, "web_fetch"))
    {
        const verb = if (eq(u8, tool, "web_fetch")) "Fetch web page" else "Open web page";
        try buf.appendSlice(gpa, verb);
        if (args) |a| {
            if (safeStr(a, "url")) |url| {
                try buf.appendSlice(gpa, ": ");
                try appendUrl(buf, gpa, url, max_reason_len);
            }
        }
        return;
    }

    // ── Outbound messaging ────────────────────────────────────────
    if (eq(u8, tool, "message") or eq(u8, tool, "pushover")) {
        try buf.appendSlice(gpa, "Send a message");
        if (args) |a| {
            // Prefer the most specific recipient hint available.
            const recip = safeStr(a, "channel") orelse
                safeStr(a, "chat_id") orelse
                safeStr(a, "account_id") orelse
                safeStr(a, "title");
            if (recip) |r| {
                try buf.appendSlice(gpa, " to ");
                try appendSanitized(buf, gpa, r);
            }
        }
        return;
    }

    // ── Shell / command execution ─────────────────────────────────
    if (eq(u8, tool, "shell") or eq(u8, tool, "bash")) {
        try buf.appendSlice(gpa, "Run a shell command");
        if (args) |a| {
            if (safeStr(a, "command")) |cmd| {
                try buf.appendSlice(gpa, ": ");
                try appendSanitizedTrunc(buf, gpa, cmd, 60);
            }
        }
        return;
    }

    // ── Memory writes ─────────────────────────────────────────────
    if (eq(u8, tool, "memory_store") or eq(u8, tool, "memory_edit")) {
        try buf.appendSlice(gpa, "Store a memory");
        if (args) |a| {
            if (safeStr(a, "key")) |key| {
                try buf.appendSlice(gpa, ": ");
                try appendSanitized(buf, gpa, key);
            }
        }
        return;
    }
    if (eq(u8, tool, "memory_forget")) {
        try buf.appendSlice(gpa, "Forget a memory");
        if (args) |a| {
            if (safeStr(a, "key")) |key| {
                try buf.appendSlice(gpa, ": ");
                try appendSanitized(buf, gpa, key);
            }
        }
        return;
    }

    // ── File writes ───────────────────────────────────────────────
    if (eq(u8, tool, "file_write") or eq(u8, tool, "file_append") or
        eq(u8, tool, "file_edit") or eq(u8, tool, "file_edit_hashed"))
    {
        const verb = if (eq(u8, tool, "file_append"))
            "Append to file"
        else if (eq(u8, tool, "file_edit") or eq(u8, tool, "file_edit_hashed"))
            "Edit file"
        else
            "Write file";
        try buf.appendSlice(gpa, verb);
        if (args) |a| {
            if (safeStr(a, "path")) |path| {
                try buf.appendSlice(gpa, ": ");
                try appendSanitized(buf, gpa, path);
            }
        }
        return;
    }

    // ── Document production ───────────────────────────────────────
    if (eq(u8, tool, "produce_document")) {
        try buf.appendSlice(gpa, "Create a document");
        if (args) |a| {
            if (safeStr(a, "title")) |title| {
                try buf.appendSlice(gpa, ": ");
                try appendSanitized(buf, gpa, title);
            } else if (safeStr(a, "format")) |fmt| {
                try appendParen(buf, gpa, fmt);
            }
        }
        return;
    }

    // ── Delegation / sub-agents ───────────────────────────────────
    if (eq(u8, tool, "delegate") or eq(u8, tool, "spawn")) {
        try buf.appendSlice(gpa, "Delegate a task to sub-agent");
        if (args) |a| {
            const who = safeStr(a, "agent") orelse safeStr(a, "label");
            if (who) |name| {
                try buf.appendSlice(gpa, " ");
                try appendSanitized(buf, gpa, name);
            }
        }
        return;
    }

    // ── HTTP requests ─────────────────────────────────────────────
    if (eq(u8, tool, "http_request")) {
        try buf.appendSlice(gpa, "Make an HTTP request");
        if (args) |a| {
            if (safeStr(a, "method")) |m| {
                try buf.appendSlice(gpa, " ");
                try appendSanitizedTrunc(buf, gpa, m, 8);
            }
            if (safeStr(a, "url")) |url| {
                try buf.appendSlice(gpa, " ");
                try appendUrl(buf, gpa, url, max_reason_len);
            }
        }
        return;
    }

    // ── Image generation ──────────────────────────────────────────
    if (eq(u8, tool, "image_generate")) {
        try buf.appendSlice(gpa, "Generate an image");
        return;
    }

    // ── Generic fallback: "<tool>: with fields a, b, c" ───────────
    try appendGenericFields(buf, gpa, tool, args);
}

/// Fallback for unknown tools: list the safe top-level argument KEY names
/// (never values). Sensitive keys are kept (they're just names, not secrets)
/// but the format intentionally emits no values at all.
fn appendGenericFields(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    tool: []const u8,
    args: ?std.json.ObjectMap,
) !void {
    try buf.appendSlice(gpa, tool);
    const a = args orelse return;
    if (a.count() == 0) return;

    try buf.appendSlice(gpa, ": with fields ");
    var it = a.iterator();
    var first = true;
    while (it.next()) |entry| {
        // Stop early if we're already near the cap — no point listing keys
        // that the final truncation will drop anyway.
        if (buf.items.len >= max_reason_len) break;
        if (!first) try buf.appendSlice(gpa, ", ");
        first = false;
        try appendSanitizedTrunc(buf, gpa, entry.key_ptr.*, 40);
    }
}

// ── Helpers ───────────────────────────────────────────────────────

/// Read a string field, returning null for sensitive keys, absent keys, or
/// non-string values. Centralizes the redaction policy at the read boundary
/// so a sensitive value can never reach the output buffer.
fn safeStr(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (isSensitiveKey(key)) return null;
    const v = args.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Case-insensitive substring match against the sensitive-key denylist.
fn isSensitiveKey(key: []const u8) bool {
    const needles = [_][]const u8{
        "token",      "secret", "password",      "passwd",
        "api_key",    "apikey", "authorization", "auth",
        "credential", "cookie", "bearer",
    };
    // Deliberate omission of a bare "key": memory_store / memory_edit /
    // memory_forget use `key` as a NON-secret identifier we WANT to show
    // ("Store a memory: user.timezone"). Secret-bearing variants are still
    // caught above as substrings — `api_key`, `apikey`, and any
    // `*_secret_key` / `bearer_key` style name matches `secret`/`bearer`.
    for (needles) |n| {
        if (containsIgnoreCase(key, n)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    const last = haystack.len - needle.len;
    while (i <= last) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Append ` (value)` with the value sanitized + truncated to a tight budget.
fn appendParen(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try buf.appendSlice(gpa, " (");
    try appendSanitizedTrunc(buf, gpa, value, 40);
    try buf.appendSlice(gpa, ")");
}

/// Append `s` with control chars/newlines collapsed to spaces, respecting the
/// global `max_reason_len` cap (drops bytes that would overflow).
fn appendSanitized(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try appendSanitizedTrunc(buf, gpa, s, max_reason_len);
}

/// Append a URL with its **query string and fragment stripped** before
/// sanitizing/truncating. A URL field name is never "sensitive" (redaction
/// keys on the field name, not the value), so a raw URL like
/// `https://api.example.com/x?access_token=SECRET` would otherwise flow
/// verbatim into the reason → the approval event → the run trace → the app
/// log. The approver needs the destination host+path, NOT the secret-bearing
/// query, so we drop everything from the first `?` or `#` (whichever comes
/// first). Fail-soft: input with no `?`/`#` is rendered as-is; non-URL input
/// (no `//`) is still cut at the first `?`/`#` if present, then shown
/// sanitized+truncated — never worse than before, never crashes.
fn appendUrl(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    raw_url: []const u8,
    max_len: usize,
) !void {
    // Cut at the earliest query (`?`) or fragment (`#`) delimiter. This keeps
    // `scheme://host[:port]/path` and discards `?query` / `#fragment` wholesale
    // — the safe, simple choice (vs. per-param redaction). Applies to non-URL
    // input too: still strictly removes any trailing secret-bearing query.
    const q = std.mem.indexOfScalar(u8, raw_url, '?');
    const h = std.mem.indexOfScalar(u8, raw_url, '#');
    const cut: usize = if (q != null and h != null)
        @min(q.?, h.?)
    else
        q orelse h orelse raw_url.len;
    try appendSanitizedTrunc(buf, gpa, raw_url[0..cut], max_len);
}

/// Append `s` sanitized, truncated to at most `limit` source bytes AND never
/// exceeding the global `max_reason_len` total. Control chars (`< 0x20`) and
/// DEL (`0x7f`) become a single space; runs of whitespace are collapsed so the
/// result is compact and single-line. If the source was truncated, an ellipsis
/// `…` is appended.
fn appendSanitizedTrunc(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    s: []const u8,
    limit: usize,
) !void {
    var consumed: usize = 0;
    var last_was_space = endsWithSpace(buf.items);
    var truncated = false;
    // Length of `buf` at the start of the most recently appended codepoint, so
    // we can back the cut off to a UTF-8 boundary if we truncate mid-sequence.
    var last_cp_start: usize = buf.items.len;
    for (s, 0..) |c, idx| {
        if (consumed >= limit) {
            truncated = idx < s.len;
            break;
        }
        if (buf.items.len >= max_reason_len) {
            truncated = true;
            break;
        }
        const ch: u8 = if (c < 0x20 or c == 0x7f) ' ' else c;
        if (ch == ' ') {
            if (last_was_space) {
                consumed += 1;
                continue;
            }
            last_was_space = true;
        } else {
            last_was_space = false;
        }
        // Remember where this codepoint begins (ASCII and UTF-8 lead bytes are
        // < 0x80 or >= 0xC0; continuation bytes are 0x80..0xBF). `ch` is the
        // sanitized byte, but multi-byte sequences are passed through verbatim
        // (every byte >= 0x80, so never rewritten to space), so the source
        // boundary structure is preserved in the output.
        if (ch < 0x80 or ch >= 0xC0) last_cp_start = buf.items.len;
        try buf.append(gpa, ch);
        consumed += 1;
    }
    if (truncated) {
        // If we stopped partway through a multi-byte UTF-8 sequence, back the
        // cut off to the start of that codepoint so we never leave a lone
        // continuation byte (or partial sequence) before the ellipsis. We only
        // wrote whole bytes, so if the tail isn't a complete, valid sequence,
        // drop back to `last_cp_start`.
        const tail = buf.items[last_cp_start..];
        if (tail.len > 0 and !std.unicode.utf8ValidateSlice(tail)) {
            buf.shrinkRetainingCapacity(last_cp_start);
        }
        // "…" is 3 UTF-8 bytes; only add it if there's room.
        if (buf.items.len + 3 <= max_reason_len + 3) {
            try buf.appendSlice(gpa, "…");
        }
    }
}

fn endsWithSpace(items: []const u8) bool {
    return items.len > 0 and (items[items.len - 1] == ' ');
}

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

const testing = std.testing;

fn callOf(name: []const u8, args: []const u8) ParsedToolCall {
    return .{ .name = name, .arguments_json = args, .tool_call_id = null };
}

const test_meta = ToolMetadata{ .name = "x", .risk_level = .medium };

test "schedule args mention Schedule and include cadence" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("schedule", "{\"action\":\"create\",\"command\":\"daily brief\",\"expression\":\"*/2 * * * *\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Schedule") != null);
    try testing.expect(std.mem.indexOf(u8, r, "*/2 * * * *") != null);
}

test "schedule without cadence still summarizes safely" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("schedule", "{\"action\":\"create\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Schedule a recurring task") != null);
}

test "browser_navigate renders Open web page: <url>" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("browser_navigate", "{\"session_id\":\"s1\",\"url\":\"https://example.com/path\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("Open web page: https://example.com/path", r);
}

test "browser_navigate strips URL query/fragment (no secret leak)" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("browser_navigate", "{\"url\":\"https://api.example.com/x?access_token=SECRET&api_key=sk-LEAKME\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    // Host + path survive…
    try testing.expect(std.mem.indexOf(u8, r, "https://api.example.com/x") != null);
    // …but the secret-bearing query is gone entirely.
    try testing.expect(std.mem.indexOf(u8, r, "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, r, "access_token") == null);
    try testing.expect(std.mem.indexOf(u8, r, "sk-LEAKME") == null);
}

test "http_request strips URL query (no secret leak)" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("http_request", "{\"method\":\"POST\",\"url\":\"https://api.example.com/x?token=SECRET\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "https://api.example.com/x") != null);
    try testing.expect(std.mem.indexOf(u8, r, "POST") != null);
    try testing.expect(std.mem.indexOf(u8, r, "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, r, "token=") == null);
}

test "URL fragment is also stripped" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("browser_navigate", "{\"url\":\"https://example.com/page#secret-anchor\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("Open web page: https://example.com/page", r);
}

test "URL without query/fragment is rendered as-is" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("web_fetch", "{\"url\":\"https://example.com/a/b/c\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("Fetch web page: https://example.com/a/b/c", r);
}

test "appendUrl is fail-soft on non-URL input (still strips any query)" {
    // No "//" scheme separator — fall back to sanitized+truncated, but still
    // cut at the first '?' so a trailing query can't leak.
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("web_fetch", "{\"url\":\"not-a-url?token=SECRET\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "not-a-url") != null);
    try testing.expect(std.mem.indexOf(u8, r, "SECRET") == null);
}

test "UTF-8-safe truncation: multi-byte url never leaves a lone continuation byte" {
    // A long run of 2-byte 'é' (0xC3 0xA9) that overruns the cap — the cut must
    // land on a codepoint boundary so the result stays valid UTF-8.
    var url: [4000]u8 = undefined;
    var i: usize = 0;
    while (i + 1 < url.len) : (i += 2) {
        url[i] = 0xC3;
        url[i + 1] = 0xA9;
    }
    const args = try std.fmt.allocPrint(testing.allocator, "{{\"url\":\"https://x/{s}\"}}", .{url[0 .. url.len - (url.len % 2)]});
    defer testing.allocator.free(args);

    const r = try buildApprovalReason(testing.allocator, callOf("browser_navigate", args), test_meta);
    defer testing.allocator.free(r);
    try testing.expect(r.len <= max_reason_len + 3);
    try testing.expect(std.unicode.utf8ValidateSlice(r));
}

test "UTF-8-safe truncation: multi-byte 3-byte command stays valid" {
    // 3-byte CJK '漢' (0xE6 0xBC 0xA2) repeated past the 60-byte command cap.
    // A single leading ASCII byte shifts the 60-byte cut to byte 59 of the
    // 漢-run (59 % 3 == 2 → lands MID-sequence), so this genuinely exercises
    // the codepoint-boundary back-off (without the fix it would leave a lone
    // continuation byte before the ellipsis → invalid UTF-8).
    var cmd: [600]u8 = undefined;
    cmd[0] = 'x';
    var i: usize = 1;
    while (i + 2 < cmd.len) : (i += 3) {
        cmd[i] = 0xE6;
        cmd[i + 1] = 0xBC;
        cmd[i + 2] = 0xA2;
    }
    const n = i; // whole 漢 codepoints only (plus the leading 'x')
    const args = try std.fmt.allocPrint(testing.allocator, "{{\"command\":\"{s}\"}}", .{cmd[0..n]});
    defer testing.allocator.free(args);

    const r = try buildApprovalReason(testing.allocator, callOf("shell", args), test_meta);
    defer testing.allocator.free(r);
    try testing.expect(std.unicode.utf8ValidateSlice(r));
    // The 漢 chars that survived must be intact (no partial trailing sequence).
    try testing.expect(std.mem.indexOf(u8, r, "漢") != null);
}

test "sensitive token value is redacted (not present in output)" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("unknown_tool", "{\"token\":\"SUPER_SECRET_VALUE\",\"path\":\"/tmp/x\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "SUPER_SECRET_VALUE") == null);
}

test "sensitive password/secret/api_key values never leak" {
    const cases = [_][]const u8{
        "{\"password\":\"hunter2\"}",
        "{\"secret\":\"hunter2\"}",
        "{\"api_key\":\"hunter2\"}",
        "{\"Authorization\":\"Bearer hunter2\"}",
        "{\"session_cookie\":\"hunter2\"}",
    };
    for (cases) |c| {
        const r = try buildApprovalReason(testing.allocator, callOf("message", c), test_meta);
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "hunter2") == null);
    }
}

test "shell command is truncated and single-line" {
    // 200-char command containing newlines.
    var big: [200]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = if (i % 20 == 0) '\n' else 'a';
    const args = try std.fmt.allocPrint(testing.allocator, "{{\"command\":\"{s}\"}}", .{big});
    defer testing.allocator.free(args);

    const r = try buildApprovalReason(testing.allocator, callOf("shell", args), test_meta);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Run a shell command") != null);
    // No raw newline survives.
    try testing.expect(std.mem.indexOf(u8, r, "\n") == null);
}

test "very long arg output is capped to ~160 chars and single-line" {
    var big: [4000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = if (i % 13 == 0) '\n' else 'z';
    const args = try std.fmt.allocPrint(testing.allocator, "{{\"url\":\"{s}\"}}", .{big});
    defer testing.allocator.free(args);

    const r = try buildApprovalReason(testing.allocator, callOf("browser_navigate", args), test_meta);
    defer testing.allocator.free(r);
    // Cap is max_reason_len plus a possible 3-byte ellipsis.
    try testing.expect(r.len <= max_reason_len + 3);
    try testing.expect(std.mem.indexOf(u8, r, "\n") == null);
}

test "malformed JSON returns safe non-empty generic string" {
    const r = try buildApprovalReason(testing.allocator, callOf("weird_tool", "{bad json"), test_meta);
    defer testing.allocator.free(r);
    try testing.expect(r.len > 0);
    // Tool name is the safe anchor.
    try testing.expect(std.mem.indexOf(u8, r, "weird_tool") != null);
}

test "empty arguments returns safe non-empty string" {
    const r = try buildApprovalReason(testing.allocator, callOf("weird_tool", ""), test_meta);
    defer testing.allocator.free(r);
    try testing.expect(r.len > 0);
    try testing.expect(std.mem.indexOf(u8, r, "weird_tool") != null);
}

test "unknown tool falls back to with-fields listing" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("my_tool", "{\"alpha\":1,\"beta\":\"x\",\"gamma\":true}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "my_tool") != null);
    try testing.expect(std.mem.indexOf(u8, r, "with fields") != null);
    try testing.expect(std.mem.indexOf(u8, r, "alpha") != null);
    // Values must not appear — only key names.
    try testing.expect(std.mem.indexOf(u8, r, "true") == null);
}

test "message includes recipient channel" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("message", "{\"content\":\"hi\",\"channel\":\"telegram\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Send a message") != null);
    try testing.expect(std.mem.indexOf(u8, r, "telegram") != null);
}

test "memory_store includes the key" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("memory_store", "{\"key\":\"user.timezone\",\"content\":\"UTC\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Store a memory") != null);
    try testing.expect(std.mem.indexOf(u8, r, "user.timezone") != null);
}

test "delegate names the sub-agent" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("delegate", "{\"agent\":\"code-reviewer\",\"prompt\":\"review\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "code-reviewer") != null);
}

test "file_write names the path" {
    const r = try buildApprovalReason(
        testing.allocator,
        callOf("file_write", "{\"path\":\"notes/todo.md\",\"content\":\"...\"}"),
        test_meta,
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Write file: notes/todo.md") != null);
}

test "non-object JSON arguments degrade to tool-name summary" {
    // Valid JSON, but an array — not an object.
    const r = try buildApprovalReason(testing.allocator, callOf("weird_tool", "[1,2,3]"), test_meta);
    defer testing.allocator.free(r);
    try testing.expect(r.len > 0);
    try testing.expect(std.mem.indexOf(u8, r, "weird_tool") != null);
}
