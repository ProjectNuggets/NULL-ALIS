const std = @import("std");
const root = @import("root.zig");
const log = std.log.scoped(.provider_reliable);

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const StreamCallback = root.StreamCallback;
const StreamChatResult = root.StreamChatResult;
const StreamChunk = root.StreamChunk;

/// Check if an error message indicates a non-retryable client error (4xx except 429/408).
pub fn isNonRetryable(err_msg: []const u8) bool {
    // Look for 4xx status codes
    var i: usize = 0;
    while (i < err_msg.len) {
        // Find a digit sequence
        if (std.ascii.isDigit(err_msg[i])) {
            var end = i;
            while (end < err_msg.len and std.ascii.isDigit(err_msg[end])) {
                end += 1;
            }
            if (end - i == 3) {
                const code = std.fmt.parseInt(u16, err_msg[i..end], 10) catch {
                    i = end;
                    continue;
                };
                if (code >= 400 and code < 500) {
                    return code != 429 and code != 408;
                }
            }
            i = end;
        } else {
            i += 1;
        }
    }
    return false;
}

/// Check if an error message indicates context window exhaustion.
pub fn isContextExhausted(err_msg: []const u8) bool {
    // Case-insensitive match against common patterns from LLM providers.
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(err_msg.len, lower_buf.len);
    for (err_msg[0..check_len], 0..) |c, idx| {
        lower_buf[idx] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..check_len];

    const has_context = std.mem.indexOf(u8, lower, "context") != null;
    const has_token = std.mem.indexOf(u8, lower, "token") != null;
    if (has_context and (std.mem.indexOf(u8, lower, "length") != null or
        std.mem.indexOf(u8, lower, "maximum") != null or
        std.mem.indexOf(u8, lower, "window") != null or
        std.mem.indexOf(u8, lower, "exceed") != null))
        return true;
    if (has_token and (std.mem.indexOf(u8, lower, "limit") != null or
        std.mem.indexOf(u8, lower, "too many") != null or
        std.mem.indexOf(u8, lower, "maximum") != null or
        std.mem.indexOf(u8, lower, "exceed") != null))
        return true;
    if (std.mem.indexOf(u8, lower, "413") != null and std.mem.indexOf(u8, lower, "too large") != null) return true;
    return false;
}

/// Check if an error message indicates a rate-limit (429) error.
pub fn isRateLimited(err_msg: []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(err_msg.len, lower_buf.len);
    for (err_msg[0..check_len], 0..) |c, idx| {
        lower_buf[idx] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..check_len];

    if (std.mem.indexOf(u8, lower, "ratelimited") != null or
        std.mem.indexOf(u8, lower, "rate limited") != null or
        std.mem.indexOf(u8, lower, "rate_limit") != null or
        std.mem.indexOf(u8, lower, "too many requests") != null or
        std.mem.indexOf(u8, lower, "quota exceeded") != null or
        std.mem.indexOf(u8, lower, "throttle") != null)
    {
        return true;
    }

    return std.mem.indexOf(u8, lower, "429") != null and
        (std.mem.indexOf(u8, lower, "rate") != null or
            std.mem.indexOf(u8, lower, "limit") != null or
            std.mem.indexOf(u8, lower, "too many") != null);
}

/// V1.11 hardening (2026-05-07) — Together / Anthropic / OpenRouter
/// transient overload detection. Mirrors `error_classify.isOverloadedText`
/// so tests in this file can stay self-contained. Distinct from
/// `isRateLimited` because no key rotation is needed (overload is
/// provider-side capacity, not attributable to one tenant).
pub fn isOverloaded(err_msg: []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(err_msg.len, lower_buf.len);
    for (err_msg[0..check_len], 0..) |c, idx| {
        lower_buf[idx] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..check_len];

    if (std.mem.indexOf(u8, lower, "overloaded") != null or
        std.mem.indexOf(u8, lower, "overloaded_error") != null or
        std.mem.indexOf(u8, lower, "service unavailable") != null or
        std.mem.indexOf(u8, lower, "service_unavailable") != null or
        std.mem.indexOf(u8, lower, "model is currently loading") != null or
        std.mem.indexOf(u8, lower, "model is loading") != null or
        std.mem.indexOf(u8, lower, "temporarily unavailable") != null or
        std.mem.indexOf(u8, lower, "provideroverloaded") != null)
    {
        return true;
    }

    // 503 paired with any of these signal words
    if (std.mem.indexOf(u8, lower, "503") != null and
        (std.mem.indexOf(u8, lower, "service") != null or
            std.mem.indexOf(u8, lower, "unavailable") != null or
            std.mem.indexOf(u8, lower, "overload") != null))
    {
        return true;
    }

    return false;
}

pub fn isTimeout(err_msg: []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(err_msg.len, lower_buf.len);
    for (err_msg[0..check_len], 0..) |c, idx| {
        lower_buf[idx] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..check_len];

    return std.mem.indexOf(u8, lower, "timeout") != null or
        std.mem.indexOf(u8, lower, "timed out") != null;
}

/// Try to extract a Retry-After value (in milliseconds) from an error message.
pub fn parseRetryAfterMs(err_msg: []const u8) ?u64 {
    const prefixes = [_][]const u8{
        "retry-after:",
        "retry_after:",
        "retry-after ",
        "retry_after ",
    };

    // Case-insensitive search
    var lower_buf: [4096]u8 = undefined;
    const check_len = @min(err_msg.len, lower_buf.len);
    for (err_msg[0..check_len], 0..) |c, idx| {
        lower_buf[idx] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..check_len];

    for (prefixes) |prefix| {
        if (std.mem.indexOf(u8, lower, prefix)) |pos| {
            const after_start = pos + prefix.len;
            if (after_start >= check_len) continue;

            // Skip whitespace
            var start = after_start;
            while (start < check_len and (err_msg[start] == ' ' or err_msg[start] == '\t')) {
                start += 1;
            }

            // Parse number
            var end = start;
            var has_dot = false;
            while (end < check_len) {
                if (std.ascii.isDigit(err_msg[end])) {
                    end += 1;
                } else if (err_msg[end] == '.' and !has_dot) {
                    has_dot = true;
                    end += 1;
                } else {
                    break;
                }
            }

            if (end > start) {
                const num_str = err_msg[start..end];
                if (std.fmt.parseFloat(f64, num_str)) |secs| {
                    if (std.math.isFinite(secs) and secs >= 0.0) {
                        const millis = @as(u64, @intFromFloat(secs * 1000.0));
                        return millis;
                    }
                } else |_| {}
            }
        }
    }

    return null;
}

/// A named provider entry for the fallback chain.
pub const ProviderEntry = struct {
    name: []const u8,
    provider: Provider,
    /// Per-provider model-ID override for cross-provider fallback. When a
    /// fallback provider serves the same logical model under a different ID
    /// (e.g. Moonshot `kimi-k2.6` vs Together `moonshotai/Kimi-K2.6`), this
    /// holds the ID to use when failing over to THIS provider. `null` = use
    /// the chain's current model unchanged. Populated by runtime_bundle.zig
    /// from the `provider/model` ref form in `fallback_providers`.
    model_override: ?[]const u8 = null,
};

/// A model fallback mapping: when `model` fails, try `fallbacks` in order.
pub const ModelFallbackEntry = struct {
    model: []const u8,
    fallbacks: []const []const u8,
};

/// Provider wrapper with retry, multi-provider fallback, and model failover.
///
/// Wraps a primary inner provider and optional extra providers as a fallback chain.
/// Retries on transient errors with exponential backoff. Skips retries for
/// non-retryable client errors (4xx except 429/408). On rate-limit errors,
/// rotates API keys if available. Supports per-model fallback chains.
pub const ReliableProvider = struct {
    /// The wrapped primary inner provider to delegate calls to.
    inner: Provider,
    /// Additional fallback providers (empty by default for backward compat).
    extras: []const ProviderEntry = &.{},
    /// Per-model fallback chains.
    model_fallbacks: []const ModelFallbackEntry = &.{},
    /// List of provider names (for diagnostics/logging).
    provider_names: []const []const u8,
    max_retries: u32,
    base_backoff_ms: u64,
    /// Extra API keys for rotation on rate-limit errors.
    api_keys: []const []const u8,
    key_index: usize,
    /// Last error message from failed attempt (for retry-after parsing).
    last_error_msg: [256]u8,
    last_error_len: usize,

    pub fn init(
        provider_names: []const []const u8,
        max_retries: u32,
        base_backoff_ms: u64,
    ) ReliableProvider {
        return .{
            .inner = undefined,
            .provider_names = provider_names,
            .max_retries = max_retries,
            .base_backoff_ms = @max(base_backoff_ms, 50),
            .api_keys = &.{},
            .key_index = 0,
            .last_error_msg = undefined,
            .last_error_len = 0,
        };
    }

    /// Initialize with an inner provider to wrap.
    pub fn initWithProvider(
        inner: Provider,
        max_retries: u32,
        base_backoff_ms: u64,
    ) ReliableProvider {
        return .{
            .inner = inner,
            .provider_names = &.{},
            .max_retries = max_retries,
            .base_backoff_ms = @max(base_backoff_ms, 50),
            .api_keys = &.{},
            .key_index = 0,
            .last_error_msg = undefined,
            .last_error_len = 0,
        };
    }

    pub fn withApiKeys(self: *ReliableProvider, keys: []const []const u8) *ReliableProvider {
        self.api_keys = keys;
        return self;
    }

    /// Set the inner provider to wrap.
    pub fn withInner(self: *ReliableProvider, inner: Provider) *ReliableProvider {
        self.inner = inner;
        return self;
    }

    /// Set additional fallback providers.
    pub fn withExtras(self: ReliableProvider, extras: []const ProviderEntry) ReliableProvider {
        var r = self;
        r.extras = extras;
        return r;
    }

    /// Set per-model fallback chains.
    pub fn withModelFallbacks(self: ReliableProvider, fallbacks: []const ModelFallbackEntry) ReliableProvider {
        var r = self;
        r.model_fallbacks = fallbacks;
        return r;
    }

    /// Returns the model chain for a given model: [model, fallback1, fallback2, ...].
    /// If no fallbacks configured for this model, returns a single-element slice.
    /// Caller must free the returned slice.
    pub fn modelChain(self: *const ReliableProvider, allocator: std.mem.Allocator, model: []const u8) ![]const []const u8 {
        // Find fallbacks for this model
        for (self.model_fallbacks) |entry| {
            if (std.mem.eql(u8, entry.model, model)) {
                // Build chain: [model] ++ fallbacks
                const chain = try allocator.alloc([]const u8, 1 + entry.fallbacks.len);
                chain[0] = model;
                for (entry.fallbacks, 0..) |fb, i| {
                    chain[1 + i] = fb;
                }
                return chain;
            }
        }
        // No fallbacks: single-element slice
        const chain = try allocator.alloc([]const u8, 1);
        chain[0] = model;
        return chain;
    }

    /// Advance to the next API key (round-robin) and return it.
    pub fn rotateKey(self: *ReliableProvider) ?[]const u8 {
        if (self.api_keys.len == 0) return null;
        const idx = self.key_index % self.api_keys.len;
        self.key_index += 1;
        return self.api_keys[idx];
    }

    /// Compute backoff duration, respecting Retry-After if present.
    pub fn computeBackoff(_: ReliableProvider, base: u64, err_msg: []const u8) u64 {
        if (parseRetryAfterMs(err_msg)) |retry_after| {
            // Cap at 30s
            return @max(@min(retry_after, 30_000), base);
        }
        return base;
    }

    /// Store an error name for retry-after inspection.
    fn storeErrorName(self: *ReliableProvider, err: anyerror) void {
        const name = @errorName(err);
        const copy_len = @min(name.len, self.last_error_msg.len);
        @memcpy(self.last_error_msg[0..copy_len], name[0..copy_len]);
        self.last_error_len = copy_len;
    }

    /// Get the last stored error message.
    fn lastErrorSlice(self: *const ReliableProvider) []const u8 {
        return self.last_error_msg[0..self.last_error_len];
    }

    fn finalFailureError(self: *const ReliableProvider) anyerror {
        const err_slice = self.lastErrorSlice();
        if (isTimeout(err_slice)) return error.Timeout;
        if (isContextExhausted(err_slice)) return error.ContextLengthExceeded;
        if (isRateLimited(err_slice)) return error.RateLimited;
        // V1.11 hardening (2026-05-07): preserve overload distinct from
        // generic AllProvidersFailed so dashboards can distinguish "we
        // exhausted retries because the provider was saturated" from "we
        // exhausted retries because the request was malformed."
        if (isOverloaded(err_slice)) return error.ProviderOverloaded;
        if (std.mem.eql(u8, err_slice, "ProviderDoesNotSupportVision")) return error.ProviderDoesNotSupportVision;
        return error.AllProvidersFailed;
    }

    const StreamRelayContext = struct {
        outer_callback: StreamCallback,
        outer_ctx: *anyopaque,
        saw_first_token: bool = false,

        fn onChunk(ctx: *anyopaque, chunk: StreamChunk) void {
            const self: *StreamRelayContext = @ptrCast(@alignCast(ctx));
            if (!chunk.is_final and (chunk.delta.len > 0 or chunk.token_count > 0)) {
                self.saw_first_token = true;
            }
            self.outer_callback(self.outer_ctx, chunk);
        }
    };

    // ── Provider vtable implementation ──

    const vtable_impl = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .supports_native_tools_for_request = supportsNativeToolsForRequestImpl,
        .supports_sensitive_streaming_for_request = supportsSensitiveStreamingForRequestImpl,
        .supports_streaming = supportsStreamingImpl,
        .supports_vision = supportsVisionImpl,
        .supports_vision_for_model = supportsVisionForModelImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
        .warmup = warmupImpl,
        .stream_chat = streamChatImpl,
        .estimate_tokens = estimateTokensImpl,
    };

    /// Create a Provider interface from this ReliableProvider.
    pub fn provider(self: *ReliableProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_impl,
        };
    }

    /// Try a single provider with retries for chatWithSystem.
    fn tryChatWithSystemProvider(
        self: *ReliableProvider,
        prov: Provider,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        current_model: []const u8,
    ) ?[]const u8 {
        var backoff_ms = self.base_backoff_ms;
        var attempt: u32 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            if (prov.chatWithSystem(allocator, system_prompt, message, current_model, 0.7)) |result| {
                return result;
            } else |err| {
                self.storeErrorName(err);
                const err_slice = self.lastErrorSlice();

                if (isNonRetryable(err_slice)) break;
                if (isTimeout(err_slice) and self.extras.len > 0) break;

                if (isRateLimited(err_slice)) {
                    if (self.extras.len > 0) break;
                    _ = self.rotateKey();
                }

                if (attempt < self.max_retries) {
                    const wait = self.computeBackoff(backoff_ms, err_slice);
                    std.Thread.sleep(wait * std.time.ns_per_ms);
                    backoff_ms = @min(backoff_ms *| 2, 10_000);
                }
            }
        }
        return null;
    }

    /// Try a single provider with retries for chat.
    fn tryChatProvider(
        self: *ReliableProvider,
        prov: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        current_model: []const u8,
        extra_fallback_available: bool,
    ) ?ChatResponse {
        var backoff_ms = self.base_backoff_ms;
        var attempt: u32 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            if (prov.chat(allocator, request, current_model, request.temperature)) |result| {
                return result;
            } else |err| {
                self.storeErrorName(err);
                const err_slice = self.lastErrorSlice();

                if (isNonRetryable(err_slice)) break;
                if (isTimeout(err_slice) and extra_fallback_available) break;

                if (isRateLimited(err_slice)) {
                    if (extra_fallback_available) break;
                    _ = self.rotateKey();
                }

                if (attempt < self.max_retries) {
                    const wait = self.computeBackoff(backoff_ms, err_slice);
                    std.Thread.sleep(wait * std.time.ns_per_ms);
                    backoff_ms = @min(backoff_ms *| 2, 10_000);
                }
            }
        }
        return null;
    }

    fn tryStreamProvider(
        self: *ReliableProvider,
        prov: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        current_model: []const u8,
        extra_fallback_available: bool,
        callback: StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!?StreamChatResult {
        if (!prov.supportsStreaming()) return null;

        var backoff_ms = self.base_backoff_ms;
        var attempt: u32 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            log.info("stream.attempt provider={s} model={s} attempt={d}", .{
                prov.getName(),
                current_model,
                attempt,
            });

            var relay_ctx = StreamRelayContext{
                .outer_callback = callback,
                .outer_ctx = callback_ctx,
            };
            var stream_request = request;
            stream_request.model = current_model;

            if (prov.streamChat(
                allocator,
                stream_request,
                current_model,
                request.temperature,
                StreamRelayContext.onChunk,
                @ptrCast(&relay_ctx),
            )) |result| {
                return result;
            } else |err| {
                self.storeErrorName(err);
                const err_slice = self.lastErrorSlice();
                log.warn("stream.attempt failed provider={s} model={s} attempt={d} emitted_first_token={} error={s}", .{
                    prov.getName(),
                    current_model,
                    attempt,
                    relay_ctx.saw_first_token,
                    err_slice,
                });

                if (relay_ctx.saw_first_token) return err;
                if (isNonRetryable(err_slice)) break;
                if (isTimeout(err_slice) and extra_fallback_available) break;

                if (isRateLimited(err_slice)) {
                    if (extra_fallback_available) break;
                    _ = self.rotateKey();
                }

                if (attempt < self.max_retries) {
                    const wait = self.computeBackoff(backoff_ms, err_slice);
                    std.Thread.sleep(wait * std.time.ns_per_ms);
                    backoff_ms = @min(backoff_ms *| 2, 10_000);
                }
            }
        }
        return null;
    }

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) anyerror![]const u8 {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        _ = temperature;

        const models = try self.modelChain(allocator, model);
        defer allocator.free(models);

        for (models) |current_model| {
            // Try primary provider
            if (self.tryChatWithSystemProvider(
                self.inner,
                allocator,
                system_prompt,
                message,
                current_model,
            )) |result| {
                return result;
            }

            // Try extra providers
            for (self.extras) |entry| {
                if (self.tryChatWithSystemProvider(
                    entry.provider,
                    allocator,
                    system_prompt,
                    message,
                    entry.model_override orelse current_model,
                )) |result| {
                    return result;
                }
            }
        }

        return self.finalFailureError();
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
    ) anyerror!ChatResponse {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        _ = temperature;

        if (request.provider_selection_policy == .exact_primary_and_model) {
            if (self.tryChatProvider(self.inner, allocator, request, model, false)) |result| {
                return result;
            }
            return self.finalFailureError();
        }

        const models = try self.modelChain(allocator, model);
        defer allocator.free(models);

        for (models) |current_model| {
            // Try primary provider
            if (self.tryChatProvider(
                self.inner,
                allocator,
                request,
                current_model,
                self.extras.len > 0,
            )) |result| {
                return result;
            }

            // Try extra providers
            for (self.extras) |entry| {
                if (self.tryChatProvider(
                    entry.provider,
                    allocator,
                    request,
                    entry.model_override orelse current_model,
                    self.extras.len > 0,
                )) |result| {
                    return result;
                }
            }
        }

        return self.finalFailureError();
    }

    fn supportsNativeToolsImpl(ptr: *anyopaque) bool {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        if (self.inner.supportsNativeTools()) return true;
        for (self.extras) |entry| {
            if (entry.provider.supportsNativeTools()) return true;
        }
        return false;
    }

    fn supportsNativeToolsForRequestImpl(ptr: *anyopaque, request: ChatRequest) bool {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        if (request.provider_selection_policy == .exact_primary_and_model) {
            return self.inner.supportsNativeToolsForRequest(request);
        }
        return supportsNativeToolsImpl(ptr);
    }

    fn supportsSensitiveStreamingForRequestImpl(ptr: *anyopaque, request: ChatRequest) bool {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        // Sensitive requests are exact-primary-only. Never infer safety from
        // an extra/fallback adapter with different process boundaries.
        if (request.provider_selection_policy != .exact_primary_and_model) return false;
        return self.inner.supportsStreaming() and
            self.inner.supportsSensitiveStreamingForRequest(request);
    }

    fn supportsStreamingImpl(ptr: *anyopaque) bool {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        if (self.inner.supportsStreaming()) return true;
        for (self.extras) |entry| {
            if (entry.provider.supportsStreaming()) return true;
        }
        return false;
    }

    fn supportsVisionImpl(ptr: *anyopaque) bool {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        if (self.inner.supportsVision()) return true;
        for (self.extras) |entry| {
            if (entry.provider.supportsVision()) return true;
        }
        return false;
    }

    fn supportsVisionForModelImpl(ptr: *anyopaque, model: []const u8) bool {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        if (self.inner.supportsVisionForModel(model)) return true;
        for (self.extras) |entry| {
            if (entry.provider.supportsVisionForModel(model)) return true;
        }
        return false;
    }

    fn getNameImpl(ptr: *anyopaque) []const u8 {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        return self.inner.getName();
    }

    fn estimateTokensImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
    ) anyerror!root.TokenEstimateResult {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));

        if (request.provider_selection_policy == .exact_primary_and_model) {
            if (self.inner.estimateTokens(allocator, request, model)) |maybe| {
                if (maybe) |result| return result;
            } else |err| {
                self.storeErrorName(err);
            }
            return error.UnsupportedOperation;
        }

        const models = try self.modelChain(allocator, model);
        defer allocator.free(models);

        for (models) |current_model| {
            if (self.inner.estimateTokens(allocator, request, current_model)) |maybe| {
                if (maybe) |result| return result;
            } else |err| {
                self.storeErrorName(err);
            }
            for (self.extras) |entry| {
                if (entry.provider.estimateTokens(allocator, request, entry.model_override orelse current_model)) |maybe| {
                    if (maybe) |result| return result;
                } else |err| {
                    self.storeErrorName(err);
                }
            }
        }
        return error.UnsupportedOperation;
    }

    fn streamChatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
        callback: StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!StreamChatResult {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        _ = temperature;

        if (request.provider_selection_policy == .exact_primary_and_model) {
            if (!self.inner.supportsStreaming()) return error.UnsupportedOperation;
            if (try self.tryStreamProvider(
                self.inner,
                allocator,
                request,
                model,
                false,
                callback,
                callback_ctx,
            )) |result| return result;
            // Exact sensitive routing must never downgrade from the audited
            // streaming transport into blocking chat, whose subprocess and
            // error-body boundary may not carry the same guarantees.
            return self.finalFailureError();
        }

        const models = try self.modelChain(allocator, model);
        defer allocator.free(models);

        for (models) |current_model| {
            if (try self.tryStreamProvider(
                self.inner,
                allocator,
                request,
                current_model,
                self.extras.len > 0,
                callback,
                callback_ctx,
            )) |result| {
                // Primary succeeded — no fallback tag needed. Early return
                // leaves `used_fallback` null on the result.
                return result;
            }

            for (self.extras) |entry| {
                if (try self.tryStreamProvider(
                    entry.provider,
                    allocator,
                    request,
                    entry.model_override orelse current_model,
                    self.extras.len > 0,
                    callback,
                    callback_ctx,
                )) |tagged| {
                    // Fallback provider succeeded after primary failed. Tag
                    // the result so the caller (agent loop) can emit a
                    // `system_notice kind=provider_fallback` to the user.
                    // Binding rule: no silent fallback.
                    var result = tagged;
                    result.used_fallback = entry.name;
                    return result;
                }
            }
        }

        return self.finalFailureError();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        self.inner.deinit();
        for (self.extras) |entry| {
            entry.provider.deinit();
        }
    }

    fn warmupImpl(ptr: *anyopaque) void {
        const self: *ReliableProvider = @ptrCast(@alignCast(ptr));
        self.inner.warmup();
        for (self.extras) |entry| {
            entry.provider.warmup();
        }
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "isContextExhausted detects common patterns" {
    try std.testing.expect(isContextExhausted("context length exceeded"));
    try std.testing.expect(isContextExhausted("maximum context length"));
    try std.testing.expect(isContextExhausted("token limit exceeded"));
    try std.testing.expect(isContextExhausted("ContextLengthExceeded"));
    try std.testing.expect(isContextExhausted("too many tokens in context"));
    try std.testing.expect(isContextExhausted("maximum token limit"));
    try std.testing.expect(isContextExhausted("HTTP 413 Payload Too Large"));
    try std.testing.expect(!isContextExhausted("500 Internal Server Error"));
    try std.testing.expect(!isContextExhausted("connection reset"));
    try std.testing.expect(!isContextExhausted(""));
}

test "isNonRetryable detects common patterns" {
    try std.testing.expect(isNonRetryable("400 Bad Request"));
    try std.testing.expect(isNonRetryable("401 Unauthorized"));
    try std.testing.expect(isNonRetryable("403 Forbidden"));
    try std.testing.expect(isNonRetryable("404 Not Found"));
    try std.testing.expect(!isNonRetryable("429 Too Many Requests"));
    try std.testing.expect(!isNonRetryable("408 Request Timeout"));
    try std.testing.expect(!isNonRetryable("500 Internal Server Error"));
    try std.testing.expect(!isNonRetryable("502 Bad Gateway"));
    try std.testing.expect(!isNonRetryable("timeout"));
    try std.testing.expect(!isNonRetryable("connection reset"));
}

test "isRateLimited detection" {
    try std.testing.expect(isRateLimited("429 Too Many Requests"));
    try std.testing.expect(isRateLimited("HTTP 429 rate limit exceeded"));
    try std.testing.expect(isRateLimited("RateLimited"));
    try std.testing.expect(!isRateLimited("401 Unauthorized"));
    try std.testing.expect(!isRateLimited("500 Internal Server Error"));
}

test "isTimeout detection" {
    try std.testing.expect(isTimeout("Timeout"));
    try std.testing.expect(isTimeout("operation timed out"));
    try std.testing.expect(!isTimeout("RateLimited"));
}

test "isOverloaded detection" {
    // V1.11 hardening (2026-05-07) — Together / Anthropic / OpenRouter
    // overload detection. These patterns must trip the retry-with-backoff
    // path (NOT the non-retryable break path) so a saturated provider on
    // demo day doesn't kill the user's request.
    try std.testing.expect(isOverloaded("503 Service Unavailable"));
    try std.testing.expect(isOverloaded("Anthropic returned overloaded_error"));
    try std.testing.expect(isOverloaded("model is currently loading, please retry"));
    try std.testing.expect(isOverloaded("model is loading"));
    try std.testing.expect(isOverloaded("upstream model overloaded"));
    try std.testing.expect(isOverloaded("Service temporarily unavailable"));
    try std.testing.expect(isOverloaded("ProviderOverloaded"));
    // Ensure we don't false-positive
    try std.testing.expect(!isOverloaded("429 Too Many Requests"));
    try std.testing.expect(!isOverloaded("401 Unauthorized"));
    try std.testing.expect(!isOverloaded("Timeout"));
    try std.testing.expect(!isOverloaded(""));
}

test "parseRetryAfterMs integer" {
    try std.testing.expect(parseRetryAfterMs("429 Too Many Requests, Retry-After: 5").? == 5000);
}

test "parseRetryAfterMs float" {
    try std.testing.expect(parseRetryAfterMs("Rate limited. retry_after: 2.5 seconds").? == 2500);
}

test "parseRetryAfterMs missing" {
    try std.testing.expect(parseRetryAfterMs("500 Internal Server Error") == null);
}

test "ReliableProvider computeBackoff uses retry-after" {
    const prov = ReliableProvider.init(&.{}, 0, 500);
    try std.testing.expect(prov.computeBackoff(500, "429 Retry-After: 3") == 3000);
}

test "ReliableProvider computeBackoff caps at 30s" {
    const prov = ReliableProvider.init(&.{}, 0, 500);
    try std.testing.expect(prov.computeBackoff(500, "429 Retry-After: 120") == 30_000);
}

test "ReliableProvider computeBackoff falls back to base" {
    const prov = ReliableProvider.init(&.{}, 0, 500);
    try std.testing.expect(prov.computeBackoff(500, "500 Server Error") == 500);
}

test "ReliableProvider auth rotation cycles keys" {
    const keys = [_][]const u8{ "key-a", "key-b", "key-c" };
    var prov = ReliableProvider.init(&.{}, 0, 1);
    _ = prov.withApiKeys(&keys);

    // Rotate 5 times, verify round-robin
    try std.testing.expectEqualStrings("key-a", prov.rotateKey().?);
    try std.testing.expectEqualStrings("key-b", prov.rotateKey().?);
    try std.testing.expectEqualStrings("key-c", prov.rotateKey().?);
    try std.testing.expectEqualStrings("key-a", prov.rotateKey().?);
    try std.testing.expectEqualStrings("key-b", prov.rotateKey().?);
}

test "ReliableProvider auth rotation returns null when empty" {
    var prov = ReliableProvider.init(&.{}, 0, 1);
    try std.testing.expect(prov.rotateKey() == null);
}

test "isNonRetryable embedded in longer message" {
    try std.testing.expect(isNonRetryable("Error: got 401 from upstream API"));
    try std.testing.expect(!isNonRetryable("Server returned 500 error"));
}

test "isRateLimited requires both 429 and keyword" {
    // Just "429" alone without rate/limit/Too Many should be false
    try std.testing.expect(!isRateLimited("error code 429"));
    // With proper keywords
    try std.testing.expect(isRateLimited("429 rate exceeded"));
    try std.testing.expect(isRateLimited("429 limit reached"));
}

test "isRateLimited empty string" {
    try std.testing.expect(!isRateLimited(""));
}

test "parseRetryAfterMs with underscore separator" {
    try std.testing.expect(parseRetryAfterMs("retry_after: 10").? == 10000);
}

test "parseRetryAfterMs with space separator" {
    try std.testing.expect(parseRetryAfterMs("retry-after 7").? == 7000);
}

test "parseRetryAfterMs zero value" {
    try std.testing.expect(parseRetryAfterMs("Retry-After: 0").? == 0);
}

test "parseRetryAfterMs case insensitive" {
    try std.testing.expect(parseRetryAfterMs("RETRY-AFTER: 3").? == 3000);
    try std.testing.expect(parseRetryAfterMs("Retry-After: 3").? == 3000);
}

test "parseRetryAfterMs ignores non-numeric" {
    try std.testing.expect(parseRetryAfterMs("Retry-After: abc") == null);
}

test "ReliableProvider init enforces min backoff 50ms" {
    const prov = ReliableProvider.init(&.{}, 0, 10);
    try std.testing.expect(prov.base_backoff_ms == 50);
}

test "ReliableProvider computeBackoff uses base when retry-after is smaller" {
    const prov = ReliableProvider.init(&.{}, 0, 5000);
    // Retry-After: 1 second = 1000ms, but base is 5000ms -> max(1000, 5000) = 5000
    try std.testing.expect(prov.computeBackoff(5000, "429 Retry-After: 1") == 5000);
}

// ════════════════════════════════════════════════════════════════════════════
// Mock provider for vtable retry tests
// ════════════════════════════════════════════════════════════════════════════

const MockInnerProvider = struct {
    call_count: u32,
    fail_until: u32,
    fail_error: anyerror = error.ProviderError,
    supports_tools: bool,
    supports_vision: bool = true,
    warmed_up: bool = false,

    const vtable_mock = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .supports_vision = mockSupportsVision,
        .getName = mockGetName,
        .deinit = mockDeinit,
        .warmup = mockWarmup,
    };

    fn toProvider(self: *MockInnerProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_mock };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockInnerProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        if (self.call_count <= self.fail_until) {
            return self.fail_error;
        }
        return "mock response";
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *MockInnerProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        if (self.call_count <= self.fail_until) {
            return self.fail_error;
        }
        return ChatResponse{ .content = try allocator.dupe(u8, "mock chat") };
    }

    fn mockSupportsNativeTools(ptr: *anyopaque) bool {
        const self: *MockInnerProvider = @ptrCast(@alignCast(ptr));
        return self.supports_tools;
    }

    fn mockSupportsVision(ptr: *anyopaque) bool {
        const self: *MockInnerProvider = @ptrCast(@alignCast(ptr));
        return self.supports_vision;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "MockProvider";
    }

    fn mockDeinit(_: *anyopaque) void {}

    fn mockWarmup(ptr: *anyopaque) void {
        const self: *MockInnerProvider = @ptrCast(@alignCast(ptr));
        self.warmed_up = true;
    }
};

/// Mock that records which model was used for each call.
const ModelAwareMock = struct {
    call_count: u32 = 0,
    estimate_count: u32 = 0,
    estimated_prompt_tokens: u32 = 42,
    models_seen_buf: [16][]const u8 = undefined,
    models_seen_len: usize = 0,
    fail_models_buf: [8][]const u8 = undefined,
    fail_models_len: usize = 0,
    response: []const u8 = "ok",
    supports_tools: bool = false,
    supports_vision: bool = true,

    const vtable_model = Provider.VTable{
        .chatWithSystem = modelChatWithSystem,
        .chat = modelChat,
        .supportsNativeTools = modelSupportsNativeTools,
        .supports_vision = modelSupportsVision,
        .getName = modelGetName,
        .deinit = modelDeinit,
        .estimate_tokens = modelEstimateTokens,
    };

    fn toProvider(self: *ModelAwareMock) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_model };
    }

    fn initWithFailModels(fail_models: []const []const u8, response: []const u8) ModelAwareMock {
        var mock = ModelAwareMock{
            .response = response,
        };
        const copy_len = @min(fail_models.len, mock.fail_models_buf.len);
        for (fail_models[0..copy_len], 0..) |m, i| {
            mock.fail_models_buf[i] = m;
        }
        mock.fail_models_len = copy_len;
        return mock;
    }

    fn failsModel(self: *const ModelAwareMock, model: []const u8) bool {
        for (self.fail_models_buf[0..self.fail_models_len]) |m| {
            if (std.mem.eql(u8, m, model)) return true;
        }
        return false;
    }

    fn recordModel(self: *ModelAwareMock, model: []const u8) void {
        if (self.models_seen_len < self.models_seen_buf.len) {
            self.models_seen_buf[self.models_seen_len] = model;
            self.models_seen_len += 1;
        }
    }

    fn modelsSeen(self: *const ModelAwareMock) []const []const u8 {
        return self.models_seen_buf[0..self.models_seen_len];
    }

    fn modelChatWithSystem(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *ModelAwareMock = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        self.recordModel(model);
        if (self.failsModel(model)) {
            return error.ModelUnavailable;
        }
        return self.response;
    }

    fn modelChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *ModelAwareMock = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        self.recordModel(model);
        if (self.failsModel(model)) {
            return error.ModelUnavailable;
        }
        return ChatResponse{ .content = try allocator.dupe(u8, self.response) };
    }

    fn modelSupportsNativeTools(ptr: *anyopaque) bool {
        const self: *ModelAwareMock = @ptrCast(@alignCast(ptr));
        return self.supports_tools;
    }

    fn modelSupportsVision(ptr: *anyopaque) bool {
        const self: *ModelAwareMock = @ptrCast(@alignCast(ptr));
        return self.supports_vision;
    }

    fn modelEstimateTokens(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        _: ChatRequest,
        model: []const u8,
    ) anyerror!root.TokenEstimateResult {
        const self: *ModelAwareMock = @ptrCast(@alignCast(ptr));
        self.estimate_count += 1;
        self.recordModel(model);
        if (self.failsModel(model)) {
            return error.UnsupportedOperation;
        }
        return .{
            .prompt_tokens = self.estimated_prompt_tokens,
            .total_tokens = self.estimated_prompt_tokens,
        };
    }

    fn modelGetName(_: *anyopaque) []const u8 {
        return "ModelAwareMock";
    }

    fn modelDeinit(_: *anyopaque) void {}
};

const StreamingMockProvider = struct {
    name: []const u8 = "StreamingMock",
    chat_count: u32 = 0,
    stream_count: u32 = 0,
    fail_stream_until: u32 = 0,
    fail_error: anyerror = error.Timeout,
    emit_partial_before_error: bool = false,
    supports_tools: bool = false,
    supports_vision: bool = true,
    supports_streaming: bool = true,
    supports_sensitive_streaming: bool = false,
    response: []const u8 = "streamed response",
    models_seen_buf: [16][]const u8 = undefined,
    models_seen_len: usize = 0,
    fail_models_buf: [8][]const u8 = undefined,
    fail_models_len: usize = 0,

    const vtable_stream = Provider.VTable{
        .chatWithSystem = streamMockChatWithSystem,
        .chat = streamMockChat,
        .supportsNativeTools = streamMockSupportsNativeTools,
        .supports_streaming = streamMockSupportsStreaming,
        .supports_sensitive_streaming_for_request = streamMockSupportsSensitiveStreaming,
        .supports_vision = streamMockSupportsVision,
        .getName = streamMockGetName,
        .deinit = streamMockDeinit,
        .stream_chat = streamMockStreamChat,
    };

    fn toProvider(self: *StreamingMockProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_stream };
    }

    fn initWithFailModels(name: []const u8, fail_models: []const []const u8, response: []const u8) StreamingMockProvider {
        var mock = StreamingMockProvider{
            .name = name,
            .response = response,
        };
        const copy_len = @min(fail_models.len, mock.fail_models_buf.len);
        for (fail_models[0..copy_len], 0..) |fail_model, i| {
            mock.fail_models_buf[i] = fail_model;
        }
        mock.fail_models_len = copy_len;
        return mock;
    }

    fn failsModel(self: *const StreamingMockProvider, model: []const u8) bool {
        for (self.fail_models_buf[0..self.fail_models_len]) |fail_model| {
            if (std.mem.eql(u8, fail_model, model)) return true;
        }
        return false;
    }

    fn recordModel(self: *StreamingMockProvider, model: []const u8) void {
        if (self.models_seen_len < self.models_seen_buf.len) {
            self.models_seen_buf[self.models_seen_len] = model;
            self.models_seen_len += 1;
        }
    }

    fn modelsSeen(self: *const StreamingMockProvider) []const []const u8 {
        return self.models_seen_buf[0..self.models_seen_len];
    }

    fn streamMockChatWithSystem(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        self.chat_count += 1;
        self.recordModel(model);
        return allocator.dupe(u8, self.response);
    }

    fn streamMockChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        self.chat_count += 1;
        self.recordModel(model);
        return ChatResponse{ .content = try allocator.dupe(u8, self.response) };
    }

    fn streamMockSupportsNativeTools(ptr: *anyopaque) bool {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        return self.supports_tools;
    }

    fn streamMockSupportsStreaming(ptr: *anyopaque) bool {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        return self.supports_streaming;
    }

    fn streamMockSupportsSensitiveStreaming(ptr: *anyopaque, _: ChatRequest) bool {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        return self.supports_sensitive_streaming;
    }

    fn streamMockSupportsVision(ptr: *anyopaque) bool {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        return self.supports_vision;
    }

    fn streamMockGetName(ptr: *anyopaque) []const u8 {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        return self.name;
    }

    fn streamMockDeinit(_: *anyopaque) void {}

    fn streamMockStreamChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        model: []const u8,
        _: f64,
        callback: StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!StreamChatResult {
        const self: *StreamingMockProvider = @ptrCast(@alignCast(ptr));
        self.stream_count += 1;
        self.recordModel(model);

        if (self.stream_count <= self.fail_stream_until or self.failsModel(model)) {
            if (self.emit_partial_before_error) {
                callback(callback_ctx, StreamChunk.textDelta("partial"));
            }
            return self.fail_error;
        }

        callback(callback_ctx, StreamChunk.textDelta(self.response));
        callback(callback_ctx, StreamChunk.finalChunk());
        return .{
            .content = try allocator.dupe(u8, self.response),
            .model = model,
        };
    }
};

const StreamCollector = struct {
    text: [256]u8 = undefined,
    text_len: usize = 0,
    non_final_chunks: u32 = 0,
    final_chunks: u32 = 0,

    fn onChunk(ctx: *anyopaque, chunk: StreamChunk) void {
        const self: *StreamCollector = @ptrCast(@alignCast(ctx));
        if (chunk.is_final) {
            self.final_chunks += 1;
            return;
        }
        self.non_final_chunks += 1;
        const remaining = self.text.len - self.text_len;
        const copy_len = @min(remaining, chunk.delta.len);
        @memcpy(self.text[self.text_len .. self.text_len + copy_len], chunk.delta[0..copy_len]);
        self.text_len += copy_len;
    }

    fn textSlice(self: *const StreamCollector) []const u8 {
        return self.text[0..self.text_len];
    }
};

test "ReliableProvider vtable succeeds without retry" {
    var mock = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = true };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 3, 50);
    const prov = reliable.provider();

    const result = try prov.chatWithSystem(std.testing.allocator, null, "hello", "test-model", 0.7);
    try std.testing.expectEqualStrings("mock response", result);
    try std.testing.expect(mock.call_count == 1);
}

test "ReliableProvider vtable retries then recovers" {
    var mock = MockInnerProvider{ .call_count = 0, .fail_until = 2, .supports_tools = false };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 3, 50);
    const prov = reliable.provider();

    const result = try prov.chatWithSystem(std.testing.allocator, "system", "hello", "model", 0.5);
    try std.testing.expectEqualStrings("mock response", result);
    // Should have been called 3 times: 2 failures + 1 success
    try std.testing.expect(mock.call_count == 3);
}

test "ReliableProvider vtable exhausts retries and returns error" {
    var mock = MockInnerProvider{ .call_count = 0, .fail_until = 100, .supports_tools = false };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 2, 50);
    const prov = reliable.provider();

    const result = prov.chatWithSystem(std.testing.allocator, null, "hello", "model", 0.5);
    try std.testing.expectError(error.AllProvidersFailed, result);
    // max_retries=2 means 3 attempts (0, 1, 2)
    try std.testing.expect(mock.call_count == 3);
}

test "ReliableProvider propagates context errors for recovery" {
    var mock = MockInnerProvider{
        .call_count = 0,
        .fail_until = 100,
        .fail_error = error.ContextLengthExceeded,
        .supports_tools = false,
    };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 1, 50);
    const prov = reliable.provider();

    const result = prov.chatWithSystem(std.testing.allocator, null, "hello", "model", 0.5);
    try std.testing.expectError(error.ContextLengthExceeded, result);
}

test "ReliableProvider vtable chat retries then recovers" {
    var mock = MockInnerProvider{ .call_count = 0, .fail_until = 1, .supports_tools = true };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 2, 50);
    const prov = reliable.provider();

    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const request = ChatRequest{ .messages = &msgs };
    const result = try prov.chat(std.testing.allocator, request, "model", 0.5);
    defer if (result.content) |c| std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("mock chat", result.content.?);
    try std.testing.expect(mock.call_count == 2);
}

test "ReliableProvider vtable delegates supportsNativeTools" {
    var mock_yes = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = true };
    var reliable_yes = ReliableProvider.initWithProvider(mock_yes.toProvider(), 0, 50);
    try std.testing.expect(reliable_yes.provider().supportsNativeTools() == true);

    var mock_no = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = false };
    var reliable_no = ReliableProvider.initWithProvider(mock_no.toProvider(), 0, 50);
    try std.testing.expect(reliable_no.provider().supportsNativeTools() == false);
}

test "ReliableProvider supportsStreaming when wrapped provider streams" {
    var streamer = StreamingMockProvider{};
    var reliable = ReliableProvider.initWithProvider(streamer.toProvider(), 0, 50);
    try std.testing.expect(reliable.provider().supportsStreaming());
}

test "ReliableProvider streamChat succeeds on primary provider" {
    var primary = StreamingMockProvider{ .name = "primary", .response = "primary stream" };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50);
    const prov = reliable.provider();

    var collector = StreamCollector{};
    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const request = ChatRequest{ .messages = &msgs, .model = "model" };
    const result = try prov.streamChat(std.testing.allocator, request, "model", 0.7, StreamCollector.onChunk, @ptrCast(&collector));
    defer if (result.content) |content| std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("primary stream", collector.textSlice());
    try std.testing.expectEqualStrings("primary stream", result.content.?);
    try std.testing.expectEqual(@as(u32, 1), collector.non_final_chunks);
    try std.testing.expectEqual(@as(u32, 1), collector.final_chunks);
    try std.testing.expectEqual(@as(u32, 1), primary.stream_count);
}

test "ReliableProvider streamChat falls back to extra provider before first token" {
    var primary = StreamingMockProvider{
        .name = "primary",
        .fail_stream_until = 10,
        .fail_error = error.Timeout,
    };
    var fallback = StreamingMockProvider{ .name = "fallback", .response = "fallback stream" };
    const extras = [_]ProviderEntry{
        .{ .name = "fallback", .provider = fallback.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 2, 50).withExtras(&extras);
    const prov = reliable.provider();

    var collector = StreamCollector{};
    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const request = ChatRequest{ .messages = &msgs, .model = "model" };
    const result = try prov.streamChat(std.testing.allocator, request, "model", 0.7, StreamCollector.onChunk, @ptrCast(&collector));
    defer if (result.content) |content| std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("fallback stream", collector.textSlice());
    try std.testing.expectEqual(@as(u32, 1), primary.stream_count);
    try std.testing.expectEqual(@as(u32, 1), fallback.stream_count);
}

test "ReliableProvider streamChat falls back to model alternative before first token" {
    var primary = StreamingMockProvider.initWithFailModels(
        "primary",
        &.{"moonshotai/Kimi-K2.5"},
        "model fallback stream",
    );
    const model_fallbacks = [_]ModelFallbackEntry{
        .{ .model = "moonshotai/Kimi-K2.5", .fallbacks = &.{"moonshotai/kimi-k2.5"} },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50).withModelFallbacks(&model_fallbacks);
    const prov = reliable.provider();

    var collector = StreamCollector{};
    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const request = ChatRequest{ .messages = &msgs, .model = "moonshotai/Kimi-K2.5" };
    const result = try prov.streamChat(
        std.testing.allocator,
        request,
        "moonshotai/Kimi-K2.5",
        0.7,
        StreamCollector.onChunk,
        @ptrCast(&collector),
    );
    defer if (result.content) |content| std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("model fallback stream", collector.textSlice());
    try std.testing.expectEqual(@as(u32, 2), primary.stream_count);
    const models_seen = primary.modelsSeen();
    try std.testing.expectEqual(@as(usize, 2), models_seen.len);
    try std.testing.expectEqualStrings("moonshotai/Kimi-K2.5", models_seen[0]);
    try std.testing.expectEqualStrings("moonshotai/kimi-k2.5", models_seen[1]);
}

test "ReliableProvider streamChat does not fallback after first token" {
    var primary = StreamingMockProvider{
        .name = "primary",
        .fail_stream_until = 10,
        .fail_error = error.Timeout,
        .emit_partial_before_error = true,
    };
    var fallback = StreamingMockProvider{ .name = "fallback", .response = "fallback stream" };
    const extras = [_]ProviderEntry{
        .{ .name = "fallback", .provider = fallback.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 1, 50).withExtras(&extras);
    const prov = reliable.provider();

    var collector = StreamCollector{};
    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const request = ChatRequest{ .messages = &msgs, .model = "model" };
    const result = prov.streamChat(std.testing.allocator, request, "model", 0.7, StreamCollector.onChunk, @ptrCast(&collector));

    try std.testing.expectError(error.Timeout, result);
    try std.testing.expectEqualStrings("partial", collector.textSlice());
    try std.testing.expectEqual(@as(u32, 0), fallback.stream_count);
}

test "ReliableProvider supportsVision checks full provider chain" {
    var inner = MockInnerProvider{
        .call_count = 0,
        .fail_until = 0,
        .supports_tools = false,
        .supports_vision = false,
    };
    var extra = MockInnerProvider{
        .call_count = 0,
        .fail_until = 0,
        .supports_tools = false,
        .supports_vision = true,
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };

    var reliable = ReliableProvider.initWithProvider(inner.toProvider(), 0, 50).withExtras(&extras);
    const prov = reliable.provider();
    try std.testing.expect(prov.supportsVision());
    try std.testing.expect(prov.supportsVisionForModel("any-model"));
}

test "ReliableProvider vtable delegates getName" {
    var mock = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = false };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 0, 50);
    try std.testing.expectEqualStrings("MockProvider", reliable.provider().getName());
}

test "ReliableProvider vtable zero retries fails immediately" {
    var mock = MockInnerProvider{ .call_count = 0, .fail_until = 100, .supports_tools = false };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 0, 50);
    const prov = reliable.provider();

    const result = prov.chatWithSystem(std.testing.allocator, null, "hello", "model", 0.5);
    try std.testing.expectError(error.AllProvidersFailed, result);
    // With 0 retries, only 1 attempt
    try std.testing.expect(mock.call_count == 1);
}

test "ReliableProvider timeout returns timeout error" {
    var mock = MockInnerProvider{
        .call_count = 0,
        .fail_until = 100,
        .fail_error = error.Timeout,
        .supports_tools = false,
    };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 0, 50);
    const prov = reliable.provider();

    const result = prov.chatWithSystem(std.testing.allocator, null, "hello", "model", 0.5);
    try std.testing.expectError(error.Timeout, result);
    try std.testing.expect(mock.call_count == 1);
}

test "ReliableProvider timeout with fallback skips same-provider retries" {
    var primary = MockInnerProvider{
        .call_count = 0,
        .fail_until = 100,
        .fail_error = error.Timeout,
        .supports_tools = false,
    };
    var fallback = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = true };

    const extras = [_]ProviderEntry{
        .{ .name = "fallback", .provider = fallback.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 2, 50).withExtras(&extras);
    const prov = reliable.provider();

    const result = try prov.chatWithSystem(std.testing.allocator, null, "hello", "model", 0.7);
    try std.testing.expectEqualStrings("mock response", result);
    try std.testing.expect(primary.call_count == 1);
    try std.testing.expect(fallback.call_count == 1);
}

// ════════════════════════════════════════════════════════════════════════════
// New tests: model fallback chain
// ════════════════════════════════════════════════════════════════════════════

test "modelChain with no fallbacks returns single element" {
    const reliable = ReliableProvider.init(&.{}, 0, 50);
    const chain = try reliable.modelChain(std.testing.allocator, "claude-opus");
    defer std.testing.allocator.free(chain);

    try std.testing.expect(chain.len == 1);
    try std.testing.expectEqualStrings("claude-opus", chain[0]);
}

test "modelChain with fallbacks returns full chain" {
    const fallbacks = [_]ModelFallbackEntry{
        .{ .model = "claude-opus", .fallbacks = &.{ "claude-sonnet", "claude-haiku" } },
    };
    const reliable = ReliableProvider.init(&.{}, 0, 50).withModelFallbacks(&fallbacks);
    const chain = try reliable.modelChain(std.testing.allocator, "claude-opus");
    defer std.testing.allocator.free(chain);

    try std.testing.expect(chain.len == 3);
    try std.testing.expectEqualStrings("claude-opus", chain[0]);
    try std.testing.expectEqualStrings("claude-sonnet", chain[1]);
    try std.testing.expectEqualStrings("claude-haiku", chain[2]);
}

test "modelChain with unrelated model returns single element" {
    const fallbacks = [_]ModelFallbackEntry{
        .{ .model = "claude-opus", .fallbacks = &.{"claude-sonnet"} },
    };
    const reliable = ReliableProvider.init(&.{}, 0, 50).withModelFallbacks(&fallbacks);
    const chain = try reliable.modelChain(std.testing.allocator, "gpt-4");
    defer std.testing.allocator.free(chain);

    try std.testing.expect(chain.len == 1);
    try std.testing.expectEqualStrings("gpt-4", chain[0]);
}

test "withModelFallbacks builder preserves other fields" {
    const fallbacks = [_]ModelFallbackEntry{
        .{ .model = "m1", .fallbacks = &.{"m2"} },
    };
    const reliable = ReliableProvider.init(&.{}, 3, 200).withModelFallbacks(&fallbacks);
    try std.testing.expect(reliable.max_retries == 3);
    try std.testing.expect(reliable.base_backoff_ms == 200);
    try std.testing.expect(reliable.model_fallbacks.len == 1);
}

test "withExtras builder preserves other fields" {
    var mock = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = false };
    const extras = [_]ProviderEntry{
        .{ .name = "fallback", .provider = mock.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 2, 100).withExtras(&extras);
    try std.testing.expect(reliable.max_retries == 2);
    try std.testing.expect(reliable.base_backoff_ms == 100);
    try std.testing.expect(reliable.extras.len == 1);
    try std.testing.expectEqualStrings("fallback", reliable.extras[0].name);
    _ = &reliable;
}

test "warmup calls inner and extras" {
    var inner_mock = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = false };
    var extra_mock = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = false };

    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra_mock.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(inner_mock.toProvider(), 0, 50).withExtras(&extras);
    const prov = reliable.provider();
    prov.warmup();

    try std.testing.expect(inner_mock.warmed_up);
    try std.testing.expect(extra_mock.warmed_up);
}

test "multi-provider fallback: primary fails, extra succeeds" {
    var primary = MockInnerProvider{ .call_count = 0, .fail_until = 100, .supports_tools = false };
    var fallback = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = true };

    const extras = [_]ProviderEntry{
        .{ .name = "fallback", .provider = fallback.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50).withExtras(&extras);
    const prov = reliable.provider();

    const result = try prov.chatWithSystem(std.testing.allocator, null, "hello", "model", 0.7);
    try std.testing.expectEqualStrings("mock response", result);
    // Primary tried once (0 retries), then fallback succeeded on first try
    try std.testing.expect(primary.call_count == 1);
    try std.testing.expect(fallback.call_count == 1);
}

test "model failover tries fallback model" {
    const fail_models = [_][]const u8{"claude-opus"};
    var mock = ModelAwareMock.initWithFailModels(&fail_models, "ok from sonnet");
    const fb = [_]ModelFallbackEntry{
        .{ .model = "claude-opus", .fallbacks = &.{"claude-sonnet"} },
    };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 0, 50).withModelFallbacks(&fb);
    const prov = reliable.provider();

    const result = try prov.chatWithSystem(std.testing.allocator, null, "hello", "claude-opus", 0.7);
    try std.testing.expectEqualStrings("ok from sonnet", result);

    const seen = mock.modelsSeen();
    try std.testing.expect(seen.len == 2);
    try std.testing.expectEqualStrings("claude-opus", seen[0]);
    try std.testing.expectEqualStrings("claude-sonnet", seen[1]);
}

test "model failover all models fail returns error" {
    const fail_models = [_][]const u8{ "model-a", "model-b", "model-c" };
    var mock = ModelAwareMock.initWithFailModels(&fail_models, "never");
    const fb = [_]ModelFallbackEntry{
        .{ .model = "model-a", .fallbacks = &.{ "model-b", "model-c" } },
    };
    var reliable = ReliableProvider.initWithProvider(mock.toProvider(), 0, 50).withModelFallbacks(&fb);
    const prov = reliable.provider();

    const result = prov.chatWithSystem(std.testing.allocator, null, "hello", "model-a", 0.7);
    try std.testing.expectError(error.AllProvidersFailed, result);

    const seen = mock.modelsSeen();
    try std.testing.expect(seen.len == 3);
}

test "supportsNativeTools returns true if any extra supports it" {
    var inner_mock = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = false };
    var extra_mock = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = true };

    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra_mock.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(inner_mock.toProvider(), 0, 50).withExtras(&extras);
    try std.testing.expect(reliable.provider().supportsNativeTools() == true);
}

test "provider selection policy: exact requests report native tool support from the primary only" {
    var primary = MockInnerProvider{
        .call_count = 0,
        .fail_until = 0,
        .supports_tools = false,
    };
    var extra = MockInnerProvider{
        .call_count = 0,
        .fail_until = 0,
        .supports_tools = true,
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50)
        .withExtras(&extras);
    const provider = reliable.provider();

    const messages = [_]root.ChatMessage{root.ChatMessage.user("request")};
    const ordinary = ChatRequest{ .messages = &messages };
    const restricted = ChatRequest{
        .messages = &messages,
        .provider_selection_policy = .exact_primary_and_model,
    };

    try std.testing.expect(provider.supportsNativeTools());
    try std.testing.expect(provider.supportsNativeToolsForRequest(ordinary));
    try std.testing.expect(!provider.supportsNativeToolsForRequest(restricted));
}

test "multi-provider chat fallback" {
    var primary = MockInnerProvider{ .call_count = 0, .fail_until = 100, .supports_tools = false };
    var fallback = MockInnerProvider{ .call_count = 0, .fail_until = 0, .supports_tools = true };

    const extras = [_]ProviderEntry{
        .{ .name = "fallback", .provider = fallback.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50).withExtras(&extras);
    const prov = reliable.provider();

    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const request = ChatRequest{ .messages = &msgs };
    const result = try prov.chat(std.testing.allocator, request, "model", 0.5);
    defer if (result.content) |c| std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("mock chat", result.content.?);
    try std.testing.expect(primary.call_count == 1);
    try std.testing.expect(fallback.call_count == 1);
}

test "provider selection policy: exact primary and model keeps chat retries on the requested route" {
    const blocked_models = [_][]const u8{ "sensitive-model", "alternate-model" };
    var primary = ModelAwareMock.initWithFailModels(&blocked_models, "never");
    var extra = ModelAwareMock.initWithFailModels(&blocked_models, "never");
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    const model_fallbacks = [_]ModelFallbackEntry{
        .{ .model = "sensitive-model", .fallbacks = &.{"alternate-model"} },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 1, 50)
        .withExtras(&extras)
        .withModelFallbacks(&model_fallbacks);

    const messages = [_]root.ChatMessage{root.ChatMessage.user("transcript")};
    const request = ChatRequest{
        .messages = &messages,
        .model = "sensitive-model",
        .provider_selection_policy = .exact_primary_and_model,
    };
    try std.testing.expectError(
        error.AllProvidersFailed,
        reliable.provider().chat(std.testing.allocator, request, "sensitive-model", 0.7),
    );

    const primary_models = primary.modelsSeen();
    try std.testing.expectEqual(@as(usize, 2), primary_models.len);
    try std.testing.expectEqualStrings("sensitive-model", primary_models[0]);
    try std.testing.expectEqualStrings("sensitive-model", primary_models[1]);
    try std.testing.expectEqual(@as(u32, 0), extra.call_count);
    try std.testing.expectEqual(@as(usize, 0), extra.modelsSeen().len);
}

test "provider selection policy: exact primary and model retries primary timeouts instead of widening" {
    var primary = MockInnerProvider{
        .call_count = 0,
        .fail_until = 1,
        .fail_error = error.Timeout,
        .supports_tools = false,
    };
    var extra = MockInnerProvider{
        .call_count = 0,
        .fail_until = 0,
        .supports_tools = false,
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 1, 50)
        .withExtras(&extras);

    const messages = [_]root.ChatMessage{root.ChatMessage.user("transcript")};
    const request = ChatRequest{
        .messages = &messages,
        .model = "sensitive-model",
        .provider_selection_policy = .exact_primary_and_model,
    };
    const result = try reliable.provider().chat(
        std.testing.allocator,
        request,
        "sensitive-model",
        0.7,
    );
    defer if (result.content) |content| std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("mock chat", result.content.?);
    try std.testing.expectEqual(@as(u32, 2), primary.call_count);
    try std.testing.expectEqual(@as(u32, 0), extra.call_count);
}

test "provider selection policy: exact stream never downgrades to blocking chat or an extra provider" {
    var primary = StreamingMockProvider{
        .name = "primary",
        .supports_streaming = false,
        .supports_sensitive_streaming = true,
        .response = "primary blocking response",
    };
    var extra = StreamingMockProvider{
        .name = "extra",
        .response = "extra streamed response",
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    const model_fallbacks = [_]ModelFallbackEntry{
        .{ .model = "sensitive-model", .fallbacks = &.{"alternate-model"} },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50)
        .withExtras(&extras)
        .withModelFallbacks(&model_fallbacks);

    var collector = StreamCollector{};
    const messages = [_]root.ChatMessage{root.ChatMessage.user("transcript")};
    const request = ChatRequest{
        .messages = &messages,
        .model = "sensitive-model",
        .provider_selection_policy = .exact_primary_and_model,
    };
    try std.testing.expect(!reliable.provider().supportsSensitiveStreamingForRequest(request));
    try std.testing.expectError(
        error.UnsupportedOperation,
        reliable.provider().streamChat(
            std.testing.allocator,
            request,
            "sensitive-model",
            0.7,
            StreamCollector.onChunk,
            @ptrCast(&collector),
        ),
    );
    try std.testing.expectEqualStrings("", collector.textSlice());
    try std.testing.expectEqual(@as(u32, 0), collector.non_final_chunks);
    try std.testing.expectEqual(@as(u32, 0), collector.final_chunks);
    try std.testing.expectEqual(@as(u32, 0), primary.stream_count);
    try std.testing.expectEqual(@as(u32, 0), primary.chat_count);
    try std.testing.expectEqual(@as(usize, 0), primary.modelsSeen().len);
    try std.testing.expectEqual(@as(u32, 0), extra.stream_count);
    try std.testing.expectEqual(@as(u32, 0), extra.chat_count);
    try std.testing.expectEqual(@as(usize, 0), extra.modelsSeen().len);
}

test "provider selection policy: pre-token exact stream failure never falls back to blocking chat" {
    var primary = StreamingMockProvider{
        .name = "primary",
        .fail_stream_until = 10,
        .fail_error = error.Timeout,
        .supports_sensitive_streaming = true,
        .response = "primary blocking response",
    };
    var extra = StreamingMockProvider{
        .name = "extra",
        .response = "extra streamed response",
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    const model_fallbacks = [_]ModelFallbackEntry{
        .{ .model = "sensitive-model", .fallbacks = &.{"alternate-model"} },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 1, 50)
        .withExtras(&extras)
        .withModelFallbacks(&model_fallbacks);

    var collector = StreamCollector{};
    const messages = [_]root.ChatMessage{root.ChatMessage.user("transcript")};
    const request = ChatRequest{
        .messages = &messages,
        .model = "sensitive-model",
        .provider_selection_policy = .exact_primary_and_model,
    };
    try std.testing.expect(reliable.provider().supportsSensitiveStreamingForRequest(request));
    try std.testing.expectError(
        error.Timeout,
        reliable.provider().streamChat(
            std.testing.allocator,
            request,
            "sensitive-model",
            0.7,
            StreamCollector.onChunk,
            @ptrCast(&collector),
        ),
    );
    try std.testing.expectEqualStrings("", collector.textSlice());
    try std.testing.expectEqual(@as(u32, 0), collector.non_final_chunks);
    try std.testing.expectEqual(@as(u32, 0), collector.final_chunks);
    try std.testing.expectEqual(@as(u32, 2), primary.stream_count);
    try std.testing.expectEqual(@as(u32, 0), primary.chat_count);
    try std.testing.expectEqual(@as(usize, 2), primary.modelsSeen().len);
    try std.testing.expectEqualStrings("sensitive-model", primary.modelsSeen()[0]);
    try std.testing.expectEqualStrings("sensitive-model", primary.modelsSeen()[1]);
    try std.testing.expectEqual(@as(u32, 0), extra.stream_count);
    try std.testing.expectEqual(@as(u32, 0), extra.chat_count);
    try std.testing.expectEqual(@as(usize, 0), extra.modelsSeen().len);
}

test "provider selection policy: partial stream failure never starts blocking chat or an extra provider" {
    var primary = StreamingMockProvider{
        .name = "primary",
        .fail_stream_until = 10,
        .fail_error = error.Timeout,
        .emit_partial_before_error = true,
        .response = "must not be emitted",
    };
    var extra = StreamingMockProvider{
        .name = "extra",
        .response = "must not be emitted",
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50)
        .withExtras(&extras);

    var collector = StreamCollector{};
    const messages = [_]root.ChatMessage{root.ChatMessage.user("transcript")};
    const request = ChatRequest{
        .messages = &messages,
        .model = "sensitive-model",
        .provider_selection_policy = .exact_primary_and_model,
    };
    try std.testing.expectError(
        error.Timeout,
        reliable.provider().streamChat(
            std.testing.allocator,
            request,
            "sensitive-model",
            0.7,
            StreamCollector.onChunk,
            @ptrCast(&collector),
        ),
    );

    try std.testing.expectEqualStrings("partial", collector.textSlice());
    try std.testing.expectEqual(@as(u32, 1), collector.non_final_chunks);
    try std.testing.expectEqual(@as(u32, 0), collector.final_chunks);
    try std.testing.expectEqual(@as(u32, 1), primary.stream_count);
    try std.testing.expectEqual(@as(u32, 0), primary.chat_count);
    try std.testing.expectEqual(@as(u32, 0), extra.stream_count);
    try std.testing.expectEqual(@as(u32, 0), extra.chat_count);
}

test "provider selection policy: exact primary and model keeps token estimates on the requested route" {
    const primary_fail_models = [_][]const u8{"sensitive-model"};
    var primary = ModelAwareMock.initWithFailModels(&primary_fail_models, "unused");
    var extra = ModelAwareMock{
        .estimated_prompt_tokens = 99,
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    const model_fallbacks = [_]ModelFallbackEntry{
        .{ .model = "sensitive-model", .fallbacks = &.{"alternate-model"} },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50)
        .withExtras(&extras)
        .withModelFallbacks(&model_fallbacks);

    const messages = [_]root.ChatMessage{root.ChatMessage.user("transcript")};
    const request = ChatRequest{
        .messages = &messages,
        .model = "sensitive-model",
        .provider_selection_policy = .exact_primary_and_model,
    };
    try std.testing.expectError(
        error.UnsupportedOperation,
        reliable.provider().estimateTokens(std.testing.allocator, request, "sensitive-model"),
    );

    try std.testing.expectEqual(@as(u32, 1), primary.estimate_count);
    try std.testing.expectEqual(@as(usize, 1), primary.modelsSeen().len);
    try std.testing.expectEqualStrings("sensitive-model", primary.modelsSeen()[0]);
    try std.testing.expectEqual(@as(u32, 0), extra.estimate_count);
    try std.testing.expectEqual(@as(usize, 0), extra.modelsSeen().len);
}

test "provider selection policy: ordinary token estimates still use the fallback chain" {
    const primary_fail_models = [_][]const u8{"ordinary-model"};
    var primary = ModelAwareMock.initWithFailModels(&primary_fail_models, "unused");
    var extra = ModelAwareMock{
        .estimated_prompt_tokens = 99,
    };
    const extras = [_]ProviderEntry{
        .{ .name = "extra", .provider = extra.toProvider() },
    };
    var reliable = ReliableProvider.initWithProvider(primary.toProvider(), 0, 50)
        .withExtras(&extras);

    const messages = [_]root.ChatMessage{root.ChatMessage.user("ordinary request")};
    const request = ChatRequest{
        .messages = &messages,
        .model = "ordinary-model",
    };
    const estimate = (try reliable.provider().estimateTokens(
        std.testing.allocator,
        request,
        "ordinary-model",
    )).?;

    try std.testing.expectEqual(@as(u32, 99), estimate.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 1), primary.estimate_count);
    try std.testing.expectEqual(@as(u32, 1), extra.estimate_count);
    try std.testing.expectEqualStrings("ordinary-model", extra.modelsSeen()[0]);
}
