const std = @import("std");
const root = @import("root.zig");
const http_native = @import("../http_native/root.zig");

pub const SseToolCallDelta = struct {
    index: usize,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,

    fn deinit(self: *const SseToolCallDelta, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        if (self.name) |name| allocator.free(name);
        if (self.arguments) |arguments| allocator.free(arguments);
    }
};

/// V1.11 hardening (2026-05-07) — usage emitted in SSE stream when
/// `stream_options.include_usage=true` was set on the request. Together,
/// OpenRouter, Groq, and Moonshot emit a final pre-`[DONE]` chunk shaped
/// like `{choices:[], usage: {prompt_tokens, completion_tokens, ...}}`.
/// Parsing this lets us replace the prior `char_count/4` heuristic with
/// the provider's authoritative count, fixing pricing.zig accuracy on
/// reasoning-heavy turns and unblocking quota enforcement.
pub const SseUsage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,
    cached_tokens: u32 = 0,
};

/// Result of parsing a single SSE line.
pub const SseLineResult = struct {
    /// Text delta content (owned, caller frees).
    text: ?[]const u8 = null,
    /// Reasoning / thinking delta content (owned, caller frees).
    /// Populated when the provider streams `delta.reasoning_content` or the
    /// choice-level `reasoning` field (Kimi / GLM / some OpenRouter models).
    reasoning: ?[]const u8 = null,
    /// Structured tool call deltas (owned, caller frees).
    tool_call_deltas: []const SseToolCallDelta = &.{},
    /// Authoritative usage report (V1.11 hardening). Populated only when the
    /// provider emits a final `usage` chunk per OpenAI spec
    /// `stream_options.include_usage=true`. Replaces the post-stream
    /// completion-token estimation.
    usage: ?SseUsage = null,
    /// Stream is complete ([DONE] sentinel).
    done: bool = false,

    fn deinit(self: *const SseLineResult, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        for (self.tool_call_deltas) |delta| delta.deinit(allocator);
        if (self.tool_call_deltas.len > 0) allocator.free(self.tool_call_deltas);
    }

    fn isSkip(self: SseLineResult) bool {
        return !self.done and self.text == null and self.reasoning == null and
            self.tool_call_deltas.len == 0 and self.usage == null;
    }
};

/// Parse a single SSE line in OpenAI streaming format.
///
/// Handles:
/// - `data: [DONE]` → `.done`
/// - `data: {JSON}` → extracts `choices[*].delta.content` and `choices[*].delta.tool_calls[*]`
/// - Empty lines, comments (`:`) → `.skip`
pub fn parseSseLine(allocator: std.mem.Allocator, line: []const u8) !SseLineResult {
    const trimmed = std.mem.trimRight(u8, line, "\r");

    if (trimmed.len == 0) return .{};
    if (trimmed[0] == ':') return .{};

    const data = extractSseDataPayload(trimmed) orelse return .{};

    if (std.mem.eql(u8, data, "[DONE]")) return .{ .done = true };

    return try extractSseEvent(allocator, data);
}

fn extractSseDataPayload(line: []const u8) ?[]const u8 {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return std.mem.trimLeft(u8, line[prefix.len..], " ");
}

/// Extract text and tool-call deltas from an OpenAI-compatible SSE JSON payload.
pub fn extractSseEvent(allocator: std.mem.Allocator, json_str: []const u8) !SseLineResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return .{},
    };

    var text_builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text_builder.deinit(allocator);

    var reasoning_builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer reasoning_builder.deinit(allocator);

    var tool_deltas: std.ArrayListUnmanaged(SseToolCallDelta) = .empty;
    errdefer {
        for (tool_deltas.items) |delta| delta.deinit(allocator);
        tool_deltas.deinit(allocator);
    }

    // V1.11 hardening (2026-05-07): the OpenAI-spec final usage chunk
    // arrives with `choices: []` (empty) and the usage object at the
    // top level. Pre-fix this function early-returned on empty choices,
    // dropping the usage payload. Now we walk choices when present and
    // extract usage independently below — both/either path is fine.
    const choices_opt: ?std.json.Value = obj.get("choices");
    if (choices_opt) |choices_v| {
        if (choices_v == .array) {
            const choices_array = choices_v.array;
            for (choices_array.items) |choice| {
                const choice_obj = switch (choice) {
                    .object => |object| object,
                    else => continue,
                };

                // Choice-level `reasoning` fallback (some providers put reasoning here
                // at the choice level rather than inside delta).
                if (choice_obj.get("reasoning")) |reasoning_value| {
                    if (reasoning_value == .string and reasoning_value.string.len > 0) {
                        try reasoning_builder.appendSlice(allocator, reasoning_value.string);
                    }
                }

                const delta = choice_obj.get("delta") orelse continue;
                const delta_obj = switch (delta) {
                    .object => |object| object,
                    else => continue,
                };

                if (delta_obj.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        try text_builder.appendSlice(allocator, content.string);
                    }
                }

                // OpenAI-compatible reasoning streaming: Kimi/GLM/some OpenRouter
                // models emit `delta.reasoning_content` per chunk. Without this path
                // the thinking stream is silently dropped and the UI shows only
                // generic stage labels.
                if (delta_obj.get("reasoning_content")) |reasoning_value| {
                    if (reasoning_value == .string and reasoning_value.string.len > 0) {
                        try reasoning_builder.appendSlice(allocator, reasoning_value.string);
                    }
                }
                if (delta_obj.get("reasoning")) |reasoning_value| {
                    if (reasoning_value == .string and reasoning_value.string.len > 0) {
                        try reasoning_builder.appendSlice(allocator, reasoning_value.string);
                    }
                }

                if (delta_obj.get("tool_calls")) |tool_calls| {
                    const tool_calls_array = switch (tool_calls) {
                        .array => |array| array,
                        else => continue,
                    };

                    for (tool_calls_array.items) |tool_call| {
                        const tool_call_obj = switch (tool_call) {
                            .object => |object| object,
                            else => continue,
                        };

                        const index_value = tool_call_obj.get("index") orelse continue;
                        const index = switch (index_value) {
                            .integer => |value| if (value >= 0) @as(usize, @intCast(value)) else continue,
                            else => continue,
                        };

                        var tool_delta = SseToolCallDelta{ .index = index };
                        errdefer tool_delta.deinit(allocator);

                        if (tool_call_obj.get("id")) |id_value| {
                            if (id_value == .string and id_value.string.len > 0) {
                                tool_delta.id = try allocator.dupe(u8, id_value.string);
                            }
                        }

                        if (tool_call_obj.get("function")) |function_value| {
                            if (function_value == .object) {
                                const function_obj = function_value.object;
                                if (function_obj.get("name")) |name_value| {
                                    if (name_value == .string and name_value.string.len > 0) {
                                        tool_delta.name = try allocator.dupe(u8, name_value.string);
                                    }
                                }
                                if (function_obj.get("arguments")) |arguments_value| {
                                    if (arguments_value == .string and arguments_value.string.len > 0) {
                                        tool_delta.arguments = try allocator.dupe(u8, arguments_value.string);
                                    }
                                }
                            }
                        }

                        try tool_deltas.append(allocator, tool_delta);
                    }
                }
            }
        }
    }

    var result = SseLineResult{};
    errdefer result.deinit(allocator);

    if (text_builder.items.len > 0) {
        result.text = try text_builder.toOwnedSlice(allocator);
    } else {
        text_builder.deinit(allocator);
    }

    if (reasoning_builder.items.len > 0) {
        result.reasoning = try reasoning_builder.toOwnedSlice(allocator);
    } else {
        reasoning_builder.deinit(allocator);
    }

    if (tool_deltas.items.len > 0) {
        result.tool_call_deltas = try tool_deltas.toOwnedSlice(allocator);
    } else {
        tool_deltas.deinit(allocator);
    }

    // V1.11 hardening (2026-05-07): authoritative usage when the provider
    // emits a final usage chunk. OpenAI-spec shape:
    //   { "usage": {
    //       "prompt_tokens": N, "completion_tokens": N, "total_tokens": N,
    //       "completion_tokens_details": { "reasoning_tokens": N },
    //       "prompt_tokens_details": { "cached_tokens": N }
    //   }}
    // The chunk usually has empty `choices`; we read it independently.
    if (obj.get("usage")) |usage_value| {
        if (usage_value == .object) {
            const usage_obj = usage_value.object;
            var u = SseUsage{};
            if (usage_obj.get("prompt_tokens")) |v| {
                if (v == .integer and v.integer >= 0) u.prompt_tokens = @intCast(v.integer);
            }
            if (usage_obj.get("completion_tokens")) |v| {
                if (v == .integer and v.integer >= 0) u.completion_tokens = @intCast(v.integer);
            }
            if (usage_obj.get("total_tokens")) |v| {
                if (v == .integer and v.integer >= 0) u.total_tokens = @intCast(v.integer);
            }
            // Reasoning tokens — DeepSeek V4-Pro / OpenAI o-series both nest
            // under completion_tokens_details. Some providers (Kimi, Groq)
            // emit reasoning_tokens at the top level.
            if (usage_obj.get("completion_tokens_details")) |details_v| {
                if (details_v == .object) {
                    if (details_v.object.get("reasoning_tokens")) |rt| {
                        if (rt == .integer and rt.integer >= 0) u.reasoning_tokens = @intCast(rt.integer);
                    }
                }
            }
            if (usage_obj.get("reasoning_tokens")) |v| {
                if (v == .integer and v.integer >= 0) u.reasoning_tokens = @intCast(v.integer);
            }
            // Cached tokens for prompt-cache hit accounting (Anthropic-style
            // cache_control reuse, Together prefix-match, etc.)
            if (usage_obj.get("prompt_tokens_details")) |details_v| {
                if (details_v == .object) {
                    if (details_v.object.get("cached_tokens")) |ct| {
                        if (ct == .integer and ct.integer >= 0) u.cached_tokens = @intCast(ct.integer);
                    }
                }
            }
            if (usage_obj.get("cached_tokens")) |v| {
                if (v == .integer and v.integer >= 0) u.cached_tokens = @intCast(v.integer);
            }
            result.usage = u;
        }
    }

    return result;
}

/// Extract `choices[*].delta.content` from an SSE JSON payload.
/// Returns owned slice or null if no content found.
pub fn extractDeltaContent(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    var event = try extractSseEvent(allocator, json_str);
    defer event.deinit(allocator);

    if (event.text) |text| {
        const copy = try allocator.dupe(u8, text);
        return copy;
    }
    return null;
}

/// **R18+SwissWatch (2026-04-28)** — single source of truth for the
/// stream timeout default. Used by both the curl fallback and the
/// native HTTP path. Set generously: 1 hour bounds a TRULY broken
/// connection while never bounding legitimate agent work (SWE-Bench-
/// class autonomous loops can run 30+ minutes on a single inference).
/// Per Nova directive: "we can't time out anything, what if the agent
/// needed to work longer." User explicit override (any non-zero
/// `request.timeout_secs`) still wins.
pub const DEFAULT_STREAM_TIMEOUT_SECS: u64 = 3600;

/// Run curl in SSE streaming mode and parse output line by line.
///
/// Spawns `curl -s --no-buffer --fail-with-body` and reads stdout incrementally.
/// For each SSE delta, calls `callback(ctx, chunk)`.
/// Returns accumulated result after stream completes.
///
/// V1.14.4 F-G1 fix — escape hatch for native TLS crash on Apple Silicon.
///
/// On macOS arm64 (M3 verified, possibly M1/M2 too), Zig 0.15.2's
/// std.crypto.pcurves.p256 hits SIGILL during ECDSA signature
/// verification for some server cert chains (Together's reproduces
/// reliably). Crash report:
///   crypto.pcurves.p256.P256.add → mulPublic → Verifier.verifyPrehashed
///   → crypto.tls.Client.init → http_native.TlsIoState.init
///   → providers.sse.native_stream → exception SIGILL "Address size fault"
///
/// Since SIGILL kills the process before native_stream can RETURN an
/// error, the existing `catch → curl_stream_fallback` never fires.
/// Set `NULLALIS_FORCE_CURL_STREAM=1` to bypass native_stream entirely
/// and route every streaming request through the curl subprocess path,
/// which uses the system's TLS implementation (Apple LibreSSL or
/// equivalent) and avoids the Zig stdlib bug.
///
/// Cost: ~5-10ms extra per request for the curl subprocess fork+exec.
/// Acceptable for booth-week demo and any LLM-bound workload (the LLM
/// roundtrip is 100-30000ms; subprocess overhead is rounding error).
///
/// Long-term: file Zig upstream issue, switch to a maintained TLS
/// library, or wait for Zig 0.16+ stdlib crypto fixes.
pub fn curlStream(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    timeout_secs: u64,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    if (forceCurlStreamPath()) {
        return curl_stream_fallback(allocator, url, body, auth_header, extra_headers, timeout_secs, callback, ctx);
    }
    return native_stream(allocator, url, body, auth_header, extra_headers, timeout_secs, callback, ctx) catch
        return curl_stream_fallback(allocator, url, body, auth_header, extra_headers, timeout_secs, callback, ctx);
}

/// True when the streaming path should be forced through the curl
/// subprocess instead of Zig's native TLS stack.
///
/// V1.14.4 F-G1.5 (booth-week hardening) — auto-default by platform:
///
/// - **macOS arm64 (Apple Silicon)**: defaults to TRUE because Zig
///   0.15.2's std.crypto.pcurves.p256 SIGILLs during ECDSA cert
///   verification on M1/M2/M3 (verified on M3 / Mac15,14; reproduced
///   3× consistently with macOS DiagnosticReports captured). Operators
///   who explicitly want native (e.g. for benchmarking the bug, or
///   after a Zig fix lands) can set `NULLALIS_FORCE_CURL_STREAM=0`.
///
/// - **Other platforms** (Linux x86_64, Linux arm64, macOS x86_64):
///   defaults to FALSE — use native. The SIGILL is Apple Silicon-
///   specific. Operators can opt INTO curl with
///   `NULLALIS_FORCE_CURL_STREAM=1` if they hit issues.
///
/// Cached after first read since neither the env var nor the platform
/// changes per-process. Logged at boot via `logStreamingTransportBanner`
/// so operators see which path is active.
pub fn forceCurlStreamPath() bool {
    const State = struct {
        var checked: bool = false;
        var force: bool = false;
    };
    if (State.checked) return State.force;
    State.checked = true;
    const platform_default: bool = isApplePlatformDefault();
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "NULLALIS_FORCE_CURL_STREAM") catch {
        // No env var set → use platform default
        State.force = platform_default;
        return State.force;
    };
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) {
        State.force = platform_default;
    } else if (value[0] == '0') {
        // Explicit opt-out (works on any platform)
        State.force = false;
    } else {
        // Explicit opt-in
        State.force = true;
    }
    return State.force;
}

/// True if this is macOS arm64, where Zig 0.15.2's TLS stack hits
/// SIGILL during ECDSA verification (F-G1). Comptime check — no
/// runtime cost.
fn isApplePlatformDefault() bool {
    const builtin = @import("builtin");
    return builtin.target.os.tag == .macos and builtin.target.cpu.arch == .aarch64;
}

/// One-shot startup banner — logs which streaming TLS transport is
/// active and why. Called by gateway boot so operators can verify the
/// F-G1 workaround is in effect (or that they explicitly opted out).
pub fn logStreamingTransportBanner() void {
    const force = forceCurlStreamPath();
    const apple_default = isApplePlatformDefault();
    if (force) {
        if (apple_default) {
            std.log.scoped(.sse).info("streaming.tls transport=curl_subprocess reason=apple_silicon_zig_tls_sigill_workaround override_with=NULLALIS_FORCE_CURL_STREAM=0", .{});
        } else {
            std.log.scoped(.sse).info("streaming.tls transport=curl_subprocess reason=operator_opt_in env=NULLALIS_FORCE_CURL_STREAM=1", .{});
        }
    } else {
        std.log.scoped(.sse).info("streaming.tls transport=zig_native reason=platform_default", .{});
    }
}

fn curl_stream_fallback(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    timeout_secs: u64,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    // Build argv on stack (max 32 args)
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "--no-buffer";
    argc += 1;
    argv_buf[argc] = "--fail-with-body";
    argc += 1;

    // R15 fix (2026-04-27): always pass --max-time. Pre-fix curl ran
    // with no limit on timeout_secs=0 → infinite hang on Together hiccup.
    //
    // R18 (2026-04-28, Nova directive): raised default 300s → 3600s
    // (1 hour). Per Nova: "we can't time out anything, what if the
    // agent needed to work longer." For SWE-Bench-class autonomous
    // coding loops, GLM/Kimi can legitimately take 30+ minutes on a
    // single inference. 1 hour is high enough to never block real
    // work, low enough to bound a TRULY broken connection (a hung
    // socket on Together's side).
    //
    // Effectively: this is a "broken connection detector," not a
    // "the agent took too long" cap. If you ever hit 1 hour, something
    // is genuinely wrong upstream — NOT the agent thinking.
    const effective_timeout: u64 = if (timeout_secs > 0) timeout_secs else DEFAULT_STREAM_TIMEOUT_SECS;
    var timeout_buf: [32]u8 = undefined;
    const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{effective_timeout}) catch unreachable;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = timeout_str;
    argc += 1;

    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Content-Type: application/json";
    argc += 1;

    if (auth_header) |auth| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = auth;
        argc += 1;
    }

    for (extra_headers) |hdr| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = "-d";
    argc += 1;
    argv_buf[argc] = body;
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    var stream_ctx = OpenAiStreamCtx{
        .allocator = allocator,
        .callback = callback,
        .callback_ctx = ctx,
    };
    defer stream_ctx.deinit();

    const file = child.stdout.?;
    var read_buf: [4096]u8 = undefined;
    var saw_done = false;

    outer: while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;

        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                const keep_streaming = handleOpenAiLine(&stream_ctx) catch {
                    stream_ctx.line_buf.clearRetainingCapacity();
                    continue;
                };
                if (!keep_streaming) {
                    saw_done = true;
                    break :outer;
                }
            } else {
                try stream_ctx.line_buf.append(allocator, byte);
            }
        }
    }

    // Parse a trailing line when the stream ends without a final '\n'.
    if (!saw_done and stream_ctx.line_buf.items.len > 0) {
        _ = handleOpenAiLine(&stream_ctx) catch {
            stream_ctx.line_buf.clearRetainingCapacity();
        };
    }

    // Drain remaining stdout to prevent deadlock on wait()
    while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
    }

    const term = child.wait() catch return error.CurlWaitError;
    switch (term) {
        .Exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }

    return finalizeOpenAiStream(&stream_ctx);
}

const ToolCallAccumulator = struct {
    id: std.ArrayListUnmanaged(u8) = .empty,
    name: std.ArrayListUnmanaged(u8) = .empty,
    arguments: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *ToolCallAccumulator, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

const OpenAiStreamCtx = struct {
    allocator: std.mem.Allocator,
    callback: root.StreamCallback,
    callback_ctx: *anyopaque,
    accumulated: std.ArrayListUnmanaged(u8) = .empty,
    /// Reasoning / thinking deltas accumulated across the stream. Surfaced
    /// on `StreamChatResult.reasoning_content` when the stream finalizes.
    reasoning_accumulated: std.ArrayListUnmanaged(u8) = .empty,
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    tool_call_accumulators: std.ArrayListUnmanaged(ToolCallAccumulator) = .empty,
    /// V1.11 hardening (2026-05-07): authoritative usage from the provider's
    /// final stream chunk (when stream_options.include_usage=true was sent).
    /// null = provider didn't emit usage; finalize falls back to char-count
    /// estimation as before.
    stream_usage: ?SseUsage = null,
    stream_tool_call_chunks: u32 = 0,

    /// Live-stream XML tool-call suppression state. When the model falls back
    /// to emitting `<invoke>`/`<tool_call>` XML inside content (Kimi K2.5
    /// regression, 2026-04-19), we don't want those tokens to flash live on
    /// the user's screen. This state lets processSseEvent filter the text
    /// deltas pushed to the user-facing callback. The full text still
    /// accumulates in `accumulated` for post-stream parseToolCalls — only
    /// the VISUAL stream is filtered.
    xml_suppress_depth: u32 = 0,
    xml_tail: [15]u8 = undefined,
    xml_tail_len: usize = 0,
    task_plan_residue_guard: usize = 0,

    fn deinit(self: *OpenAiStreamCtx) void {
        self.accumulated.deinit(self.allocator);
        self.reasoning_accumulated.deinit(self.allocator);
        self.line_buf.deinit(self.allocator);
        for (self.tool_call_accumulators.items) |*accumulator| {
            accumulator.deinit(self.allocator);
        }
        self.tool_call_accumulators.deinit(self.allocator);
    }
};

/// Filter a text delta chunk so that content inside internal XML blocks does
/// not reach the live user-facing callback. Covers tool-call fallback markup
/// and backend-private `<task_plan>...</task_plan>` planning blocks. The
/// filtering is stateful across chunks using
/// `xml_tail` as carry-over (since an opening tag may be split across
/// chunk boundaries). Returns a slice into `scratch` containing the
/// filtered text to emit.
fn filterLiveXmlBlocks(
    ctx: *OpenAiStreamCtx,
    chunk: []const u8,
    scratch: *std.ArrayListUnmanaged(u8),
) ![]const u8 {
    scratch.clearRetainingCapacity();

    // Work off carry + chunk to catch tags split across chunk boundaries.
    const carry_slice = ctx.xml_tail[0..ctx.xml_tail_len];
    var work: std.ArrayListUnmanaged(u8) = .empty;
    defer work.deinit(ctx.allocator);
    try work.appendSlice(ctx.allocator, carry_slice);
    try work.appendSlice(ctx.allocator, chunk);
    const buf = work.items;

    // We must hold back the last up-to-15 bytes so we don't emit a partial
    // opening/closing tag mid-detection. The held-back portion becomes the
    // new carry for the next chunk.
    const hold_back: usize = @min(buf.len, 15);
    const scan_end: usize = buf.len - hold_back;

    var i: usize = 0;
    while (i < scan_end) {
        if (ctx.xml_suppress_depth == 0) {
            const residue_len = taskPlanResiduePrefixLen(buf[i..], ctx.task_plan_residue_guard > 0);
            if (residue_len > 0) {
                i += residue_len;
                ctx.task_plan_residue_guard = 32;
                continue;
            }
            if (std.mem.startsWith(u8, buf[i..], "<invoke ") or
                std.mem.startsWith(u8, buf[i..], "<tool_call>") or
                std.mem.startsWith(u8, buf[i..], "<task_plan>"))
            {
                ctx.xml_suppress_depth += 1;
                if (std.mem.startsWith(u8, buf[i..], "<invoke ")) {
                    i += "<invoke ".len;
                } else if (std.mem.startsWith(u8, buf[i..], "<task_plan>")) {
                    ctx.task_plan_residue_guard = 32;
                    i += "<task_plan>".len;
                } else {
                    i += "<tool_call>".len;
                }
                continue;
            }
            try scratch.append(ctx.allocator, buf[i]);
            if (ctx.task_plan_residue_guard > 0) ctx.task_plan_residue_guard -= 1;
            i += 1;
        } else {
            if (std.mem.startsWith(u8, buf[i..], "</invoke>")) {
                ctx.xml_suppress_depth -|= 1;
                i += "</invoke>".len;
                continue;
            }
            if (std.mem.startsWith(u8, buf[i..], "</tool_call>")) {
                ctx.xml_suppress_depth -|= 1;
                i += "</tool_call>".len;
                continue;
            }
            if (std.mem.startsWith(u8, buf[i..], "</task_plan>")) {
                ctx.xml_suppress_depth -|= 1;
                ctx.task_plan_residue_guard = 32;
                i += "</task_plan>".len;
                continue;
            }
            // Character inside suppression block — drop it.
            i += 1;
        }
    }

    // Save the hold-back portion as next carry.
    const carry_start = if (i > scan_end) @min(i, buf.len) else scan_end;
    const new_carry = buf[carry_start..];
    if (new_carry.len > ctx.xml_tail.len) {
        // Shouldn't happen because hold_back <= 15, but be defensive.
        const start = new_carry.len - ctx.xml_tail.len;
        @memcpy(ctx.xml_tail[0..], new_carry[start..]);
        ctx.xml_tail_len = ctx.xml_tail.len;
    } else {
        @memcpy(ctx.xml_tail[0..new_carry.len], new_carry);
        ctx.xml_tail_len = new_carry.len;
    }

    return scratch.items;
}

fn taskPlanResiduePrefixLen(buf: []const u8, allow_tiny_tail: bool) usize {
    const residues = [_][]const u8{
        "</task_plan>",
        "/task_plan>",
        "task_plan>",
        "ask_plan>",
        "sk_plan>",
        "k_plan>",
        "_plan>",
        "plan>",
    };
    for (residues) |residue| {
        if (std.mem.startsWith(u8, buf, residue)) return residue.len;
    }
    if (allow_tiny_tail) {
        const tiny_residues = [_][]const u8{
            "lan>",
            "an>",
            "n>",
            ">",
        };
        for (tiny_residues) |residue| {
            if (std.mem.startsWith(u8, buf, residue)) return residue.len;
        }
    }
    return 0;
}

/// On stream finalize, flush the xml_tail carry-over through the filter
/// so any tail bytes that aren't part of a pending tag get emitted. Since
/// there's no more data coming, scan the entire tail (hold_back = 0) and
/// emit anything not in a suppression block.
fn flushLiveXmlTail(
    ctx: *OpenAiStreamCtx,
    scratch: *std.ArrayListUnmanaged(u8),
) ![]const u8 {
    scratch.clearRetainingCapacity();
    const buf = ctx.xml_tail[0..ctx.xml_tail_len];
    var i: usize = 0;
    while (i < buf.len) {
        if (ctx.xml_suppress_depth == 0) {
            const residue_len = taskPlanResiduePrefixLen(buf[i..], ctx.task_plan_residue_guard > 0);
            if (residue_len > 0) {
                i += residue_len;
                ctx.task_plan_residue_guard = 32;
                continue;
            }
            if (std.mem.startsWith(u8, buf[i..], "<invoke ") or
                std.mem.startsWith(u8, buf[i..], "<tool_call>") or
                std.mem.startsWith(u8, buf[i..], "<task_plan>"))
            {
                ctx.xml_suppress_depth += 1;
                if (std.mem.startsWith(u8, buf[i..], "<invoke ")) {
                    i += "<invoke ".len;
                } else if (std.mem.startsWith(u8, buf[i..], "<task_plan>")) {
                    ctx.task_plan_residue_guard = 32;
                    i += "<task_plan>".len;
                } else {
                    i += "<tool_call>".len;
                }
                continue;
            }
            try scratch.append(ctx.allocator, buf[i]);
            if (ctx.task_plan_residue_guard > 0) ctx.task_plan_residue_guard -= 1;
            i += 1;
        } else {
            if (std.mem.startsWith(u8, buf[i..], "</invoke>")) {
                ctx.xml_suppress_depth -|= 1;
                i += "</invoke>".len;
                continue;
            }
            if (std.mem.startsWith(u8, buf[i..], "</tool_call>")) {
                ctx.xml_suppress_depth -|= 1;
                i += "</tool_call>".len;
                continue;
            }
            if (std.mem.startsWith(u8, buf[i..], "</task_plan>")) {
                ctx.xml_suppress_depth -|= 1;
                ctx.task_plan_residue_guard = 32;
                i += "</task_plan>".len;
                continue;
            }
            i += 1;
        }
    }
    ctx.xml_tail_len = 0;
    ctx.task_plan_residue_guard = 0;
    return scratch.items;
}

fn ensureToolCallAccumulator(
    allocator: std.mem.Allocator,
    accumulators: *std.ArrayListUnmanaged(ToolCallAccumulator),
    index: usize,
) !*ToolCallAccumulator {
    while (accumulators.items.len <= index) {
        try accumulators.append(allocator, .{});
    }
    return &accumulators.items[index];
}

fn appendToolCallDelta(ctx: *OpenAiStreamCtx, delta: SseToolCallDelta) !void {
    const accumulator = try ensureToolCallAccumulator(ctx.allocator, &ctx.tool_call_accumulators, delta.index);
    if (delta.id) |id| try accumulator.id.appendSlice(ctx.allocator, id);
    if (delta.name) |name| try accumulator.name.appendSlice(ctx.allocator, name);
    if (delta.arguments) |arguments| try accumulator.arguments.appendSlice(ctx.allocator, arguments);
}

fn processSseEvent(ctx: *OpenAiStreamCtx, event: SseLineResult) !bool {
    defer event.deinit(ctx.allocator);

    // V1.11 hardening (2026-05-07): capture authoritative usage when the
    // provider emits the OpenAI-spec usage chunk (stream_options.include_usage
    // was set). This chunk often arrives BEFORE [DONE], with empty choices,
    // so we record it regardless of done state.
    if (event.usage) |u| ctx.stream_usage = u;

    if (event.done) return false;

    if (event.text) |text| {
        // Full-text accumulation is unfiltered — post-stream parseToolCalls
        // still needs to see the raw XML to extract tool invocations.
        try ctx.accumulated.appendSlice(ctx.allocator, text);

        // The user-facing stream IS filtered — suppress `<invoke>…</invoke>`
        // and `<tool_call>…</tool_call>` blocks so the user doesn't see raw
        // XML flash on their screen when the model falls back to emitting
        // tool calls as content (Kimi K2.5 regression).
        var scratch: std.ArrayListUnmanaged(u8) = .empty;
        defer scratch.deinit(ctx.allocator);
        const filtered = try filterLiveXmlBlocks(ctx, text, &scratch);
        if (filtered.len > 0) {
            ctx.callback(ctx.callback_ctx, root.StreamChunk.textDelta(filtered));
        }
    }

    // Accumulate reasoning deltas. Not forwarded to the live streaming
    // callback yet — the callback is the reply-text channel. Reasoning is
    // surfaced on `StreamChatResult.reasoning_content` at finalize and
    // emitted by the agent loop as a `.narration_frame .thinking` observer
    // event, which the gateway routes into the SSE reasoning_summary stream.
    if (event.reasoning) |reasoning| {
        try ctx.reasoning_accumulated.appendSlice(ctx.allocator, reasoning);
    }

    for (event.tool_call_deltas) |delta| {
        try appendToolCallDelta(ctx, delta);
    }
    if (event.tool_call_deltas.len > 0) {
        ctx.stream_tool_call_chunks += @intCast(@min(event.tool_call_deltas.len, std.math.maxInt(u32) - ctx.stream_tool_call_chunks));
    }

    return true;
}

fn handleOpenAiLine(ctx: *OpenAiStreamCtx) !bool {
    const event = try parseSseLine(ctx.allocator, ctx.line_buf.items);
    ctx.line_buf.clearRetainingCapacity();
    return processSseEvent(ctx, event);
}

fn buildToolCalls(
    allocator: std.mem.Allocator,
    accumulators: []const ToolCallAccumulator,
) ![]const root.ToolCall {
    var calls: std.ArrayListUnmanaged(root.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        calls.deinit(allocator);
    }

    for (accumulators, 0..) |accumulator, index| {
        if (accumulator.name.items.len == 0) {
            // A streamed tool_call delta arrived without a name ever appearing
            // in any of its deltas. This should not happen with well-behaved
            // providers but has been observed as a silent drop in the past.
            // Log it so a "tools unreliable" report has a trail to follow.
            if (accumulator.id.items.len > 0 or accumulator.arguments.items.len > 0) {
                std.log.scoped(.sse).warn(
                    "sse.buildToolCalls: dropping tool_call at index={d} with empty name (id_len={d} args_len={d}) — provider emitted partial deltas",
                    .{ index, accumulator.id.items.len, accumulator.arguments.items.len },
                );
            }
            continue;
        }

        {
            const id = if (accumulator.id.items.len > 0)
                try allocator.dupe(u8, accumulator.id.items)
            else
                try std.fmt.allocPrint(allocator, "call_{d}", .{index});
            errdefer allocator.free(id);

            const name = try allocator.dupe(u8, accumulator.name.items);
            errdefer allocator.free(name);

            const arguments = if (accumulator.arguments.items.len > 0)
                try allocator.dupe(u8, accumulator.arguments.items)
            else
                try allocator.dupe(u8, "{}");
            errdefer allocator.free(arguments);

            try calls.append(allocator, .{
                .id = id,
                .name = name,
                .arguments = arguments,
            });
        }
    }

    if (calls.items.len == 0) {
        calls.deinit(allocator);
        return &.{};
    }

    return try calls.toOwnedSlice(allocator);
}

fn finalizeOpenAiStream(ctx: *OpenAiStreamCtx) !root.StreamChatResult {
    // Flush any carry-over bytes held back for mid-chunk tag detection.
    // Without this, the final few chars of prose never reach the user.
    if (ctx.xml_tail_len > 0) {
        var scratch: std.ArrayListUnmanaged(u8) = .empty;
        defer scratch.deinit(ctx.allocator);
        const flushed = try flushLiveXmlTail(ctx, &scratch);
        if (flushed.len > 0) {
            ctx.callback(ctx.callback_ctx, root.StreamChunk.textDelta(flushed));
        }
    }
    ctx.callback(ctx.callback_ctx, root.StreamChunk.finalChunk());

    // V1.11 hardening (2026-05-07): prefer authoritative provider-emitted
    // usage over the char-count heuristic. Only fall back to estimation
    // when stream_options.include_usage was rejected or the provider didn't
    // honor it. The estimate was off by 30-50% on reasoning-heavy turns,
    // which made pricing.zig cost attribution unreliable and the entitlement
    // monthly_weight_budget enforcement effectively blind.
    const usage_out: root.TokenUsage = if (ctx.stream_usage) |u| .{
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .total_tokens = if (u.total_tokens > 0) u.total_tokens else (u.prompt_tokens + u.completion_tokens),
        .reasoning_tokens = u.reasoning_tokens,
        .cached_prompt_tokens = u.cached_tokens,
    } else .{
        .completion_tokens = @intCast((ctx.accumulated.items.len + 3) / 4),
    };

    return .{
        .content = if (ctx.accumulated.items.len > 0) try ctx.allocator.dupe(u8, ctx.accumulated.items) else null,
        .reasoning_content = if (ctx.reasoning_accumulated.items.len > 0)
            try ctx.allocator.dupe(u8, ctx.reasoning_accumulated.items)
        else
            null,
        .tool_calls = try buildToolCalls(ctx.allocator, ctx.tool_call_accumulators.items),
        .usage = usage_out,
        .model = "",
        .stream_tool_call_chunks = ctx.stream_tool_call_chunks,
    };
}

// ── Live-stream XML filter tests ─────────────────────────────────────

fn captureTextDelta(cb_ctx: *anyopaque, chunk: root.StreamChunk) void {
    const buf: *std.ArrayListUnmanaged(u8) = @ptrCast(@alignCast(cb_ctx));
    if (chunk.is_final) return;
    if (chunk.delta.len == 0) return;
    buf.appendSlice(std.testing.allocator, chunk.delta) catch return;
}

test "stream filter strips a single complete <invoke> block" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var ctx = OpenAiStreamCtx{
        .allocator = std.testing.allocator,
        .callback = captureTextDelta,
        .callback_ctx = @ptrCast(&captured),
    };
    defer ctx.deinit();

    // Simulate the full text arriving as one chunk.
    const chunk =
        \\I'll check now.
        \\<invoke name="runtime_info">
        \\{"section":"summary"}
        \\</invoke>
        \\Done.
    ;
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const filtered = try filterLiveXmlBlocks(&ctx, chunk, &scratch);
    try captured.appendSlice(std.testing.allocator, filtered);
    // Flush the carry at end-of-stream.
    const tail = try flushLiveXmlTail(&ctx, &scratch);
    try captured.appendSlice(std.testing.allocator, tail);

    try std.testing.expect(std.mem.indexOf(u8, captured.items, "<invoke") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "I'll check now") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Done.") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "runtime_info") == null);
}

test "stream filter strips <tool_call> block" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var ctx = OpenAiStreamCtx{
        .allocator = std.testing.allocator,
        .callback = captureTextDelta,
        .callback_ctx = @ptrCast(&captured),
    };
    defer ctx.deinit();

    const chunk =
        \\Before.
        \\<tool_call>
        \\{"name":"shell","arguments":{"command":"ls"}}
        \\</tool_call>
        \\After.
    ;
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const filtered = try filterLiveXmlBlocks(&ctx, chunk, &scratch);
    try captured.appendSlice(std.testing.allocator, filtered);
    const tail = try flushLiveXmlTail(&ctx, &scratch);
    try captured.appendSlice(std.testing.allocator, tail);

    try std.testing.expect(std.mem.indexOf(u8, captured.items, "<tool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "</tool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Before.") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "After.") != null);
}

test "stream filter strips internal <task_plan> block split across chunks" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var ctx = OpenAiStreamCtx{
        .allocator = std.testing.allocator,
        .callback = captureTextDelta,
        .callback_ctx = @ptrCast(&captured),
    };
    defer ctx.deinit();

    const chunks = [_][]const u8{
        "Thinking.\n<task_",
        "plan><summary>Private plan</summary><step>Call schedule</step></task_",
        "plan>\nVisible summary.",
    };
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    for (chunks) |chunk| {
        const filtered = try filterLiveXmlBlocks(&ctx, chunk, &scratch);
        try captured.appendSlice(std.testing.allocator, filtered);
    }
    const tail = try flushLiveXmlTail(&ctx, &scratch);
    try captured.appendSlice(std.testing.allocator, tail);

    try std.testing.expect(std.mem.indexOf(u8, captured.items, "<task_plan>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "</task_plan>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "/task_plan>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "sk_plan>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Private plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Thinking.") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Visible summary.") != null);
}

test "stream filter does not replay consumed task_plan closing suffix" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var ctx = OpenAiStreamCtx{
        .allocator = std.testing.allocator,
        .callback = captureTextDelta,
        .callback_ctx = @ptrCast(&captured),
    };
    defer ctx.deinit();

    const chunks = [_][]const u8{
        "<task_plan><summary>Private plan</summary></task_pla",
        "n>Visible summary.",
    };
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    for (chunks) |chunk| {
        const filtered = try filterLiveXmlBlocks(&ctx, chunk, &scratch);
        try captured.appendSlice(std.testing.allocator, filtered);
    }
    const tail = try flushLiveXmlTail(&ctx, &scratch);
    try captured.appendSlice(std.testing.allocator, tail);

    try std.testing.expect(std.mem.indexOf(u8, captured.items, "</task_plan>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "n>Visible") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Private plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Visible summary.") != null);
}

test "stream filter handles tag split across chunk boundary" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var ctx = OpenAiStreamCtx{
        .allocator = std.testing.allocator,
        .callback = captureTextDelta,
        .callback_ctx = @ptrCast(&captured),
    };
    defer ctx.deinit();

    // Chunks deliberately split in the middle of `<invoke ` and `</invoke>`.
    const chunks = [_][]const u8{
        "Hello <inv",
        "oke name=\"x\">{}</inv",
        "oke> done",
    };
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    for (chunks) |chunk| {
        const filtered = try filterLiveXmlBlocks(&ctx, chunk, &scratch);
        try captured.appendSlice(std.testing.allocator, filtered);
    }
    const tail = try flushLiveXmlTail(&ctx, &scratch);
    try captured.appendSlice(std.testing.allocator, tail);

    try std.testing.expect(std.mem.indexOf(u8, captured.items, "<invoke") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "</invoke>") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "done") != null);
}

test "stream filter passes prose through unchanged when no tags present" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var ctx = OpenAiStreamCtx{
        .allocator = std.testing.allocator,
        .callback = captureTextDelta,
        .callback_ctx = @ptrCast(&captured),
    };
    defer ctx.deinit();

    const chunk = "This is just prose with no XML tags in it at all.";
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const filtered = try filterLiveXmlBlocks(&ctx, chunk, &scratch);
    try captured.appendSlice(std.testing.allocator, filtered);
    const tail = try flushLiveXmlTail(&ctx, &scratch);
    try captured.appendSlice(std.testing.allocator, tail);

    try std.testing.expectEqualStrings(chunk, captured.items);
}

fn native_openai_chunk(ctx: *OpenAiStreamCtx, bytes: []const u8) anyerror!bool {
    for (bytes) |byte| {
        if (byte == '\n') {
            const keep_streaming = handleOpenAiLine(ctx) catch {
                ctx.line_buf.clearRetainingCapacity();
                continue;
            };
            if (!keep_streaming) return false;
        } else {
            try ctx.line_buf.append(ctx.allocator, byte);
        }
    }
    return true;
}

fn native_stream(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    timeout_secs: u64,
    callback: root.StreamCallback,
    callback_ctx: *anyopaque,
) !root.StreamChatResult {
    var headers_buf: [8][]const u8 = undefined;
    var header_count: usize = 0;
    headers_buf[header_count] = "Accept: text/event-stream";
    header_count += 1;
    headers_buf[header_count] = "Content-Type: application/json";
    header_count += 1;
    if (auth_header) |auth| {
        headers_buf[header_count] = auth;
        header_count += 1;
    }
    for (extra_headers) |hdr| {
        headers_buf[header_count] = hdr;
        header_count += 1;
    }

    var stream_ctx = OpenAiStreamCtx{
        .allocator = allocator,
        .callback = callback,
        .callback_ctx = callback_ctx,
    };
    defer stream_ctx.deinit();

    // R15 fix (2026-04-27): bumped from 30s → 300s for deep reasoning.
    // R18 (2026-04-28, Nova directive): 300s → 3600s (1 hour). Same
    // rationale as the curl path above — bound a broken connection,
    // never bound legitimate agent work. SWE-Bench-class autonomous
    // loops can legitimately take 30+ minutes.
    const timeout_ms: u32 = if (timeout_secs == 0) @intCast(DEFAULT_STREAM_TIMEOUT_SECS * 1000) else @intCast(@min(timeout_secs * 1000, std.math.maxInt(u32)));
    const status_code = try http_native.stream_body(
        allocator,
        .{
            .method = "POST",
            .url = url,
            .headers = headers_buf[0..header_count],
            .body = body,
            .timeout_ms = timeout_ms,
            .max_response_bytes = 8 * 1024 * 1024,
            .subsystem = .providers,
        },
        &stream_ctx,
        native_openai_chunk,
    );

    if (status_code < 200 or status_code >= 300) return error.CurlFailed;

    if (stream_ctx.line_buf.items.len > 0) {
        _ = handleOpenAiLine(&stream_ctx) catch {
            stream_ctx.line_buf.clearRetainingCapacity();
        };
    }

    return finalizeOpenAiStream(&stream_ctx);
}

// ════════════════════════════════════════════════════════════════════════════
// Anthropic SSE Parsing
// ════════════════════════════════════════════════════════════════════════════

/// Result of parsing a single Anthropic SSE line.
pub const AnthropicSseResult = union(enum) {
    /// Remember this event type (caller tracks state).
    event: []const u8,
    /// Text delta content (owned, caller frees).
    delta: []const u8,
    /// Output token count from message_delta usage.
    usage: u32,
    /// Stream is complete (message_stop).
    done: void,
    /// Line should be skipped (empty, comment, or uninteresting event).
    skip: void,
};

/// Parse a single SSE line in Anthropic streaming format.
///
/// Anthropic SSE is stateful: `event:` lines set the context for subsequent `data:` lines.
/// The caller must track `current_event` across calls.
///
/// - `event: X` → `.event` (caller remembers X)
/// - `data: {JSON}` + current_event=="content_block_delta" → extracts `delta.text` → `.delta`
/// - `data: {JSON}` + current_event=="message_delta" → extracts `usage.output_tokens` → `.usage`
/// - `data: {JSON}` + current_event=="message_stop" → `.done`
/// - Everything else → `.skip`
pub fn parseAnthropicSseLine(allocator: std.mem.Allocator, line: []const u8, current_event: []const u8) !AnthropicSseResult {
    const trimmed = std.mem.trimRight(u8, line, "\r");

    if (trimmed.len == 0) return .skip;
    if (trimmed[0] == ':') return .skip;

    // Handle "event: TYPE" lines
    const event_prefix = "event: ";
    if (std.mem.startsWith(u8, trimmed, event_prefix)) {
        return .{ .event = trimmed[event_prefix.len..] };
    }

    // Handle "data: {JSON}" lines
    const data = extractSseDataPayload(trimmed) orelse return .skip;

    if (std.mem.eql(u8, current_event, "message_stop")) return .done;

    if (std.mem.eql(u8, current_event, "content_block_delta")) {
        const text = try extractAnthropicDelta(allocator, data) orelse return .skip;
        return .{ .delta = text };
    }

    if (std.mem.eql(u8, current_event, "message_delta")) {
        const tokens = try extractAnthropicUsage(data) orelse return .skip;
        return .{ .usage = tokens };
    }

    return .skip;
}

/// Extract `delta.text` from an Anthropic content_block_delta JSON payload.
/// Returns owned slice or null if not a text_delta.
pub fn extractAnthropicDelta(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const delta = obj.get("delta") orelse return null;
    if (delta != .object) return null;

    const dtype = delta.object.get("type") orelse return null;
    if (dtype != .string or !std.mem.eql(u8, dtype.string, "text_delta")) return null;

    const text = delta.object.get("text") orelse return null;
    if (text != .string) return null;
    if (text.string.len == 0) return null;

    return try allocator.dupe(u8, text.string);
}

/// Extract `usage.output_tokens` from an Anthropic message_delta JSON payload.
/// Returns token count or null if not present.
pub fn extractAnthropicUsage(json_str: []const u8) !?u32 {
    // Use a stack buffer for parsing to avoid needing an allocator
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const usage = obj.get("usage") orelse return null;
    if (usage != .object) return null;

    const output_tokens = usage.object.get("output_tokens") orelse return null;
    if (output_tokens != .integer) return null;

    return @intCast(output_tokens.integer);
}

/// Run curl in SSE streaming mode for Anthropic and parse output line by line.
///
/// Similar to `curlStream()` but uses stateful Anthropic SSE parsing.
/// `headers` is a slice of pre-formatted header strings (e.g. "x-api-key: sk-...").
///
/// V1.14.4 F-G1 — same `NULLALIS_FORCE_CURL_STREAM` escape hatch as
/// `curlStream` above. The Anthropic native_stream path uses the
/// same Zig stdlib TLS that crashes with SIGILL on Apple Silicon.
pub fn curlStreamAnthropic(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    if (forceCurlStreamPath()) {
        return curl_stream_anthropic_fallback(allocator, url, body, headers, callback, ctx);
    }
    return native_stream_anthropic(allocator, url, body, headers, callback, ctx) catch
        return curl_stream_anthropic_fallback(allocator, url, body, headers, callback, ctx);
}

fn curl_stream_anthropic_fallback(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    // Build argv on stack (max 32 args)
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "--no-buffer";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Content-Type: application/json";
    argc += 1;

    for (headers) |hdr| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = "-d";
    argc += 1;
    argv_buf[argc] = body;
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Read stdout line by line, parse Anthropic SSE events
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    var current_event: []const u8 = "";
    var output_tokens: u32 = 0;

    const file = child.stdout.?;
    var read_buf: [4096]u8 = undefined;

    outer: while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;

        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                const result = parseAnthropicSseLine(allocator, line_buf.items, current_event) catch {
                    line_buf.clearRetainingCapacity();
                    continue;
                };
                switch (result) {
                    .event => |ev| {
                        // Dupe event name — it points into line_buf which we're about to clear
                        if (current_event.len > 0) allocator.free(@constCast(current_event));
                        current_event = allocator.dupe(u8, ev) catch "";
                    },
                    .delta => |text| {
                        defer allocator.free(text);
                        try accumulated.appendSlice(allocator, text);
                        callback(ctx, root.StreamChunk.textDelta(text));
                    },
                    .usage => |tokens| output_tokens = tokens,
                    .done => {
                        line_buf.clearRetainingCapacity();
                        break :outer;
                    },
                    .skip => {},
                }
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Free owned event string
    if (current_event.len > 0) allocator.free(@constCast(current_event));

    // Send final chunk
    callback(ctx, root.StreamChunk.finalChunk());

    // Drain remaining stdout to prevent deadlock on wait()
    while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
    }

    const term = child.wait() catch return error.CurlWaitError;
    switch (term) {
        .Exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }

    const content = if (accumulated.items.len > 0)
        try allocator.dupe(u8, accumulated.items)
    else
        null;

    // Use actual output_tokens if reported, otherwise estimate
    const completion_tokens = if (output_tokens > 0)
        output_tokens
    else
        @as(u32, @intCast((accumulated.items.len + 3) / 4));

    return .{
        .content = content,
        .usage = .{ .completion_tokens = completion_tokens },
        .model = "",
    };
}

const AnthropicStreamCtx = struct {
    allocator: std.mem.Allocator,
    callback: root.StreamCallback,
    callback_ctx: *anyopaque,
    accumulated: std.ArrayListUnmanaged(u8) = .empty,
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    current_event: []const u8 = "",
    output_tokens: u32 = 0,

    fn deinit(self: *AnthropicStreamCtx) void {
        if (self.current_event.len > 0) self.allocator.free(@constCast(self.current_event));
        self.accumulated.deinit(self.allocator);
        self.line_buf.deinit(self.allocator);
    }
};

fn native_anthropic_chunk(ctx: *AnthropicStreamCtx, bytes: []const u8) anyerror!bool {
    for (bytes) |byte| {
        if (byte == '\n') {
            const result = parseAnthropicSseLine(ctx.allocator, ctx.line_buf.items, ctx.current_event) catch {
                ctx.line_buf.clearRetainingCapacity();
                continue;
            };
            switch (result) {
                .event => |ev| {
                    if (ctx.current_event.len > 0) ctx.allocator.free(@constCast(ctx.current_event));
                    ctx.current_event = ctx.allocator.dupe(u8, ev) catch "";
                },
                .delta => |text| {
                    defer ctx.allocator.free(text);
                    try ctx.accumulated.appendSlice(ctx.allocator, text);
                    ctx.callback(ctx.callback_ctx, root.StreamChunk.textDelta(text));
                },
                .usage => |tokens| ctx.output_tokens = tokens,
                .done => {
                    ctx.line_buf.clearRetainingCapacity();
                    return false;
                },
                .skip => {},
            }
            ctx.line_buf.clearRetainingCapacity();
        } else {
            try ctx.line_buf.append(ctx.allocator, byte);
        }
    }
    return true;
}

fn native_stream_anthropic(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: root.StreamCallback,
    callback_ctx: *anyopaque,
) !root.StreamChatResult {
    var headers_buf: [8][]const u8 = undefined;
    var header_count: usize = 0;
    headers_buf[header_count] = "Accept: text/event-stream";
    header_count += 1;
    headers_buf[header_count] = "Content-Type: application/json";
    header_count += 1;
    for (headers) |hdr| {
        headers_buf[header_count] = hdr;
        header_count += 1;
    }

    var stream_ctx = AnthropicStreamCtx{
        .allocator = allocator,
        .callback = callback,
        .callback_ctx = callback_ctx,
    };
    defer stream_ctx.deinit();

    const status_code = try http_native.stream_body(
        allocator,
        .{
            .method = "POST",
            .url = url,
            .headers = headers_buf[0..header_count],
            .body = body,
            .timeout_ms = 30_000,
            .max_response_bytes = 8 * 1024 * 1024,
            .subsystem = .providers,
        },
        &stream_ctx,
        native_anthropic_chunk,
    );

    if (status_code < 200 or status_code >= 300) return error.CurlFailed;

    callback(callback_ctx, root.StreamChunk.finalChunk());
    const completion_tokens = if (stream_ctx.output_tokens > 0)
        stream_ctx.output_tokens
    else
        @as(u32, @intCast((stream_ctx.accumulated.items.len + 3) / 4));

    return .{
        .content = if (stream_ctx.accumulated.items.len > 0) try allocator.dupe(u8, stream_ctx.accumulated.items) else null,
        .usage = .{ .completion_tokens = completion_tokens },
        .model = "",
    };
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "parseSseLine valid delta" {
    const allocator = std.testing.allocator;
    const result = try parseSseLine(allocator, "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}");
    defer result.deinit(allocator);
    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("Hello", result.text.?);
    try std.testing.expectEqual(@as(usize, 0), result.tool_call_deltas.len);
    try std.testing.expect(!result.done);
}

test "parseSseLine supports data prefix without trailing space" {
    const allocator = std.testing.allocator;
    const result = try parseSseLine(allocator, "data:{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}");
    defer result.deinit(allocator);
    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("Hello", result.text.?);
}

test "parseSseLine extracts tool call delta" {
    const allocator = std.testing.allocator;
    const result = try parseSseLine(allocator, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"function\":{\"name\":\"web_search\",\"arguments\":\"{\\\"query\\\":\\\"hrs\\\"}\"}}]}}]}");
    defer result.deinit(allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_call_deltas.len);
    try std.testing.expectEqual(@as(usize, 0), result.tool_call_deltas[0].index);
    try std.testing.expectEqualStrings("call_abc", result.tool_call_deltas[0].id.?);
    try std.testing.expectEqualStrings("web_search", result.tool_call_deltas[0].name.?);
    try std.testing.expectEqualStrings("{\"query\":\"hrs\"}", result.tool_call_deltas[0].arguments.?);
}

test "parseSseLine DONE sentinel" {
    const result = try parseSseLine(std.testing.allocator, "data: [DONE]");
    try std.testing.expect(result.done);
}

test "parseSseLine empty line" {
    const result = try parseSseLine(std.testing.allocator, "");
    try std.testing.expect(result.isSkip());
}

test "parseSseLine comment" {
    const result = try parseSseLine(std.testing.allocator, ":keep-alive");
    try std.testing.expect(result.isSkip());
}

test "parseSseLine delta without content" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[{\"delta\":{}}]}");
    try std.testing.expect(result.isSkip());
}

test "parseSseLine empty choices" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[]}");
    try std.testing.expect(result.isSkip());
}

test "parseSseLine invalid JSON" {
    try std.testing.expectError(error.InvalidSseJson, parseSseLine(std.testing.allocator, "data: not-json{{{"));
}

test "extractSseEvent rejects unparseable JSON cleanly (no leak)" {
    // V1 close-out 2026-04-30 — the audit flagged extractSseEvent as having
    // zero direct tests despite being on the hot path between curlStream
    // and the OpenAI/Anthropic ctx. Pin error.InvalidSseJson on bad input.
    try std.testing.expectError(
        error.InvalidSseJson,
        extractSseEvent(std.testing.allocator, "{not valid json"),
    );
    try std.testing.expectError(
        error.InvalidSseJson,
        extractSseEvent(std.testing.allocator, ""),
    );
}

test "extractSseEvent treats valid JSON array as skip (no error, no leak)" {
    // Defensive: provider could send `["chunk"]` or other non-object JSON.
    // Contract is "treat as skip," not "error" — pin that so a refactor to
    // strict-typing doesn't accidentally start erroring on benign input.
    const result = try extractSseEvent(std.testing.allocator, "[\"array-not-object\"]");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.isSkip());
}

test "extractSseEvent handles missing delta field without leaking" {
    // Provider chunks without a `delta` (initial chunk on some streams,
    // or `[DONE]`-adjacent chunks) used to be a leak surface if the
    // tool_call_deltas allocation slipped through on the error path.
    // This test pins the SseLineResult contract: no text, no reasoning,
    // no tool_call_deltas, not done — i.e. isSkip().
    const result = try extractSseEvent(std.testing.allocator, "{\"choices\":[{}]}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expect(result.reasoning == null);
    try std.testing.expectEqual(@as(usize, 0), result.tool_call_deltas.len);
    try std.testing.expect(!result.done);
    try std.testing.expect(result.isSkip());
}

test "extractSseEvent handles non-object choices entry" {
    // Defensive: provider sends `choices: [null]` or `choices: ["string"]`
    // — should treat as a no-content skip, not crash.
    const result = try extractSseEvent(std.testing.allocator, "{\"choices\":[null]}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.isSkip());
}

test "extractDeltaContent with content" {
    const allocator = std.testing.allocator;
    const result = (try extractDeltaContent(allocator, "{\"choices\":[{\"delta\":{\"content\":\"world\"}}]}")).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractDeltaContent without content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}");
    try std.testing.expect(result == null);
}

test "extractDeltaContent empty content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"content\":\"\"}}]}");
    try std.testing.expect(result == null);
}

const StreamRecorder = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    final_chunks: usize = 0,

    fn deinit(self: *StreamRecorder) void {
        self.text.deinit(self.allocator);
    }

    fn onChunk(ctx: *anyopaque, chunk: root.StreamChunk) void {
        const self: *StreamRecorder = @ptrCast(@alignCast(ctx));
        if (chunk.is_final) {
            self.final_chunks += 1;
            return;
        }
        self.text.appendSlice(self.allocator, chunk.delta) catch return;
    }
};

fn freeStreamChatResult(allocator: std.mem.Allocator, result: *root.StreamChatResult) void {
    if (result.content) |content| allocator.free(content);
    for (result.tool_calls) |call| {
        allocator.free(call.id);
        allocator.free(call.name);
        allocator.free(call.arguments);
    }
    if (result.tool_calls.len > 0) allocator.free(result.tool_calls);
    result.* = .{};
}

test "openai stream accumulates split tool calls and visible text" {
    const allocator = std.testing.allocator;

    var recorder = StreamRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var stream_ctx = OpenAiStreamCtx{
        .allocator = allocator,
        .callback = StreamRecorder.onChunk,
        .callback_ctx = &recorder,
    };
    defer stream_ctx.deinit();

    try stream_ctx.line_buf.appendSlice(allocator, "data: {\"choices\":[{\"delta\":{\"content\":\"Searching \",\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"function\":{\"name\":\"web_search\",\"arguments\":\"{\\\"query\\\":\\\"H\"}}]}}]}");
    try std.testing.expect(try handleOpenAiLine(&stream_ctx));

    try stream_ctx.line_buf.appendSlice(allocator, "data: {\"choices\":[{\"delta\":{\"content\":\"now\",\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"RS news\\\"}\"}}]}}]}");
    try std.testing.expect(try handleOpenAiLine(&stream_ctx));

    var result = try finalizeOpenAiStream(&stream_ctx);
    defer freeStreamChatResult(allocator, &result);

    try std.testing.expectEqualStrings("Searching now", recorder.text.items);
    try std.testing.expectEqual(@as(usize, 1), recorder.final_chunks);
    try std.testing.expect(result.content != null);
    try std.testing.expectEqualStrings("Searching now", result.content.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_abc", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("web_search", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"query\":\"HRS news\"}", result.tool_calls[0].arguments);
    try std.testing.expectEqual(@as(u32, 2), result.stream_tool_call_chunks);
}

test "openai stream captures authoritative usage from final chunk" {
    // V1.11 hardening (2026-05-07) — when stream_options.include_usage=true
    // is set on the request, the provider emits a final pre-`[DONE]` chunk
    // shaped like `{choices:[], usage:{prompt_tokens:N, completion_tokens:N,
    // total_tokens:N, completion_tokens_details:{reasoning_tokens:N}}}`. The
    // stream context must capture this and prefer it over the char-count
    // heuristic at finalize. Pre-fix this chunk was treated as a no-op
    // because `choices` was empty, so completion_tokens stayed at the
    // `chars/4` estimate (off by 30-50% on reasoning-heavy turns).
    const allocator = std.testing.allocator;

    var recorder = StreamRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var stream_ctx = OpenAiStreamCtx{
        .allocator = allocator,
        .callback = StreamRecorder.onChunk,
        .callback_ctx = &recorder,
    };
    defer stream_ctx.deinit();

    // 1. Normal content delta
    try stream_ctx.line_buf.appendSlice(allocator, "data: {\"choices\":[{\"delta\":{\"content\":\"Hello world\"}}]}");
    try std.testing.expect(try handleOpenAiLine(&stream_ctx));

    // 2. Final usage chunk (empty choices, populated usage with reasoning + cache)
    try stream_ctx.line_buf.appendSlice(allocator, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":47,\"total_tokens\":167,\"completion_tokens_details\":{\"reasoning_tokens\":35},\"prompt_tokens_details\":{\"cached_tokens\":80}}}");
    try std.testing.expect(try handleOpenAiLine(&stream_ctx));

    // 3. [DONE] sentinel
    try stream_ctx.line_buf.appendSlice(allocator, "data: [DONE]");
    try std.testing.expect(!(try handleOpenAiLine(&stream_ctx)));

    var result = try finalizeOpenAiStream(&stream_ctx);
    defer freeStreamChatResult(allocator, &result);

    try std.testing.expectEqual(@as(u32, 120), result.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 47), result.usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 167), result.usage.total_tokens);
    try std.testing.expectEqual(@as(u32, 35), result.usage.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 80), result.usage.cached_prompt_tokens);
}

test "openai stream falls back to estimate when usage chunk absent" {
    // Pre-V1.11-hardening behavior: when the provider doesn't emit a usage
    // chunk (didn't honor stream_options.include_usage, or older provider),
    // completion_tokens estimates from accumulated character count. Guard
    // that the fallback path still works.
    const allocator = std.testing.allocator;

    var recorder = StreamRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var stream_ctx = OpenAiStreamCtx{
        .allocator = allocator,
        .callback = StreamRecorder.onChunk,
        .callback_ctx = &recorder,
    };
    defer stream_ctx.deinit();

    // 16-char content → 4 estimated tokens
    try stream_ctx.line_buf.appendSlice(allocator, "data: {\"choices\":[{\"delta\":{\"content\":\"Sixteen-char str\"}}]}");
    try std.testing.expect(try handleOpenAiLine(&stream_ctx));
    try stream_ctx.line_buf.appendSlice(allocator, "data: [DONE]");
    try std.testing.expect(!(try handleOpenAiLine(&stream_ctx)));

    var result = try finalizeOpenAiStream(&stream_ctx);
    defer freeStreamChatResult(allocator, &result);

    try std.testing.expectEqual(@as(u32, 0), result.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 4), result.usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 0), result.usage.total_tokens);
    try std.testing.expectEqual(@as(u32, 0), result.usage.reasoning_tokens);
}

test "openai stream accumulates multiple parallel tool calls" {
    // Regression guard: when the LLM emits two parallel tool calls (index=0
    // and index=1) interleaved across stream events, both must survive into
    // the finalized result. A silent drop here is the failure mode that
    // would make the agent "execute one of many promised tools."
    const allocator = std.testing.allocator;

    var recorder = StreamRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var stream_ctx = OpenAiStreamCtx{
        .allocator = allocator,
        .callback = StreamRecorder.onChunk,
        .callback_ctx = &recorder,
    };
    defer stream_ctx.deinit();

    // Delta 1: index=0 introduces web_search, index=1 introduces runtime_info
    try stream_ctx.line_buf.appendSlice(
        allocator,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[" ++
            "{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"web_search\",\"arguments\":\"{\\\"q\\\":\\\"x\"}}," ++
            "{\"index\":1,\"id\":\"call_b\",\"function\":{\"name\":\"runtime_info\",\"arguments\":\"{}\"}}" ++
            "]}}]}",
    );
    try std.testing.expect(try handleOpenAiLine(&stream_ctx));

    // Delta 2: completes web_search arguments on index=0
    try stream_ctx.line_buf.appendSlice(
        allocator,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[" ++
            "{\"index\":0,\"function\":{\"arguments\":\"\\\"}\"}}" ++
            "]}}]}",
    );
    try std.testing.expect(try handleOpenAiLine(&stream_ctx));

    var result = try finalizeOpenAiStream(&stream_ctx);
    defer freeStreamChatResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_a", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("web_search", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"q\":\"x\"}", result.tool_calls[0].arguments);
    try std.testing.expectEqualStrings("call_b", result.tool_calls[1].id);
    try std.testing.expectEqualStrings("runtime_info", result.tool_calls[1].name);
    try std.testing.expectEqualStrings("{}", result.tool_calls[1].arguments);
}

test "StreamChunk textDelta token estimate" {
    const chunk = root.StreamChunk.textDelta("12345678");
    try std.testing.expect(chunk.token_count == 2);
    try std.testing.expect(!chunk.is_final);
    try std.testing.expectEqualStrings("12345678", chunk.delta);
}

test "StreamChunk finalChunk" {
    const chunk = root.StreamChunk.finalChunk();
    try std.testing.expect(chunk.is_final);
    try std.testing.expectEqualStrings("", chunk.delta);
    try std.testing.expect(chunk.token_count == 0);
}

// ── Anthropic SSE Tests ─────────────────────────────────────────

test "parseAnthropicSseLine event line returns event" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "event: content_block_delta", "");
    switch (result) {
        .event => |ev| try std.testing.expectEqualStrings("content_block_delta", ev),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with content_block_delta returns delta" {
    const allocator = std.testing.allocator;
    const json = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}";
    const result = try parseAnthropicSseLine(allocator, json, "content_block_delta");
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_delta returns usage" {
    const json = "data: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":42}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_delta");
    switch (result) {
        .usage => |tokens| try std.testing.expect(tokens == 42),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_stop returns done" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "data: {\"type\":\"message_stop\"}", "message_stop");
    try std.testing.expect(result == .done);
}

test "parseAnthropicSseLine empty line returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine comment returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, ":keep-alive", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine data with unknown event returns skip" {
    const json = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\"}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_start");
    try std.testing.expect(result == .skip);
}

test "extractAnthropicDelta correct JSON returns text" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}";
    const result = (try extractAnthropicDelta(allocator, json)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractAnthropicDelta without text returns null" {
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}";
    const result = try extractAnthropicDelta(std.testing.allocator, json);
    try std.testing.expect(result == null);
}

test "extractAnthropicUsage correct JSON returns token count" {
    const json = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":57}}";
    const result = (try extractAnthropicUsage(json)).?;
    try std.testing.expect(result == 57);
}
