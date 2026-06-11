const std = @import("std");
const platform = @import("platform.zig");
pub const config_types = @import("config_types.zig");
pub const config_parse = @import("config_parse.zig");

// ── Re-export all types so downstream `@import("config.zig").Foo` still works ──

pub const AutonomyLevel = config_types.AutonomyLevel;
// HardwareTransport: removed D19 (2026-04-25) — V1 stripped the hardware surface.
pub const SandboxBackend = config_types.SandboxBackend;
pub const DiagnosticsConfig = config_types.DiagnosticsConfig;
pub const AutonomyConfig = config_types.AutonomyConfig;
pub const DockerRuntimeConfig = config_types.DockerRuntimeConfig;
pub const RuntimeConfig = config_types.RuntimeConfig;
pub const TransportMode = config_types.TransportMode;
pub const PoolConfig = config_types.PoolConfig;
pub const ResolverConfig = config_types.ResolverConfig;
pub const TransportConfig = config_types.TransportConfig;
pub const NetworkConfig = config_types.NetworkConfig;
pub const AppProfile = config_types.AppProfile;
pub const ModelFallbackEntry = config_types.ModelFallbackEntry;
pub const ReliabilityConfig = config_types.ReliabilityConfig;
pub const SchedulerConfig = config_types.SchedulerConfig;
pub const AgentConfig = config_types.AgentConfig;
pub const SidecarConfig = config_types.SidecarConfig;
pub const ModelRouteConfig = config_types.ModelRouteConfig;
pub const HeartbeatConfig = config_types.HeartbeatConfig;
pub const CronConfig = config_types.CronConfig;
pub const TelegramReceiveMode = config_types.TelegramReceiveMode;
pub const TelegramConfig = config_types.TelegramConfig;
pub const DiscordConfig = config_types.DiscordConfig;
pub const SlackReceiveMode = config_types.SlackReceiveMode;
pub const SlackConfig = config_types.SlackConfig;
pub const WebhookConfig = config_types.WebhookConfig;
pub const IMessageConfig = config_types.IMessageConfig;
pub const MatrixConfig = config_types.MatrixConfig;
pub const MattermostConfig = config_types.MattermostConfig;
pub const WhatsAppConfig = config_types.WhatsAppConfig;
pub const IrcConfig = config_types.IrcConfig;
pub const LarkReceiveMode = config_types.LarkReceiveMode;
pub const LarkConfig = config_types.LarkConfig;
// DingTalkConfig: deleted Sprint 8 (S8.4+S8.6, 2026-04-24).
pub const SignalConfig = config_types.SignalConfig;
pub const EmailConfig = config_types.EmailConfig;
pub const LineConfig = config_types.LineConfig;
pub const QQGroupPolicy = config_types.QQGroupPolicy;
pub const QQConfig = config_types.QQConfig;
pub const OneBotConfig = config_types.OneBotConfig;
pub const MaixCamConfig = config_types.MaixCamConfig;
pub const ChannelsConfig = config_types.ChannelsConfig;
pub const MemoryConfig = config_types.MemoryConfig;
pub const TunnelConfig = config_types.TunnelConfig;
pub const GatewayConfig = config_types.GatewayConfig;
pub const TenantConfig = config_types.TenantConfig;
pub const StateConfig = config_types.StateConfig;
pub const ComposioConfig = config_types.ComposioConfig;
pub const BrandingConfig = config_types.BrandingConfig;
pub const SecretsConfig = config_types.SecretsConfig;
pub const BrowserComputerUseConfig = config_types.BrowserComputerUseConfig;
pub const BrowserConfig = config_types.BrowserConfig;
pub const HttpRequestConfig = config_types.HttpRequestConfig;
pub const IdentityConfig = config_types.IdentityConfig;
pub const CostConfig = config_types.CostConfig;
pub const PeripheralBoardConfig = config_types.PeripheralBoardConfig;
pub const PeripheralsConfig = config_types.PeripheralsConfig;
// HardwareConfig: removed D19 (2026-04-25) alongside HardwareTransport.
pub const SandboxConfig = config_types.SandboxConfig;
pub const ResourceLimitsConfig = config_types.ResourceLimitsConfig;
pub const AuditConfig = config_types.AuditConfig;
pub const SecurityConfig = config_types.SecurityConfig;
pub const DelegateAgentConfig = config_types.DelegateAgentConfig;
pub const NamedAgentConfig = config_types.NamedAgentConfig;
pub const McpServerConfig = config_types.McpServerConfig;
pub const ApiSpecConfig = config_types.ApiSpecConfig;
pub const ModelPricing = config_types.ModelPricing;
pub const ToolsConfig = config_types.ToolsConfig;
pub const ProviderEntry = config_types.ProviderEntry;
pub const AudioMediaConfig = config_types.AudioMediaConfig;
pub const DmScope = config_types.DmScope;
pub const IdentityLink = config_types.IdentityLink;
pub const SessionConfig = config_types.SessionConfig;

// ── Top-level Config ────────────────────────────────────────────

pub const Config = struct {
    const ResolvedConfigPaths = struct {
        config_path: []const u8,
        config_dir: []const u8,
        workspace_dir: []const u8,
    };
    // Computed paths (not serialized)
    workspace_dir: []const u8,
    config_path: []const u8,

    // Top-level fields
    profile: []const u8 = "standard",
    providers: []const ProviderEntry = &.{},
    audio_media: AudioMediaConfig = .{},
    default_provider: []const u8 = "openrouter",
    default_model: ?[]const u8 = null,
    legacy_default_provider_detected: bool = false,
    legacy_default_model_detected: bool = false,
    default_temperature: f64 = 0.7,
    reasoning_effort: ?[]const u8 = null,

    // Model routing and delegate agents
    model_routes: []const ModelRouteConfig = &.{},
    agents: []const NamedAgentConfig = &.{},
    agent_bindings: []const @import("agent_routing.zig").AgentBinding = &.{},
    mcp_servers: []const McpServerConfig = &.{},
    /// Sprint 3 — operator-registered OpenAPI 3.x specs. The agent
    /// reaches these via the `openapi` tool. Operator-owned (NOT
    /// tenant-settable) for the same reason as `mcp_servers`: a spec
    /// declares an outbound integration + a credential reference.
    api_specs: []const ApiSpecConfig = &.{},

    // Nested sub-configs
    diagnostics: DiagnosticsConfig = .{},
    autonomy: AutonomyConfig = .{},
    runtime: RuntimeConfig = .{},
    network: NetworkConfig = .{},
    reliability: ReliabilityConfig = .{},
    scheduler: SchedulerConfig = .{},
    agent: AgentConfig = .{},
    sidecar: SidecarConfig = .{},
    heartbeat: HeartbeatConfig = .{},
    cron: CronConfig = .{},
    channels: ChannelsConfig = .{},
    memory: MemoryConfig = .{},
    tunnel: TunnelConfig = .{},
    gateway: GatewayConfig = .{},
    tenant: TenantConfig = .{},
    state: StateConfig = .{},
    composio: ComposioConfig = .{},
    /// Operator-deployed brand typography (Thmanyah by default). Empty
    /// font_dir disables; otherwise produce_document applies @font-face /
    /// pandoc --variable mainfont so PDF/DOCX/PPTX/HTML output matches the
    /// operator's house font. See `BrandingConfig` for details.
    branding: BrandingConfig = .{},
    secrets: SecretsConfig = .{},
    browser: BrowserConfig = .{},
    http_request: HttpRequestConfig = .{},
    identity: IdentityConfig = .{},
    cost: CostConfig = .{},
    peripherals: PeripheralsConfig = .{},
    // hardware: HardwareConfig field removed D19 (2026-04-25).
    security: SecurityConfig = .{},
    tools: ToolsConfig = .{},
    session: SessionConfig = .{},

    // Convenience aliases for backward-compat flat access used by other modules.
    // These are set during load() to mirror nested values.
    temperature: f64 = 0.7,
    max_tokens: ?u32 = null,
    memory_backend: []const u8 = config_types.MemoryConfig.DEFAULT_MEMORY_BACKEND,
    memory_auto_save: bool = true,
    heartbeat_enabled: bool = false,
    heartbeat_interval_minutes: u32 = 60,
    gateway_host: []const u8 = "127.0.0.1",
    gateway_port: u16 = 3000,
    workspace_only: bool = true,
    max_actions_per_hour: u32 = 100,

    allocator: std.mem.Allocator,
    arena: ?*std.heap.ArenaAllocator = null,

    /// Look up a provider's API key from the providers list.
    pub fn getProviderKey(self: *const Config, name: []const u8) ?[]const u8 {
        for (self.providers) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.api_key;
        }
        return null;
    }

    /// Convenience: API key for the default_provider.
    pub fn defaultProviderKey(self: *const Config) ?[]const u8 {
        return self.getProviderKey(self.default_provider);
    }

    fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
    }

    fn isPlaceholderSecretValue(value: []const u8) bool {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return true;

        if (startsWithIgnoreCase(trimmed, "REPLACE_WITH_")) return true;
        if (eqlIgnoreCase(trimmed, "changeme")) return true;
        if (eqlIgnoreCase(trimmed, "change-me")) return true;
        if (eqlIgnoreCase(trimmed, "default")) return true;
        if (eqlIgnoreCase(trimmed, "replace_with_strong_random_token")) return true;
        if (eqlIgnoreCase(trimmed, "replace_with_provider_key")) return true;
        if (eqlIgnoreCase(trimmed, "replace_with_postgres_connection_string")) return true;
        if (eqlIgnoreCase(trimmed, "test-internal-token")) return true;
        if (eqlIgnoreCase(trimmed, "dev-internal-token")) return true;
        return false;
    }

    fn hasUsableTogetherApiKey(self: *const Config) bool {
        if (self.getProviderKey("together-ai")) |key| {
            if (!isPlaceholderSecretValue(key)) return true;
        }
        if (self.getProviderKey("together")) |key| {
            if (!isPlaceholderSecretValue(key)) return true;
        }
        if (std.process.getEnvVarOwned(self.allocator, "TOGETHER_API_KEY")) |key| {
            defer self.allocator.free(key);
            return !isPlaceholderSecretValue(key);
        } else |_| {}
        return false;
    }

    /// Look up a provider's base_url from the providers list.
    pub fn getProviderBaseUrl(self: *const Config, name: []const u8) ?[]const u8 {
        for (self.providers) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.base_url;
        }
        return null;
    }

    /// Look up whether a provider supports native tool calls.
    /// Returns true (default) if provider is not in the list.
    pub fn getProviderNativeTools(self: *const Config, name: []const u8) bool {
        for (self.providers) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.native_tools;
        }
        return true;
    }

    /// Sync flat convenience fields from the nested sub-configs.
    pub fn syncFlatFields(self: *Config) void {
        self.temperature = self.default_temperature;
        self.memory_backend = self.memory.backend;
        self.memory_auto_save = self.memory.auto_save;
        self.heartbeat_enabled = self.heartbeat.enabled;
        self.heartbeat_interval_minutes = self.heartbeat.interval_minutes;
        self.gateway_host = self.gateway.host;
        self.gateway_port = self.gateway.port;
        self.workspace_only = self.autonomy.workspace_only;
        self.max_actions_per_hour = self.autonomy.max_actions_per_hour;
    }

    fn setInternalServiceToken(self: *Config, token: []const u8) !void {
        const tokens = try self.allocator.alloc([]const u8, 1);
        tokens[0] = token;
        self.gateway.internal_service_tokens = tokens;
    }

    fn applySecretRuntimeOverrides(
        self: *Config,
        internal_service_token: ?[]const u8,
        postgres_connection_string: ?[]const u8,
    ) void {
        if (internal_service_token) |token| {
            self.setInternalServiceToken(token) catch return;
        }
        if (postgres_connection_string) |connection_string| {
            self.state.postgres.connection_string = connection_string;
        }
    }

    /// Apply top-level profile defaults after parsing explicit config values.
    /// Only set values that are still at their default, so direct config always wins.
    pub fn applyProfileDefaults(self: *Config) !void {
        switch (AppProfile.fromString(self.profile)) {
            .standard => {},
            .zaki_bot => {
                // Primary provider is Moonshot's native API; Kimi K2.6's
                // bare model ID on Moonshot is `kimi-k2.6` (Together's ID
                // `moonshotai/Kimi-K2.6` is used only on the Together
                // fallback route, carried via the `provider/model` ref form
                // in `fallback_providers` below).
                //
                // `default_provider` has no nullable "unset" state — its
                // struct default is `"openrouter"`. Treat that sentinel as
                // "operator did not pin a provider" and switch it to
                // `moonshot`; an explicit `agents.defaults.model.primary`
                // with any other provider prefix overrides it (parse sets
                // `default_provider` before `applyProfileDefaults` runs).
                const provider_unset = std.mem.eql(u8, self.default_provider, "openrouter");
                if (self.default_model == null) {
                    self.default_model = try self.allocator.dupe(u8, "kimi-k2.6");
                    if (provider_unset) {
                        self.default_provider = try self.allocator.dupe(u8, "moonshot");
                    }
                }
                // `reasoning_effort` is the unified mode knob (fast/balanced/
                // deep → low/medium/high); `medium` = the "balanced" default.
                //
                // HONEST NOTE (probed 2026-05-21, 6 live calls): Together does
                // NOT currently honor `reasoning_effort` OR `thinking` for
                // Kimi K2.6 — it reasons at a model-decided depth regardless.
                // This default is intent-correct and takes effect if/when the
                // provider honors it (or the model/provider changes); the
                // mode-knob no-op is tracked separately, not wired here.
                //
                // On the Moonshot native route the request shape switches
                // to Kimi's `thinking` field (see compatible.zig); the
                // provider drops `reasoning_effort` there. This default is
                // still set so the Together fallback route and any
                // context_snapshot report stay consistent.
                if (self.reasoning_effort == null) {
                    self.reasoning_effort = try self.allocator.dupe(u8, "medium");
                }
                // Together stays a cross-provider fallback. The entry uses
                // the `provider/model` ref form: Moonshot and Together
                // disagree on the model ID (`kimi-k2.6` vs
                // `moonshotai/Kimi-K2.6`), so the ref carries Together's own
                // ID after the provider name. runtime_bundle.zig splits it
                // into a provider name + a per-provider model override, and
                // the reliability layer applies that override when it fails
                // over to Together — so Together receives ITS model ID, not
                // Moonshot's. Only injected on the `kimi-k2.6` default; an
                // operator who pinned a different model gets no auto-fallback
                // (the ref's hard-coded Together ID would not match).
                if ((provider_unset or std.mem.eql(u8, self.default_provider, "moonshot")) and
                    self.reliability.fallback_providers.len == 0 and
                    self.default_model != null and
                    std.mem.eql(u8, self.default_model.?, "kimi-k2.6"))
                {
                    self.reliability.fallback_providers = &.{"together/moonshotai/Kimi-K2.6"};
                }
                if (std.mem.eql(u8, self.memory.profile, "markdown_only")) {
                    self.memory.profile = "postgres_hybrid";
                }
                if (std.mem.eql(u8, self.memory.search.provider, "none")) {
                    self.memory.search.provider = "together";
                }
                // Finding #4 footgun guard: the SidecarConfig struct default
                // (groq/llama-3.1-8b-instant) is Groq's free 6000-TPM tier —
                // a compaction fires ~15 sidecar calls in seconds, exhausts
                // the TPM budget, and every boundary extraction past the
                // first fails. zaki_bot already runs on Together (see
                // fallback_providers + memory.search above), so default the
                // extraction sidecar to a capable Together model unless the
                // operator pinned their own `sidecar` block. An operator who
                // genuinely wants a different sidecar sets provider/model in
                // config.json and this guard does not fire.
                if (std.mem.eql(u8, self.sidecar.provider, "groq") and
                    std.mem.eql(u8, self.sidecar.model, "llama-3.1-8b-instant"))
                {
                    self.sidecar.provider = try self.allocator.dupe(u8, "together");
                    self.sidecar.model = try self.allocator.dupe(u8, "meta-llama/Llama-3.3-70B-Instruct-Turbo");
                }
            },
        }
        self.memory.applyProfileDefaults();
        if (AppProfile.fromString(self.profile) == .zaki_bot) {
            if (!self.memory.search.query.hybrid.mmr.enabled) {
                self.memory.search.query.hybrid.mmr.enabled = true;
            }
            if (!self.memory.search.query.hybrid.temporal_decay.enabled) {
                self.memory.search.query.hybrid.temporal_decay.enabled = true;
            }
            // Adaptive retrieval selects query strategy (keyword vs. hybrid) based on
            // query characteristics. Enable by default for zaki_bot — it's cheap at
            // query time and measurably improves recall for short/semantic queries.
            if (!self.memory.retrieval_stages.adaptive_retrieval_enabled) {
                self.memory.retrieval_stages.adaptive_retrieval_enabled = true;
            }

            // 2026-05-24 (v1.14.21 final-sprint activation) — flip 7 dormant
            // feature flags to default-on for the zaki_bot commercial profile.
            // Each flag is end-to-end wired today but was opt-in for historical
            // operator-decides reasons. For SaaS commercial v1 the default
            // posture is "everything on, central meter throttles." Operators
            // on standalone deploys can still set explicit `false` in
            // config.json to opt out per flag.
            //
            // Rationale per flag:
            //   - audio_media: Whisper STT (groq whisper-large-v3) + Telegram
            //     TTS. Fails soft if no API key. Voice notes "just work."
            //   - heartbeat: starts the proactive engine. Per-user
            //     `proactive_updates` flag (user_settings, default true) still
            //     gates per-tenant. WITHOUT this flip the user-level toggle
            //     has nothing to gate — silent-off.
            //   - cron: starts cron-job loading. WITHOUT this flip jobs
            //     created via the `schedule` tool silently never fire. This
            //     was a real blocker.
            //   - response_cache + semantic_cache: end-to-end wired at
            //     agent/root.zig:3488 + :4557 via mem_rt.semanticCache().get.
            //     Storage cost only; near-zero hit rate on personal-brain
            //     workload but covers recurring dream/heartbeat patterns.
            //   - composio: surfaces Gmail/Calendar/Drive/Slack/Notion tools
            //     when API key wired. Fails soft if no key.
            //   - cost: per-tenant cost tracking infrastructure. Pairs with
            //     the central usage meter at zaki-prod (spend SSE event in
            //     done frame, v1.14.20).
            //
            // What we leave OFF (the audit conclusions):
            //   - summarizer.enabled — legacy V1.5 sliding-window path;
            //     Pass A (boundary extraction) + Pass C (session-end) +
            //     extraction_persist + TTL are the modern replacement and
            //     enabling the legacy summarizer risks duplicate writes
            //     fighting the canonical pipeline.
            //   - browser.enabled — current tool only does `open` (system
            //     browser launch, useless for SaaS) + `read` (curl-equivalent
            //     of web_fetch). CDP actions stripped at v1.14.13 per
            //     §14.5 honesty. Flip when Playwright integration ships
            //     (server-side MCP OR browser extension).
            //   - snapshot_enabled, peripherals, query_expansion,
            //     llm_reranker, qmd — deliberately off; see deferred-register.
            if (!self.audio_media.enabled) self.audio_media.enabled = true;
            if (!self.heartbeat.enabled) self.heartbeat.enabled = true;
            if (!self.cron.enabled) self.cron.enabled = true;
            if (!self.memory.response_cache.enabled) self.memory.response_cache.enabled = true;
            if (!self.memory.semantic_cache.enabled) self.memory.semantic_cache.enabled = true;
            if (!self.composio.enabled) self.composio.enabled = true;
            if (!self.cost.enabled) self.cost.enabled = true;
        }
    }

    pub fn load(backing_allocator: std.mem.Allocator) !Config {
        // Use an arena so deinit() can free everything in one shot.
        const arena_ptr = try backing_allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer {
            arena_ptr.deinit();
            backing_allocator.destroy(arena_ptr);
        }
        const allocator = arena_ptr.allocator();

        const home = platform.getHomeDir(allocator) catch return error.NoHomeDir;
        const config_path_override = std.process.getEnvVarOwned(allocator, "NULLALIS_CONFIG_PATH") catch null;
        const resolved_paths = try resolveConfigPaths(allocator, home, config_path_override);

        var cfg = Config{
            .workspace_dir = resolved_paths.workspace_dir,
            .config_path = resolved_paths.config_path,
            .allocator = allocator,
            .arena = arena_ptr,
        };

        // Try to read existing config file
        if (std.fs.openFileAbsolute(resolved_paths.config_path, .{})) |file| {
            defer file.close();
            const content = try file.readToEndAlloc(allocator, 1024 * 64);
            cfg.parseJson(content) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {}, // malformed JSON — use defaults for unparsed fields
            };
        } else |_| {
            // Config file doesn't exist yet — use defaults
        }

        // Environment variable overrides
        cfg.applyEnvOverrides();

        // Sync flat fields from nested structs
        cfg.syncFlatFields();

        return cfg;
    }

    fn resolveConfigPaths(
        allocator: std.mem.Allocator,
        home: []const u8,
        config_path_override: ?[]const u8,
    ) !ResolvedConfigPaths {
        const default_config_dir = try std.fs.path.join(allocator, &.{ home, ".nullalis" });
        const default_config_path = try std.fs.path.join(allocator, &.{ default_config_dir, "config.json" });
        const default_workspace_dir = try std.fs.path.join(allocator, &.{ default_config_dir, "workspace" });

        const override_raw = config_path_override orelse {
            return .{
                .config_path = default_config_path,
                .config_dir = default_config_dir,
                .workspace_dir = default_workspace_dir,
            };
        };

        const override_trimmed = std.mem.trim(u8, override_raw, " \t\r\n");
        if (override_trimmed.len == 0) {
            return .{
                .config_path = default_config_path,
                .config_dir = default_config_dir,
                .workspace_dir = default_workspace_dir,
            };
        }
        if (!std.fs.path.isAbsolute(override_trimmed)) {
            std.log.warn("NULLALIS_CONFIG_PATH ignored: expected absolute path, got '{s}'", .{override_trimmed});
            return .{
                .config_path = default_config_path,
                .config_dir = default_config_dir,
                .workspace_dir = default_workspace_dir,
            };
        }

        const override_path = try allocator.dupe(u8, override_trimmed);
        const override_dir = std.fs.path.dirname(override_path) orelse {
            std.log.warn("NULLALIS_CONFIG_PATH ignored: missing parent directory '{s}'", .{override_trimmed});
            return .{
                .config_path = default_config_path,
                .config_dir = default_config_dir,
                .workspace_dir = default_workspace_dir,
            };
        };
        const override_dir_owned = try allocator.dupe(u8, override_dir);
        const override_workspace = try std.fs.path.join(allocator, &.{ override_dir_owned, "workspace" });
        return .{
            .config_path = override_path,
            .config_dir = override_dir_owned,
            .workspace_dir = override_workspace,
        };
    }

    /// Free all memory owned by this config (arena + heap pointer).
    /// No-op for configs created without load() (e.g. in tests).
    pub fn deinit(self: *Config) void {
        if (self.arena) |arena| {
            const backing = arena.child_allocator;
            arena.deinit();
            backing.destroy(arena);
            self.arena = null;
        }
    }

    /// Parse a JSON array of strings into an allocated slice.
    pub fn parseStringArray(self: *Config, arr: std.json.Array) ![]const []const u8 {
        return config_parse.parseStringArray(self.allocator, arr);
    }

    pub fn parseJson(self: *Config, content: []const u8) !void {
        return config_parse.parseJson(self, content);
    }

    fn writeChannelFieldSeparator(w: *std.Io.Writer, wrote_any: bool) !void {
        if (wrote_any) {
            try w.print(",\n", .{});
        }
    }

    fn writeIndentedMultilineJson(w: *std.Io.Writer, json: []const u8, continuation_indent: []const u8) !void {
        var start: usize = 0;
        while (start < json.len) {
            const rel_nl = std.mem.indexOfScalar(u8, json[start..], '\n');
            if (rel_nl) |nl| {
                const end = start + nl;
                try w.writeAll(json[start..end]);
                try w.writeAll("\n");
                const next_start = end + 1;
                if (next_start < json.len) {
                    try w.writeAll(continuation_indent);
                }
                start = next_start;
            } else {
                try w.writeAll(json[start..]);
                break;
            }
        }
    }

    fn writePrettyJsonInline(allocator: std.mem.Allocator, w: *std.Io.Writer, value: anytype, continuation_indent: []const u8) !void {
        const pretty = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
        defer allocator.free(pretty);
        try writeIndentedMultilineJson(w, pretty, continuation_indent);
    }

    fn writeChannelAccounts(allocator: std.mem.Allocator, w: *std.Io.Writer, channel_name: []const u8, accounts: anytype) !void {
        try w.print("    {f}: {{\n      \"accounts\": {{", .{std.json.fmt(channel_name, .{})});
        for (accounts, 0..) |account, i| {
            if (i == 0) {
                try w.print("\n", .{});
            } else {
                try w.print(",\n", .{});
            }
            const account_id = if (comptime @hasField(@TypeOf(account), "account_id"))
                account.account_id
            else
                "default";
            try w.print("        {f}: ", .{std.json.fmt(account_id, .{})});
            try writePrettyJsonInline(allocator, w, account, "        ");
        }
        try w.print("\n      }}\n    }}", .{});
    }

    fn writeChannelsSection(self: *const Config, w: *std.Io.Writer) !void {
        try w.print("  \"channels\": {{\n", .{});

        var wrote_any = false;
        if (!self.channels.cli) {
            try writeChannelFieldSeparator(w, wrote_any);
            try w.print("    \"cli\": false", .{});
            wrote_any = true;
        }

        inline for (std.meta.fields(ChannelsConfig)) |field| {
            if (comptime std.mem.eql(u8, field.name, "cli")) continue;

            const channel_value = @field(self.channels, field.name);
            switch (@typeInfo(field.type)) {
                .pointer => |ptr| {
                    if (ptr.size == .slice and channel_value.len > 0) {
                        try writeChannelFieldSeparator(w, wrote_any);
                        try writeChannelAccounts(self.allocator, w, field.name, channel_value);
                        wrote_any = true;
                    }
                },
                .optional => {
                    if (channel_value) |val| {
                        try writeChannelFieldSeparator(w, wrote_any);
                        try w.print("    {f}: ", .{std.json.fmt(field.name, .{})});
                        try writePrettyJsonInline(self.allocator, w, val, "    ");
                        wrote_any = true;
                    }
                },
                else => {},
            }
        }

        if (wrote_any) {
            try w.print("\n  }},\n", .{});
        } else {
            try w.print("  }},\n", .{});
        }
    }

    fn writeStringArray(w: *std.Io.Writer, values: []const []const u8) !void {
        try w.print("[", .{});
        for (values, 0..) |value, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("{f}", .{std.json.fmt(value, .{})});
        }
        try w.print("]", .{});
    }

    fn writeReliabilitySection(self: *const Config, w: *std.Io.Writer) !void {
        try w.print("  \"reliability\": {{\n", .{});
        try w.print("    \"provider_retries\": {d},\n", .{self.reliability.provider_retries});
        try w.print("    \"provider_backoff_ms\": {d},\n", .{self.reliability.provider_backoff_ms});
        try w.print("    \"channel_initial_backoff_secs\": {d},\n", .{self.reliability.channel_initial_backoff_secs});
        try w.print("    \"channel_max_backoff_secs\": {d},\n", .{self.reliability.channel_max_backoff_secs});
        try w.print("    \"scheduler_poll_secs\": {d},\n", .{self.reliability.scheduler_poll_secs});
        try w.print("    \"scheduler_retries\": {d},\n", .{self.reliability.scheduler_retries});
        try w.print("    \"shutdown_flush_budget_ms\": {d},\n", .{self.reliability.shutdown_flush_budget_ms});
        try w.print("    \"shutdown_join_timeout_ms\": {d},\n", .{self.reliability.shutdown_join_timeout_ms});

        try w.print("    \"fallback_providers\": ", .{});
        try writeStringArray(w, self.reliability.fallback_providers);
        try w.print(",\n", .{});

        try w.print("    \"api_keys\": ", .{});
        try writeStringArray(w, self.reliability.api_keys);
        try w.print(",\n", .{});

        try w.print("    \"model_fallbacks\": [", .{});
        for (self.reliability.model_fallbacks, 0..) |entry, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("{{\"model\": {f}, \"fallbacks\": ", .{std.json.fmt(entry.model, .{})});
            try writeStringArray(w, entry.fallbacks);
            try w.print("}}", .{});
        }
        try w.print("]\n", .{});
        try w.print("  }},\n", .{});
    }

    fn writeMcpServersSection(self: *const Config, w: *std.Io.Writer) !void {
        try w.print("  \"mcp_servers\": {{\n", .{});
        for (self.mcp_servers, 0..) |server, i| {
            try w.print("    {f}: {{", .{std.json.fmt(server.name, .{})});
            // transport is emitted explicitly so a saved http server reloads
            // as http even though it has no `command`.
            switch (server.transport) {
                .stdio => {
                    try w.print("\"command\": {f}", .{std.json.fmt(server.command, .{})});
                    if (server.args.len > 0) {
                        try w.print(", \"args\": {f}", .{std.json.fmt(server.args, .{})});
                    }
                },
                .http => {
                    try w.print("\"transport\": \"http\", \"url\": {f}", .{std.json.fmt(server.url, .{})});
                },
            }
            if (server.env.len > 0) {
                try w.print(", \"env\": {{", .{});
                for (server.env, 0..) |entry, env_i| {
                    if (env_i > 0) try w.print(", ", .{});
                    try w.print("{f}: {f}", .{
                        std.json.fmt(entry.key, .{}),
                        std.json.fmt(entry.value, .{}),
                    });
                }
                try w.print("}}", .{});
            }
            if (server.headers.len > 0) {
                try w.print(", \"headers\": {{", .{});
                for (server.headers, 0..) |entry, hdr_i| {
                    if (hdr_i > 0) try w.print(", ", .{});
                    try w.print("{f}: {f}", .{
                        std.json.fmt(entry.key, .{}),
                        std.json.fmt(entry.value, .{}),
                    });
                }
                try w.print("}}", .{});
            }
            // S7.11 — emit read_line_timeout_secs unconditionally so an
            // operator's non-default value survives a Config.save round-trip
            // (Config.save is reachable from the onboarding flow). Omitting it
            // silently reverted the field to the 30s struct default on reload.
            try w.print(", \"read_line_timeout_secs\": {d}", .{server.read_line_timeout_secs});
            try w.print("}}", .{});
            if (i + 1 < self.mcp_servers.len) try w.print(",", .{});
            try w.print("\n", .{});
        }
        try w.print("  }},\n", .{});
    }

    /// Sprint 3 — serialize the `api_specs` block in the object-of-objects
    /// form (keyed by id) so a Config.save round-trip preserves operator
    /// OpenAPI registrations.
    fn writeApiSpecsSection(self: *const Config, w: *std.Io.Writer) !void {
        try w.print("  \"api_specs\": {{\n", .{});
        for (self.api_specs, 0..) |s, i| {
            try w.print("    {f}: {{", .{std.json.fmt(s.id, .{})});
            if (s.spec_url.len > 0) {
                try w.print("\"spec_url\": {f}", .{std.json.fmt(s.spec_url, .{})});
            } else {
                try w.print("\"spec_path\": {f}", .{std.json.fmt(s.spec_path, .{})});
            }
            if (s.base_url.len > 0) {
                try w.print(", \"base_url\": {f}", .{std.json.fmt(s.base_url, .{})});
            }
            if (s.auth_ref.len > 0) {
                try w.print(", \"auth_ref\": {f}", .{std.json.fmt(s.auth_ref, .{})});
            }
            try w.print(", \"mode\": \"{s}\"", .{s.mode.toSlice()});
            try w.print("}}", .{});
            if (i + 1 < self.api_specs.len) try w.print(",", .{});
            try w.print("\n", .{});
        }
        try w.print("  }},\n", .{});
    }

    /// Apply NULLALIS_* environment variable overrides (with NULLCLAW_*
    /// fallback through D28 sunset on 2026-05-15).
    pub fn applyEnvOverrides(self: *Config) void {
        const env_rebrand = @import("env_rebrand.zig");

        // Provider
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_PROVIDER", "NULLCLAW_PROVIDER") catch null) |prov| {
            self.default_provider = prov;
        }

        // Model
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_MODEL", "NULLCLAW_MODEL") catch null) |model| {
            self.default_model = model;
        }

        // Temperature
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_TEMPERATURE", "NULLCLAW_TEMPERATURE") catch null) |temp_str| {
            defer self.allocator.free(temp_str);
            if (std.fmt.parseFloat(f64, temp_str)) |temp| {
                if (temp >= 0.0 and temp <= 2.0) {
                    self.default_temperature = temp;
                }
            } else |_| {}
        }

        // Gateway port
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_GATEWAY_PORT", "NULLCLAW_GATEWAY_PORT") catch null) |port_str| {
            defer self.allocator.free(port_str);
            if (std.fmt.parseInt(u16, port_str, 10)) |port| {
                self.gateway.port = port;
            } else |_| {}
        }

        // Gateway host
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_GATEWAY_HOST", "NULLCLAW_GATEWAY_HOST") catch null) |host| {
            self.gateway.host = host;
        }

        // Workspace
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_WORKSPACE", "NULLCLAW_WORKSPACE") catch null) |ws| {
            self.workspace_dir = ws;
        }

        // Allow public bind
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_ALLOW_PUBLIC_BIND", "NULLCLAW_ALLOW_PUBLIC_BIND") catch null) |val| {
            defer self.allocator.free(val);
            self.gateway.allow_public_bind = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        }

        // Internal service token: NULLALIS_* primary, NULLCLAW_* fallback,
        // then unprefixed INTERNAL_SERVICE_TOKEN as the legacy 3rd-tier
        // fallback. Unprefixed names stay alive past sunset (operators may
        // share env across products); only the NULLCLAW_*-prefixed name
        // gets the deprecation banner.
        var internal_service_token: ?[]const u8 = null;
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_INTERNAL_SERVICE_TOKEN", "NULLCLAW_INTERNAL_SERVICE_TOKEN") catch null) |token| {
            internal_service_token = token;
        } else {
            if (std.process.getEnvVarOwned(self.allocator, "INTERNAL_SERVICE_TOKEN")) |token| {
                internal_service_token = token;
            } else |_| {}
        }

        var postgres_connection_string: ?[]const u8 = null;
        if (env_rebrand.getEnvOwnedWithRebrand(self.allocator, "NULLALIS_POSTGRES_CONNECTION_STRING", "NULLCLAW_POSTGRES_CONNECTION_STRING") catch null) |connection_string| {
            postgres_connection_string = connection_string;
        } else {
            if (std.process.getEnvVarOwned(self.allocator, "POSTGRES_CONNECTION_STRING")) |connection_string| {
                postgres_connection_string = connection_string;
            } else |_| {}
        }

        self.applySecretRuntimeOverrides(internal_service_token, postgres_connection_string);
    }

    /// Save config as JSON to the config_path.
    pub fn save(self: *const Config) !void {
        const dir = std.fs.path.dirname(self.config_path) orelse return error.InvalidConfigPath;

        // Ensure parent directory exists
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file = try std.fs.createFileAbsolute(self.config_path, .{});
        defer file.close();

        var buf: [8192]u8 = undefined;
        var bw = file.writer(&buf);
        const w = &bw.interface;

        try w.print("{{\n", .{});

        // Top-level fields
        try w.print("  \"profile\": {f},\n", .{std.json.fmt(self.profile, .{})});
        try w.print("  \"default_temperature\": {d:.1},\n", .{self.default_temperature});
        if (self.reasoning_effort) |value| {
            try w.print("  \"reasoning_effort\": {f},\n", .{std.json.fmt(value, .{})});
        }

        // models.providers
        if (self.providers.len > 0) {
            try w.print("  \"models\": {{\n    \"providers\": {{\n", .{});
            for (self.providers, 0..) |entry, i| {
                try w.print("      {f}: {{", .{std.json.fmt(entry.name, .{})});
                var has_field = false;
                if (entry.api_key) |key| {
                    try w.print("\"api_key\": {f}", .{std.json.fmt(key, .{})});
                    has_field = true;
                }
                if (entry.base_url) |base| {
                    if (has_field) try w.print(", ", .{});
                    try w.print("\"base_url\": {f}", .{std.json.fmt(base, .{})});
                    has_field = true;
                }
                if (comptime @hasField(ProviderEntry, "native_tools")) {
                    if (!entry.native_tools) {
                        if (has_field) try w.print(", ", .{});
                        try w.print("\"native_tools\": false", .{});
                        has_field = true;
                    }
                }
                try w.print("}}", .{});
                if (i + 1 < self.providers.len) try w.print(",", .{});
                try w.print("\n", .{});
            }
            try w.print("    }}\n  }},\n", .{});
        }

        if (self.model_routes.len > 0) {
            try w.print("  \"model_routes\": {f},\n", .{std.json.fmt(self.model_routes, .{})});
        }

        // agents.defaults (model + heartbeat) + agents.list
        {
            const has_model = self.default_model != null;
            const has_heartbeat = self.heartbeat.enabled or self.heartbeat.interval_minutes != 60;
            const has_agents = self.agents.len > 0;
            if (has_model or has_heartbeat or has_agents) {
                try w.print("  \"agents\": {{\n", .{});
                var wrote_agent_field = false;
                if (has_model or has_heartbeat) {
                    try w.print("    \"defaults\": {{\n", .{});
                    wrote_agent_field = true;
                }
                if (self.default_model) |model| {
                    const primary = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.default_provider, model });
                    defer self.allocator.free(primary);
                    try w.print("      \"model\": {{\"primary\": {f}}}", .{std.json.fmt(primary, .{})});
                    if (has_heartbeat) try w.print(",", .{});
                    try w.print("\n", .{});
                }
                if (has_heartbeat) {
                    try w.print("      \"heartbeat\": {{", .{});
                    // Convert interval_minutes to "every" string
                    const mins = self.heartbeat.interval_minutes;
                    if (mins >= 60 and mins % 60 == 0) {
                        try w.print("\"every\": \"{d}h\"", .{mins / 60});
                    } else {
                        try w.print("\"every\": \"{d}m\"", .{mins});
                    }
                    if (!self.heartbeat.enabled) {
                        try w.print(", \"enabled\": false", .{});
                    }
                    try w.print("}}\n", .{});
                }
                if (has_model or has_heartbeat) {
                    try w.print("    }}", .{});
                }
                if (has_agents) {
                    if (wrote_agent_field) {
                        try w.print(",\n", .{});
                    }
                    try w.print("    \"list\": {f}\n", .{std.json.fmt(self.agents, .{})});
                } else {
                    try w.print("\n", .{});
                }
                try w.print("  }},\n", .{});
            }
        }

        if (self.agent_bindings.len > 0) {
            try w.print("  \"bindings\": {f},\n", .{std.json.fmt(self.agent_bindings, .{})});
        }
        if (self.mcp_servers.len > 0) {
            try self.writeMcpServersSection(w);
        }
        if (self.api_specs.len > 0) {
            try self.writeApiSpecsSection(w);
        }

        // Diagnostics (with nested otel)
        try w.print("  \"diagnostics\": {{\n", .{});
        try w.print("    \"backend\": {f}", .{std.json.fmt(self.diagnostics.backend, .{})});
        if (self.diagnostics.otel_endpoint != null or self.diagnostics.otel_service_name != null) {
            try w.print(",\n    \"otel\": {{", .{});
            var otel_first = true;
            if (self.diagnostics.otel_endpoint) |ep| {
                try w.print("\"endpoint\": {f}", .{std.json.fmt(ep, .{})});
                otel_first = false;
            }
            if (self.diagnostics.otel_service_name) |sn| {
                if (!otel_first) try w.print(", ", .{});
                try w.print("\"service_name\": {f}", .{std.json.fmt(sn, .{})});
            }
            try w.print("}}", .{});
        }
        try w.print("\n  }},\n", .{});

        try w.print("  \"autonomy\": {f},\n", .{std.json.fmt(self.autonomy, .{})});
        try w.print("  \"runtime\": {f},\n", .{std.json.fmt(self.runtime, .{})});

        // Reliability
        try self.writeReliabilitySection(w);
        try w.print("  \"scheduler\": {f},\n", .{std.json.fmt(self.scheduler, .{})});
        try w.print("  \"agent\": {f},\n", .{std.json.fmt(.{
            .compact_context = self.agent.compact_context,
            .max_tool_iterations = self.agent.max_tool_iterations,
            .max_history_messages = self.agent.max_history_messages,
            .parallel_tools = self.agent.parallel_tools,
            .parallel_tools_rollout_percent = self.agent.parallel_tools_rollout_percent,
            .tool_dispatcher = self.agent.tool_dispatcher,
            .session_idle_timeout_secs = self.agent.session_idle_timeout_secs,
            .compaction_keep_recent = self.agent.compaction_keep_recent,
            .compaction_max_summary_chars = self.agent.compaction_max_summary_chars,
            .compaction_max_source_chars = self.agent.compaction_max_source_chars,
            .message_timeout_secs = self.agent.message_timeout_secs,
            .session_ttl_secs = self.agent.session_ttl_secs,
            .activation_mode = self.agent.activation_mode,
            .send_mode = self.agent.send_mode,
            .queue_mode = self.agent.queue_mode,
            .queue_debounce_ms = self.agent.queue_debounce_ms,
            .queue_cap = self.agent.queue_cap,
            .queue_drop = self.agent.queue_drop,
            .tts_mode = self.agent.tts_mode,
            .tts_provider = self.agent.tts_provider,
            .tts_limit_chars = self.agent.tts_limit_chars,
            .tts_summary = self.agent.tts_summary,
            .tts_audio = self.agent.tts_audio,
        }, .{})});

        // Channels
        try self.writeChannelsSection(w);

        try w.print("  \"memory\": {f},\n", .{std.json.fmt(self.memory, .{})});
        try w.print("  \"gateway\": {f},\n", .{std.json.fmt(self.gateway, .{})});
        try w.print("  \"tenant\": {f},\n", .{std.json.fmt(self.tenant, .{})});
        try w.print("  \"state\": {f},\n", .{std.json.fmt(self.state, .{})});
        try w.print("  \"tunnel\": {f},\n", .{std.json.fmt(self.tunnel, .{})});
        try w.print("  \"composio\": {f},\n", .{std.json.fmt(self.composio, .{})});
        try w.print("  \"secrets\": {f},\n", .{std.json.fmt(self.secrets, .{})});
        try w.print("  \"browser\": {f},\n", .{std.json.fmt(self.browser, .{})});
        try w.print("  \"http_request\": {f},\n", .{std.json.fmt(self.http_request, .{})});
        try w.print("  \"identity\": {f},\n", .{std.json.fmt(self.identity, .{})});
        try w.print("  \"cost\": {f},\n", .{std.json.fmt(self.cost, .{})});
        try w.print("  \"security\": {f},\n", .{std.json.fmt(self.security, .{})});
        try w.print("  \"peripherals\": {f},\n", .{std.json.fmt(self.peripherals, .{})});

        // Tools (with media.audio)
        try w.print("  \"tools\": {{\n", .{});
        try w.print("    \"shell_timeout_secs\": {d},\n", .{self.tools.shell_timeout_secs});
        try w.print("    \"shell_max_output_bytes\": {d},\n", .{self.tools.shell_max_output_bytes});
        try w.print("    \"max_file_size_bytes\": {d},\n", .{self.tools.max_file_size_bytes});
        try w.print("    \"web_fetch_max_chars\": {d}", .{self.tools.web_fetch_max_chars});
        if (self.tools.web_search_provider.len > 0) {
            try w.print(",\n    \"web_search_provider\": {f}", .{std.json.fmt(self.tools.web_search_provider, .{})});
        }
        if (self.tools.web_search_exa_api_key.len > 0) {
            try w.print(",\n    \"web_search_exa_api_key\": {f}", .{std.json.fmt(self.tools.web_search_exa_api_key, .{})});
        }
        if (self.tools.web_search_brave_api_key.len > 0) {
            try w.print(",\n    \"web_search_brave_api_key\": {f}", .{std.json.fmt(self.tools.web_search_brave_api_key, .{})});
        }
        // tools.media.audio
        {
            const am = self.audio_media;
            const is_default = am.enabled and
                std.mem.eql(u8, am.provider, "groq") and
                std.mem.eql(u8, am.model, "whisper-large-v3") and
                am.base_url == null and am.language == null;
            if (!is_default) {
                try w.print(",\n    \"media\": {{\n      \"audio\": {{\n", .{});
                try w.print("        \"enabled\": {s}", .{if (am.enabled) "true" else "false"});
                if (am.language) |lang| {
                    try w.print(",\n        \"language\": {f}", .{std.json.fmt(lang, .{})});
                }
                try w.print(",\n        \"models\": [{{\"provider\": {f}, \"model\": {f}", .{ std.json.fmt(am.provider, .{}), std.json.fmt(am.model, .{}) });
                if (am.base_url) |bu| {
                    try w.print(", \"base_url\": {f}", .{std.json.fmt(bu, .{})});
                }
                try w.print("}}]\n      }}\n    }}", .{});
            }
        }
        try w.print("\n  }},\n", .{});

        // "hardware" serialization removed D19 (2026-04-25) alongside the
        // HardwareConfig struct itself.
        try w.print("  \"session\": {f}\n", .{std.json.fmt(self.session, .{})});

        try w.print("}}\n", .{});
        try w.flush();
    }

    // ── Validation ──────────────────────────────────────────────

    pub const ValidationError = error{
        LegacyDefaultProviderField,
        LegacyDefaultModelField,
        InvalidDefaultModelPrimary,
        NoDefaultModel,
        TemperatureOutOfRange,
        InvalidPort,
        InvalidRetryCount,
        InvalidBackoffMs,
        MissingDefaultProviderConfig,
        MissingTogetherApiKey,
        MissingInternalServiceToken,
        InvalidInternalServiceToken,
        InvalidZakiBotStateBackend,
        MissingPostgresConnectionString,
        InvalidPostgresConnectionString,
    };

    pub fn validate(self: *const Config) ValidationError!void {
        if (self.legacy_default_provider_detected) {
            return ValidationError.LegacyDefaultProviderField;
        }
        if (self.legacy_default_model_detected) {
            return ValidationError.LegacyDefaultModelField;
        }
        if (self.default_provider.len == 0) {
            return ValidationError.InvalidDefaultModelPrimary;
        }
        if (self.default_model == null) {
            return ValidationError.NoDefaultModel;
        }
        if (self.default_temperature < 0.0 or self.default_temperature > 2.0) {
            return ValidationError.TemperatureOutOfRange;
        }
        if (self.gateway.port == 0) {
            return ValidationError.InvalidPort;
        }
        if (self.reliability.provider_retries > 100) {
            return ValidationError.InvalidRetryCount;
        }
        if (self.reliability.provider_backoff_ms > 600_000) {
            return ValidationError.InvalidBackoffMs;
        }
        if (AppProfile.fromString(self.profile) == .zaki_bot) {
            if (self.getProviderBaseUrl(self.default_provider) == null) {
                return ValidationError.MissingDefaultProviderConfig;
            }
            if ((std.mem.eql(u8, self.default_provider, "together") or std.mem.eql(u8, self.default_provider, "together-ai")) and !self.hasUsableTogetherApiKey()) {
                return ValidationError.MissingTogetherApiKey;
            }
            if (self.gateway.internal_service_tokens.len == 0) {
                return ValidationError.MissingInternalServiceToken;
            }
            for (self.gateway.internal_service_tokens) |token| {
                if (isPlaceholderSecretValue(token)) {
                    return ValidationError.InvalidInternalServiceToken;
                }
            }
            if (!std.mem.eql(u8, self.state.backend, "postgres")) {
                return ValidationError.InvalidZakiBotStateBackend;
            }
            if (self.state.postgres.connection_string.len == 0) {
                return ValidationError.MissingPostgresConnectionString;
            }
            if (isPlaceholderSecretValue(self.state.postgres.connection_string)) {
                return ValidationError.InvalidPostgresConnectionString;
            }
        }
    }

    /// Print a human-readable validation error to stderr.
    pub fn printValidationError(err: ValidationError) void {
        switch (err) {
            ValidationError.LegacyDefaultProviderField => std.debug.print(
                "Config error: top-level default_provider is not supported. Set agents.defaults.model.primary instead.\n",
                .{},
            ),
            ValidationError.LegacyDefaultModelField => std.debug.print(
                "Config error: top-level default_model is not supported. Set agents.defaults.model.primary instead.\n",
                .{},
            ),
            ValidationError.InvalidDefaultModelPrimary => std.debug.print(
                "Config error: agents.defaults.model.primary must be in \"provider/model\" format.\n",
                .{},
            ),
            ValidationError.NoDefaultModel => std.debug.print(
                "No default model configured. Set agents.defaults.model.primary in ~/.nullalis/config.json or run `nullalis onboard`.\n",
                .{},
            ),
            ValidationError.TemperatureOutOfRange => std.debug.print("Config error: temperature must be between 0.0 and 2.0.\n", .{}),
            ValidationError.InvalidPort => std.debug.print("Config error: gateway port must be non-zero.\n", .{}),
            ValidationError.InvalidRetryCount => std.debug.print("Config error: provider_retries must be <= 100.\n", .{}),
            ValidationError.InvalidBackoffMs => std.debug.print("Config error: provider_backoff_ms must be <= 600000.\n", .{}),
            ValidationError.MissingDefaultProviderConfig => std.debug.print(
                "Config error: the selected provider must exist under models.providers with a base_url in zaki_bot profile.\n",
                .{},
            ),
            ValidationError.MissingTogetherApiKey => std.debug.print(
                "Config error: zaki_bot profile requires a valid TOGETHER_API_KEY for together-ai.\n",
                .{},
            ),
            ValidationError.MissingInternalServiceToken => std.debug.print(
                "Config error: zaki_bot profile requires NULLALIS_INTERNAL_SERVICE_TOKEN (or INTERNAL_SERVICE_TOKEN; legacy NULLCLAW_INTERNAL_SERVICE_TOKEN sunsets 2026-05-15).\n",
                .{},
            ),
            ValidationError.InvalidInternalServiceToken => std.debug.print(
                "Config error: zaki_bot profile internal service token is empty or uses a placeholder value.\n",
                .{},
            ),
            ValidationError.InvalidZakiBotStateBackend => std.debug.print(
                "Config error: zaki_bot profile requires state.backend=postgres.\n",
                .{},
            ),
            ValidationError.MissingPostgresConnectionString => std.debug.print(
                "Config error: zaki_bot profile requires NULLALIS_POSTGRES_CONNECTION_STRING (or POSTGRES_CONNECTION_STRING; legacy NULLCLAW_POSTGRES_CONNECTION_STRING sunsets 2026-05-15).\n",
                .{},
            ),
            ValidationError.InvalidPostgresConnectionString => std.debug.print(
                "Config error: zaki_bot profile Postgres connection string is empty or uses a placeholder value.\n",
                .{},
            ),
        }
    }

    /// Print configured models summary to stderr (for startup banners).
    pub fn printModelConfig(self: *const Config) void {
        std.debug.print("  Model:    {s}\n", .{self.default_model orelse "(not set)"});
        std.debug.print("  Provider: {s}\n", .{self.default_provider});
        if (self.model_routes.len > 0) {
            std.debug.print("  Routes:   {d} configured\n", .{self.model_routes.len});
            for (self.model_routes) |r| {
                std.debug.print("            [{s}] {s}/{s}\n", .{ r.hint, r.provider, r.model });
            }
        }
        if (self.agents.len > 0) {
            std.debug.print("  Agents:   {d} configured\n", .{self.agents.len});
            for (self.agents) |a| {
                std.debug.print("            {s} → {s}/{s}\n", .{ a.name, a.provider, a.model });
            }
        }
    }
};

// ── Config field-exhaustiveness guard (findings #3/#4 follow-up) ──
//
// Findings #3 and #4 were the same class: a config surface (`sidecar`,
// `network`) that exists as a struct AND a `Config` field — but with NO
// parser in config_parse.zig, and nothing detecting the gap.
// `Config.sidecar` was permanently the struct default for months;
// finding #4 (the boundary-extraction cascade) traced straight back to it.
//
// This comptime guard makes that class un-mergeable: every top-level
// `Config` field MUST be registered below. Add a field without
// registering it and the build fails — forcing the author to decide
// whether it needs a parser (.json_parsed), is runtime/derived state
// (.runtime_or_derived), or is a known-unwired gap (.decorative_pending,
// which is tracked in docs/CONFIG_CONTROL_PLANE_AUDIT.md — not silent).
//
// Scope: TOP-LEVEL fields only. Nested-struct Class-D bugs (e.g.
// AgentConfig.extraction) are out of scope — a recursive walk is a
// separate, larger effort. The top-level walk catches the #3/#4 class.
const ConfigFieldDisposition = enum {
    /// config_parse.zig reads this from config.json.
    json_parsed,
    /// Set at construction, or derived/synced from a nested block at
    /// runtime, or a parse-detected flag — never read directly from JSON.
    runtime_or_derived,
    /// KNOWN unparsed config surface — a tracked follow-up, not a silent
    /// gap. See docs/CONFIG_CONTROL_PLANE_AUDIT.md.
    decorative_pending,
};

const ConfigFieldAccount = struct { name: []const u8, disposition: ConfigFieldDisposition };

const config_field_accounting = [_]ConfigFieldAccount{
    .{ .name = "workspace_dir", .disposition = .runtime_or_derived },
    .{ .name = "config_path", .disposition = .runtime_or_derived },
    .{ .name = "profile", .disposition = .json_parsed },
    .{ .name = "providers", .disposition = .json_parsed },
    .{ .name = "audio_media", .disposition = .json_parsed },
    .{ .name = "default_provider", .disposition = .json_parsed },
    .{ .name = "default_model", .disposition = .json_parsed },
    .{ .name = "legacy_default_provider_detected", .disposition = .runtime_or_derived },
    .{ .name = "legacy_default_model_detected", .disposition = .runtime_or_derived },
    .{ .name = "default_temperature", .disposition = .json_parsed },
    .{ .name = "reasoning_effort", .disposition = .json_parsed },
    .{ .name = "model_routes", .disposition = .json_parsed },
    .{ .name = "agents", .disposition = .json_parsed },
    .{ .name = "agent_bindings", .disposition = .json_parsed },
    .{ .name = "mcp_servers", .disposition = .json_parsed },
    .{ .name = "api_specs", .disposition = .json_parsed },
    .{ .name = "diagnostics", .disposition = .json_parsed },
    .{ .name = "autonomy", .disposition = .json_parsed },
    .{ .name = "runtime", .disposition = .json_parsed },
    .{ .name = "network", .disposition = .decorative_pending },
    .{ .name = "reliability", .disposition = .json_parsed },
    .{ .name = "scheduler", .disposition = .json_parsed },
    .{ .name = "agent", .disposition = .json_parsed },
    .{ .name = "sidecar", .disposition = .json_parsed },
    .{ .name = "heartbeat", .disposition = .json_parsed },
    .{ .name = "cron", .disposition = .json_parsed },
    .{ .name = "channels", .disposition = .json_parsed },
    .{ .name = "memory", .disposition = .json_parsed },
    .{ .name = "tunnel", .disposition = .json_parsed },
    .{ .name = "gateway", .disposition = .json_parsed },
    .{ .name = "tenant", .disposition = .json_parsed },
    .{ .name = "state", .disposition = .json_parsed },
    .{ .name = "composio", .disposition = .json_parsed },
    .{ .name = "branding", .disposition = .json_parsed },
    .{ .name = "secrets", .disposition = .json_parsed },
    .{ .name = "browser", .disposition = .json_parsed },
    .{ .name = "http_request", .disposition = .json_parsed },
    .{ .name = "identity", .disposition = .json_parsed },
    .{ .name = "cost", .disposition = .json_parsed },
    .{ .name = "peripherals", .disposition = .json_parsed },
    .{ .name = "security", .disposition = .json_parsed },
    .{ .name = "tools", .disposition = .json_parsed },
    .{ .name = "session", .disposition = .json_parsed },
    .{ .name = "temperature", .disposition = .runtime_or_derived },
    .{ .name = "max_tokens", .disposition = .runtime_or_derived },
    .{ .name = "memory_backend", .disposition = .runtime_or_derived },
    .{ .name = "memory_auto_save", .disposition = .runtime_or_derived },
    .{ .name = "heartbeat_enabled", .disposition = .runtime_or_derived },
    .{ .name = "heartbeat_interval_minutes", .disposition = .runtime_or_derived },
    .{ .name = "gateway_host", .disposition = .runtime_or_derived },
    .{ .name = "gateway_port", .disposition = .runtime_or_derived },
    .{ .name = "workspace_only", .disposition = .runtime_or_derived },
    .{ .name = "max_actions_per_hour", .disposition = .runtime_or_derived },
    .{ .name = "allocator", .disposition = .runtime_or_derived },
    .{ .name = "arena", .disposition = .runtime_or_derived },
};

comptime {
    // ~53 fields × ~53 accounting entries × per-char std.mem.eql exceeds
    // the default 1000-backwards-branch comptime budget.
    @setEvalBranchQuota(100_000);
    // Forward: every Config field must be registered.
    for (std.meta.fields(Config)) |field| {
        var accounted = false;
        for (config_field_accounting) |entry| {
            if (std.mem.eql(u8, field.name, entry.name)) {
                accounted = true;
                break;
            }
        }
        if (!accounted) {
            @compileError("Config field '" ++ field.name ++ "' is UNACCOUNTED. " ++
                "Register it in `config_field_accounting` (config.zig): if it is read " ++
                "from config.json add a parser in config_parse.zig and tag .json_parsed; " ++
                "if it is runtime/derived state tag .runtime_or_derived; if it is a " ++
                "known-unwired gap tag .decorative_pending. This guard exists because " ++
                "findings #3/#4 were Config fields with no parser, undetected for months.");
        }
    }
    // Reverse: no stale accounting entries for removed fields.
    for (config_field_accounting) |entry| {
        var exists = false;
        for (std.meta.fields(Config)) |field| {
            if (std.mem.eql(u8, entry.name, field.name)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            @compileError("config_field_accounting has a stale entry '" ++ entry.name ++
                "' — no such Config field. Remove it.");
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────

test "json parse roundtrip" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "default_temperature": 0.5,
        \\  "models": {"providers": {"anthropic": {"api_key": "sk-test"}}},
        \\  "agents": {"defaults": {"model": {"primary": "anthropic/claude-opus-4"}, "heartbeat": {"every": "15m"}}},
        \\  "memory": {"backend": "markdown", "auto_save": false},
        \\  "gateway": {"port": 9090, "host": "0.0.0.0", "require_explicit_chat_stream_session_key": true, "max_workers": 24, "max_queued_requests": 4096, "overload_retry_after_secs": 5, "inbound_workers": 6, "outbound_workers": 3},
        \\  "tenant": {"enabled": true, "data_root": "/data/users", "runtime_cache_max_users": 5000, "runtime_idle_ttl_secs": 900},
        \\  "autonomy": {"level": "full", "workspace_only": false, "max_actions_per_hour": 50},
        \\  "runtime": {"kind": "docker"},
        \\  "cost": {"enabled": true, "daily_limit_usd": 25.0}
        \\}
    ;

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    try cfg.parseJson(json);
    cfg.syncFlatFields();

    try std.testing.expectEqualStrings("anthropic", cfg.default_provider);
    try std.testing.expectEqualStrings("claude-opus-4", cfg.default_model.?);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.default_temperature);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.temperature);
    try std.testing.expectEqualStrings("sk-test", cfg.defaultProviderKey().?);
    try std.testing.expect(cfg.heartbeat.enabled);
    try std.testing.expect(cfg.heartbeat_enabled);
    try std.testing.expectEqual(@as(u32, 15), cfg.heartbeat.interval_minutes);
    try std.testing.expectEqualStrings("markdown", cfg.memory.backend);
    try std.testing.expectEqualStrings("markdown", cfg.memory_backend);
    try std.testing.expect(!cfg.memory.auto_save);
    try std.testing.expect(!cfg.memory_auto_save);
    try std.testing.expectEqual(@as(u16, 9090), cfg.gateway.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.gateway.host);
    try std.testing.expect(cfg.gateway.require_explicit_chat_stream_session_key);
    try std.testing.expectEqual(@as(u16, 24), cfg.gateway.max_workers);
    try std.testing.expectEqual(@as(u32, 4096), cfg.gateway.max_queued_requests);
    try std.testing.expectEqual(@as(u16, 5), cfg.gateway.overload_retry_after_secs);
    try std.testing.expectEqual(@as(u32, 6), cfg.gateway.inbound_workers);
    try std.testing.expectEqual(@as(u32, 3), cfg.gateway.outbound_workers);
    try std.testing.expect(cfg.tenant.enabled);
    try std.testing.expectEqualStrings("/data/users", cfg.tenant.data_root);
    try std.testing.expectEqual(@as(u32, 5000), cfg.tenant.runtime_cache_max_users);
    try std.testing.expectEqual(@as(u32, 900), cfg.tenant.runtime_idle_ttl_secs);
    try std.testing.expectEqual(AutonomyLevel.full, cfg.autonomy.level);
    try std.testing.expect(!cfg.autonomy.workspace_only);
    try std.testing.expect(!cfg.workspace_only);
    try std.testing.expectEqual(@as(u32, 50), cfg.autonomy.max_actions_per_hour);
    try std.testing.expectEqualStrings("docker", cfg.runtime.kind);
    try std.testing.expect(cfg.cost.enabled);
    try std.testing.expectEqual(@as(f64, 25.0), cfg.cost.daily_limit_usd);

    // Clean up allocated strings
    allocator.free(cfg.default_provider);
    allocator.free(cfg.default_model.?);
    for (cfg.providers) |e| {
        allocator.free(e.name);
        if (e.api_key) |k| allocator.free(k);
        if (e.base_url) |b| allocator.free(b);
    }
    allocator.free(cfg.providers);
    allocator.free(cfg.memory.backend);
    allocator.free(cfg.gateway.host);
    allocator.free(cfg.tenant.data_root);
    allocator.free(cfg.runtime.kind);
}

test "V1.14.12 (M2/M3/M5 hardening): all three new gate flags default to true" {
    // Locks the soak-safe default contract. If any of these flips to
    // false by default, the deployment loses the M2 fast-path,
    // M3 coverage filter, or M5 legacy direct-write coverage —
    // potentially silently. The default-on contract is the soak
    // safety net. Operators MUST explicitly opt out via config.json.
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(cfg.agent.extraction_cardinality_fastpath);
    try std.testing.expect(cfg.agent.extraction_coverage_filter_enabled);
    // V1.14.12 (Path A) — extraction_legacy_direct_writes field removed.
}

test "V1.14.12 (M2/M3 hardening): operator can override the two remaining flags via config.json" {
    // Hardening test: parseJson MUST honor explicit overrides for
    // each flag. The M5 legacy_direct_writes flag was deleted in
    // Path A (no longer a feature flag — the gated paths were removed
    // entirely after A/B bench validation).
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "agent": {
        \\    "extraction_cardinality_fastpath": false,
        \\    "extraction_coverage_filter_enabled": false
        \\  }
        \\}
    ;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.agent.extraction_cardinality_fastpath);
    try std.testing.expect(!cfg.agent.extraction_coverage_filter_enabled);
}

test "gateway config defaults require explicit chat stream session key" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(cfg.gateway.require_explicit_chat_stream_session_key);
}

test "validation rejects bad temperature" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .default_temperature = 5.0,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(Config.ValidationError.TemperatureOutOfRange, cfg.validate());
}

test "json parse reads reliability fallback providers and model fallbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "agents": {"defaults": {"model": {"primary": "openai-codex/gpt-5.3-codex"}}},
        \\  "reliability": {
        \\    "provider_retries": 3,
        \\    "provider_backoff_ms": 750,
        \\    "fallback_providers": ["openrouter", "groq"],
        \\    "api_keys": ["key_a", "key_b"],
        \\    "model_fallbacks": [
        \\      {"model": "gpt-5.3-codex", "fallbacks": ["openrouter/anthropic/claude-sonnet-4"]},
        \\      {"model": "claude-opus-4", "fallbacks": ["claude-sonnet-4", "claude-haiku-3.5"]}
        \\    ]
        \\  }
        \\}
    ;

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    try cfg.parseJson(json);

    try std.testing.expectEqual(@as(u32, 3), cfg.reliability.provider_retries);
    try std.testing.expectEqual(@as(u64, 750), cfg.reliability.provider_backoff_ms);
    try std.testing.expectEqual(@as(usize, 2), cfg.reliability.fallback_providers.len);
    try std.testing.expectEqualStrings("openrouter", cfg.reliability.fallback_providers[0]);
    try std.testing.expectEqualStrings("groq", cfg.reliability.fallback_providers[1]);
    try std.testing.expectEqual(@as(usize, 2), cfg.reliability.api_keys.len);
    try std.testing.expectEqualStrings("key_a", cfg.reliability.api_keys[0]);
    try std.testing.expectEqualStrings("key_b", cfg.reliability.api_keys[1]);
    try std.testing.expectEqual(@as(usize, 2), cfg.reliability.model_fallbacks.len);
    try std.testing.expectEqualStrings("gpt-5.3-codex", cfg.reliability.model_fallbacks[0].model);
    try std.testing.expectEqual(@as(usize, 1), cfg.reliability.model_fallbacks[0].fallbacks.len);
    try std.testing.expectEqualStrings(
        "openrouter/anthropic/claude-sonnet-4",
        cfg.reliability.model_fallbacks[0].fallbacks[0],
    );
}

test "validation rejects zero port" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .allocator = std.testing.allocator,
    };
    cfg.gateway.port = 0;
    try std.testing.expectError(Config.ValidationError.InvalidPort, cfg.validate());
}

test "validation passes for defaults" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "test/model",
        .allocator = std.testing.allocator,
    };
    try cfg.validate();
}

test "validation rejects null default_model" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(Config.ValidationError.NoDefaultModel, cfg.validate());
}

test "validation rejects top-level default_provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"default_provider":"anthropic","agents":{"defaults":{"model":{"primary":"anthropic/claude-opus-4"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.legacy_default_provider_detected);
    try std.testing.expectError(Config.ValidationError.LegacyDefaultProviderField, cfg.validate());
}

test "json parse top-level default_model" {
    const allocator = std.testing.allocator;
    const json =
        \\{"default_model": "meta-llama/llama-3.3-70b-instruct:free"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.legacy_default_model_detected);
    try std.testing.expect(cfg.default_model == null);
    try std.testing.expectError(Config.ValidationError.LegacyDefaultModelField, cfg.validate());
}

test "validation rejects top-level default_model even when nested model exists" {
    const allocator = std.testing.allocator;
    // use an arena to match production behavior (both allocs are freed together)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = a };
    try cfg.parseJson(
        \\{"default_model": "top-level-model", "agents": {"defaults": {"model": {"primary": "anthropic/nested-model"}}}}
    );
    try std.testing.expect(cfg.legacy_default_model_detected);
    try std.testing.expectEqualStrings("nested-model", cfg.default_model.?);
    try std.testing.expectError(Config.ValidationError.LegacyDefaultModelField, cfg.validate());
}

test "validation rejects defaults.model.primary without provider prefix" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents":{"defaults":{"model":{"primary":"claude-opus-4"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectError(Config.ValidationError.InvalidDefaultModelPrimary, cfg.validate());
}

test "save includes channels section by default" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    const cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };
    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"channels\": {") != null);
}

test "save writes configured telegram channel account" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };
    cfg.channels.telegram = &.{
        .{
            .account_id = "main",
            .bot_token = "123:ABC",
            .allow_from = &.{"user1"},
        },
    };
    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"telegram\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"accounts\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"main\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"account_id\": \"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"bot_token\": \"123:ABC\"") != null);
}

test "save roundtrip preserves reliability settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    const fallback_models = [_][]const u8{
        "openrouter/anthropic/claude-sonnet-4",
        "groq/llama-3.3-70b",
    };
    const model_fallbacks = [_]ModelFallbackEntry{
        .{
            .model = "gpt-5.3-codex",
            .fallbacks = &fallback_models,
        },
    };

    var cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };
    cfg.reliability.provider_retries = 4;
    cfg.reliability.provider_backoff_ms = 1200;
    cfg.reliability.channel_initial_backoff_secs = 5;
    cfg.reliability.channel_max_backoff_secs = 90;
    cfg.reliability.scheduler_poll_secs = 20;
    cfg.reliability.scheduler_retries = 3;
    cfg.reliability.fallback_providers = &.{ "openrouter", "groq" };
    cfg.reliability.api_keys = &.{ "rk_a", "rk_b" };
    cfg.reliability.model_fallbacks = &model_fallbacks;
    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = arena.allocator(),
    };
    try loaded.parseJson(content);

    try std.testing.expectEqual(@as(u32, 4), loaded.reliability.provider_retries);
    try std.testing.expectEqual(@as(u64, 1200), loaded.reliability.provider_backoff_ms);
    try std.testing.expectEqual(@as(u64, 5), loaded.reliability.channel_initial_backoff_secs);
    try std.testing.expectEqual(@as(u64, 90), loaded.reliability.channel_max_backoff_secs);
    try std.testing.expectEqual(@as(u64, 20), loaded.reliability.scheduler_poll_secs);
    try std.testing.expectEqual(@as(u32, 3), loaded.reliability.scheduler_retries);
    try std.testing.expectEqual(@as(usize, 2), loaded.reliability.fallback_providers.len);
    try std.testing.expectEqualStrings("openrouter", loaded.reliability.fallback_providers[0]);
    try std.testing.expectEqualStrings("groq", loaded.reliability.fallback_providers[1]);
    try std.testing.expectEqual(@as(usize, 2), loaded.reliability.api_keys.len);
    try std.testing.expectEqualStrings("rk_a", loaded.reliability.api_keys[0]);
    try std.testing.expectEqualStrings("rk_b", loaded.reliability.api_keys[1]);
    try std.testing.expectEqual(@as(usize, 1), loaded.reliability.model_fallbacks.len);
    try std.testing.expectEqualStrings("gpt-5.3-codex", loaded.reliability.model_fallbacks[0].model);
    try std.testing.expectEqual(@as(usize, 2), loaded.reliability.model_fallbacks[0].fallbacks.len);
    try std.testing.expectEqualStrings("openrouter/anthropic/claude-sonnet-4", loaded.reliability.model_fallbacks[0].fallbacks[0]);
    try std.testing.expectEqualStrings("groq/llama-3.3-70b", loaded.reliability.model_fallbacks[0].fallbacks[1]);
}

test "json parse memory weights accept integer values" {
    const allocator = std.testing.allocator;
    const json =
        \\{"memory":{"search":{"query":{"hybrid":{"vector_weight":1,"text_weight":0}}}}}
    ;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(f64, 1.0), cfg.memory.search.query.hybrid.vector_weight);
    try std.testing.expectEqual(@as(f64, 0.0), cfg.memory.search.query.hybrid.text_weight);
}

test "save roundtrip preserves extended config sections" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };
    cfg.reasoning_effort = "high";
    cfg.model_routes = &.{
        .{
            .hint = "fast",
            .provider = "groq",
            .model = "llama-3.3-70b",
            .api_key = "gsk_test",
        },
    };
    cfg.agents = &.{
        .{
            .name = "helper",
            .provider = "openrouter",
            .model = "openai/gpt-4o-mini",
            .system_prompt = "You are helper.",
            .api_key = "rk_test",
            .temperature = 0.2,
            .max_depth = 5,
        },
    };
    cfg.agent_bindings = &.{
        .{
            .agent_id = "helper",
            .comment = "discord-main",
            .match = .{
                .channel = "discord",
                .account_id = "main",
            },
        },
    };
    cfg.mcp_servers = &.{
        .{
            .name = "context7",
            .command = "npx",
            .args = &.{
                "-y",
                "@upstash/context7-mcp",
            },
            .env = &.{
                .{
                    .key = "OPENROUTER_API_KEY",
                    .value = "sk-test",
                },
            },
        },
    };

    cfg.runtime.kind = "docker";
    cfg.runtime.docker.image = "alpine:3.20";
    cfg.runtime.docker.network = "bridge";
    cfg.runtime.docker.memory_limit_mb = 768;
    cfg.runtime.docker.cpu_limit = 0.75;
    cfg.runtime.docker.read_only_rootfs = false;
    cfg.runtime.docker.mount_workspace = false;

    cfg.scheduler.enabled = false;
    cfg.scheduler.max_tasks = 32;
    cfg.scheduler.max_concurrent = 2;

    cfg.agent.compact_context = true;
    // max_tool_iterations: NOT set here — mode presets handle this (8/25/500).
    // max_history_messages: NOT set here — mode presets set 0 (uncapped).
    // Q1 (2026-04-27): message-count cap deprecated; compaction is the sole
    // context governor. Mode-independent defaults apply; no per-mode overrides.
    // overrides accepted but forced to 0 at parse time (config_parse.zig).
    cfg.agent.parallel_tools = true;
    cfg.agent.parallel_tools_rollout_percent = 100;
    cfg.agent.tool_dispatcher = "parallel";
    cfg.agent.session_idle_timeout_secs = 90;
    // Phase 3.9 compaction budgets — profile must not override these.
    cfg.agent.compaction_keep_recent = 20;
    cfg.agent.compaction_max_summary_chars = 16_000;
    cfg.agent.compaction_max_source_chars = 80_000;
    cfg.agent.message_timeout_secs = 300;

    cfg.memory.search.provider = "openai";
    cfg.memory.search.model = "text-embedding-3-small";
    cfg.memory.search.dimensions = 1536;
    cfg.memory.search.query.hybrid.vector_weight = 0.6;
    cfg.memory.search.query.hybrid.text_weight = 0.4;
    cfg.memory.search.cache.max_entries = 333;
    cfg.memory.search.chunking.max_tokens = 1024;
    cfg.memory.response_cache.enabled = true;
    cfg.memory.response_cache.ttl_minutes = 15;
    cfg.memory.response_cache.max_entries = 123;
    cfg.memory.lifecycle.snapshot_enabled = true;
    cfg.memory.lifecycle.snapshot_on_hygiene = true;
    cfg.memory.lifecycle.auto_hydrate = false;

    cfg.gateway.allow_public_bind = true;
    cfg.gateway.pair_rate_limit_per_minute = 20;
    cfg.gateway.webhook_rate_limit_per_minute = 80;
    cfg.gateway.idempotency_ttl_secs = 120;
    cfg.gateway.paired_tokens = &.{ "tok-1", "tok-2" };

    cfg.tunnel.provider = "cloudflare";

    cfg.composio.enabled = true;
    cfg.composio.api_key = "comp-key";
    cfg.composio.entity_id = "entity-1";

    cfg.secrets.encrypt = false;

    cfg.browser.enabled = true;
    cfg.browser.backend = "native";
    cfg.browser.computer_use.endpoint = "http://127.0.0.1:8788/v1/actions";
    cfg.browser.computer_use.api_key = "computer-use-key";
    cfg.browser.computer_use.timeout_ms = 42_000;
    cfg.browser.computer_use.allow_remote_endpoint = true;
    cfg.browser.computer_use.max_coordinate_x = 1920;
    cfg.browser.computer_use.max_coordinate_y = 1080;
    cfg.browser.allowed_domains = &.{ "github.com", "docs.rs" };

    cfg.http_request.enabled = true;
    cfg.http_request.max_response_size = 12345;
    cfg.http_request.timeout_secs = 8;
    cfg.http_request.allowed_domains = &.{"api.github.com"};

    cfg.identity.format = "aieos";
    cfg.identity.aieos_path = "id.json";
    cfg.identity.aieos_inline = "inline-id";

    cfg.cost.warn_at_percent = 70;
    cfg.cost.allow_override = true;

    cfg.security.sandbox.enabled = true;
    cfg.security.sandbox.backend = .firejail;
    cfg.security.sandbox.fail_open_on_dev = true;
    cfg.security.sandbox.firejail_args = &.{ "--private", "--net=none" };
    cfg.security.resources.max_memory_mb = 1024;
    cfg.security.resources.max_cpu_percent = 55;
    cfg.security.resources.max_disk_mb = 2048;
    cfg.security.resources.max_cpu_time_secs = 120;
    cfg.security.resources.max_subprocesses = 20;
    cfg.security.resources.memory_monitoring = false;
    cfg.security.audit.enabled = false;
    cfg.security.audit.log_file = "audit-file.log";
    cfg.security.audit.log_path = "custom.log";
    cfg.security.audit.retention_days = 14;
    cfg.security.audit.max_size_mb = 9;
    cfg.security.audit.sign_events = true;

    cfg.peripherals.enabled = true;
    cfg.peripherals.datasheet_dir = "/tmp/ds";
    cfg.peripherals.boards = &.{
        .{
            .board = "arduino-uno",
            .transport = "serial",
            .path = "/dev/ttyACM0",
            .baud = 57_600,
        },
    };

    // hardware.* fixture writes removed D19 (2026-04-25).

    cfg.session.dm_scope = .per_peer;
    cfg.session.idle_minutes = 45;
    cfg.session.typing_interval_secs = 2;
    cfg.session.identity_links = &.{
        .{
            .canonical = "alice",
            .peers = &.{ "telegram:111", "discord:222" },
        },
    };

    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = arena.allocator(),
    };
    try loaded.parseJson(content);

    try std.testing.expectEqualStrings("high", loaded.reasoning_effort.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.model_routes.len);
    try std.testing.expectEqualStrings("fast", loaded.model_routes[0].hint);
    try std.testing.expectEqualStrings("gsk_test", loaded.model_routes[0].api_key.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.agents.len);
    try std.testing.expectEqualStrings("helper", loaded.agents[0].name);
    try std.testing.expectEqual(@as(usize, 1), loaded.agent_bindings.len);
    try std.testing.expectEqualStrings("discord", loaded.agent_bindings[0].match.channel.?);
    try std.testing.expectEqualStrings("main", loaded.agent_bindings[0].match.account_id.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.mcp_servers.len);
    try std.testing.expectEqualStrings("context7", loaded.mcp_servers[0].name);
    try std.testing.expectEqual(@as(usize, 2), loaded.mcp_servers[0].args.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.mcp_servers[0].env.len);
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", loaded.mcp_servers[0].env[0].key);

    try std.testing.expectEqualStrings("docker", loaded.runtime.kind);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), loaded.runtime.docker.cpu_limit.?, 0.0001);
    try std.testing.expectEqual(@as(u32, 32), loaded.scheduler.max_tasks);
    try std.testing.expect(loaded.agent.parallel_tools);
    try std.testing.expectEqual(@as(u8, 100), loaded.agent.parallel_tools_rollout_percent);

    try std.testing.expectEqualStrings("openai", loaded.memory.search.provider);
    try std.testing.expect(loaded.memory.response_cache.enabled);
    try std.testing.expectEqual(@as(u32, 2), loaded.gateway.paired_tokens.len);
    try std.testing.expect(loaded.gateway.allow_public_bind);
    try std.testing.expectEqualStrings("cloudflare", loaded.tunnel.provider);
    try std.testing.expect(loaded.composio.enabled);
    try std.testing.expect(!loaded.secrets.encrypt);
    try std.testing.expect(loaded.browser.enabled);
    try std.testing.expectEqual(@as(usize, 2), loaded.browser.allowed_domains.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:8788/v1/actions", loaded.browser.computer_use.endpoint);
    try std.testing.expectEqualStrings("computer-use-key", loaded.browser.computer_use.api_key.?);
    try std.testing.expectEqual(@as(u64, 42_000), loaded.browser.computer_use.timeout_ms);
    try std.testing.expect(loaded.browser.computer_use.allow_remote_endpoint);
    try std.testing.expectEqual(@as(i64, 1920), loaded.browser.computer_use.max_coordinate_x.?);
    try std.testing.expect(loaded.http_request.enabled);
    try std.testing.expectEqual(@as(usize, 1), loaded.http_request.allowed_domains.len);
    try std.testing.expectEqualStrings("api.github.com", loaded.http_request.allowed_domains[0]);
    try std.testing.expectEqualStrings("aieos", loaded.identity.format);
    try std.testing.expectEqual(@as(u8, 70), loaded.cost.warn_at_percent);
    try std.testing.expectEqual(config_types.SandboxBackend.firejail, loaded.security.sandbox.backend);
    try std.testing.expect(loaded.security.sandbox.fail_open_on_dev);
    try std.testing.expectEqual(@as(usize, 2), loaded.security.sandbox.firejail_args.len);
    try std.testing.expectEqual(@as(u32, 55), loaded.security.resources.max_cpu_percent);
    try std.testing.expectEqual(@as(u32, 2048), loaded.security.resources.max_disk_mb);
    try std.testing.expectEqualStrings("audit-file.log", loaded.security.audit.log_file.?);
    try std.testing.expectEqual(@as(u32, 14), loaded.security.audit.retention_days);
    try std.testing.expect(loaded.peripherals.enabled);
    try std.testing.expectEqual(@as(usize, 1), loaded.peripherals.boards.len);
    try std.testing.expectEqualStrings("arduino-uno", loaded.peripherals.boards[0].board);
    try std.testing.expectEqualStrings("/dev/ttyACM0", loaded.peripherals.boards[0].path.?);
    // hardware.* roundtrip assertion removed D19 (2026-04-25).
    try std.testing.expectEqual(config_types.DmScope.per_peer, loaded.session.dm_scope);
    try std.testing.expectEqual(@as(usize, 1), loaded.session.identity_links.len);
}

test "save escapes mcp_servers strings safely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };
    cfg.default_model = "gpt-5";
    cfg.mcp_servers = &.{
        .{
            .name = "ctx\"7",
            .command = "npx \"@scope/pkg\"\nrun",
            .args = &.{
                "--path=C:\\tmp\\file",
                "line\nbreak",
            },
            .env = &.{
                .{
                    .key = "OPEN\"KEY",
                    .value = "ab\\cd\"ef\nz",
                },
            },
            // Non-default value: must survive the save→load round-trip.
            .read_line_timeout_secs = 120,
        },
    };

    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = arena.allocator(),
    };
    try loaded.parseJson(content);

    try std.testing.expectEqual(@as(usize, 1), loaded.mcp_servers.len);
    try std.testing.expectEqualStrings("ctx\"7", loaded.mcp_servers[0].name);
    try std.testing.expectEqualStrings("npx \"@scope/pkg\"\nrun", loaded.mcp_servers[0].command);
    try std.testing.expectEqual(@as(usize, 2), loaded.mcp_servers[0].args.len);
    try std.testing.expectEqualStrings("--path=C:\\tmp\\file", loaded.mcp_servers[0].args[0]);
    try std.testing.expectEqualStrings("line\nbreak", loaded.mcp_servers[0].args[1]);
    try std.testing.expectEqual(@as(usize, 1), loaded.mcp_servers[0].env.len);
    try std.testing.expectEqualStrings("OPEN\"KEY", loaded.mcp_servers[0].env[0].key);
    try std.testing.expectEqualStrings("ab\\cd\"ef\nz", loaded.mcp_servers[0].env[0].value);
    // S7.11 round-trip: a non-default read_line_timeout_secs must persist.
    try std.testing.expectEqual(@as(u32, 120), loaded.mcp_servers[0].read_line_timeout_secs);
}

test "save escapes manually serialized config strings safely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };
    cfg.profile = "std\"ard\\profile";
    cfg.reasoning_effort = "high";
    cfg.default_provider = "prov\"ider";
    cfg.default_model = "model\\name";
    cfg.providers = &.{
        .{
            .name = "prov\"ider",
            .api_key = "key\\\"line\nnext",
            .base_url = "https://example.com/v1?name=\"model\"",
        },
    };
    cfg.diagnostics.backend = "otel\"json";
    cfg.diagnostics.otel_endpoint = "https://otel.example/v1?x=\"y\"";
    cfg.diagnostics.otel_service_name = "null\\alis";
    cfg.reliability.fallback_providers = &.{ "fallback\"one", "fallback\\two" };
    cfg.reliability.api_keys = &.{"api\"key"};
    cfg.reliability.model_fallbacks = &.{
        .{
            .model = "primary\"model",
            .fallbacks = &.{"fallback\nmodel"},
        },
    };
    cfg.channels.telegram = &.{
        .{
            .account_id = "acct\"one",
            .bot_token = "tok\\en\nnext",
        },
    };
    cfg.tools.web_search_provider = "exa\"provider";
    cfg.tools.web_search_exa_api_key = "exa\\key";
    cfg.tools.web_search_brave_api_key = "brave\"key";
    cfg.audio_media.enabled = true;
    cfg.audio_media.provider = "groq\"audio";
    cfg.audio_media.model = "whisper\\model";
    cfg.audio_media.base_url = "https://audio.example/v1?x=\"y\"";
    cfg.audio_media.language = "en\"US";

    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = arena.allocator(),
    };
    try loaded.parseJson(content);

    try std.testing.expectEqualStrings("std\"ard\\profile", loaded.profile);
    try std.testing.expectEqualStrings("high", loaded.reasoning_effort.?);
    try std.testing.expectEqualStrings("prov\"ider", loaded.default_provider);
    try std.testing.expectEqualStrings("model\\name", loaded.default_model.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.providers.len);
    try std.testing.expectEqualStrings("key\\\"line\nnext", loaded.providers[0].api_key.?);
    try std.testing.expectEqualStrings("https://example.com/v1?name=\"model\"", loaded.providers[0].base_url.?);
    try std.testing.expectEqualStrings("otel\"json", loaded.diagnostics.backend);
    try std.testing.expectEqualStrings("https://otel.example/v1?x=\"y\"", loaded.diagnostics.otel_endpoint.?);
    try std.testing.expectEqualStrings("null\\alis", loaded.diagnostics.otel_service_name.?);
    try std.testing.expectEqualStrings("fallback\"one", loaded.reliability.fallback_providers[0]);
    try std.testing.expectEqualStrings("api\"key", loaded.reliability.api_keys[0]);
    try std.testing.expectEqualStrings("primary\"model", loaded.reliability.model_fallbacks[0].model);
    try std.testing.expectEqualStrings("fallback\nmodel", loaded.reliability.model_fallbacks[0].fallbacks[0]);
    try std.testing.expectEqual(@as(usize, 1), loaded.channels.telegram.len);
    try std.testing.expectEqualStrings("acct\"one", loaded.channels.telegram[0].account_id);
    try std.testing.expectEqualStrings("tok\\en\nnext", loaded.channels.telegram[0].bot_token);
    try std.testing.expectEqualStrings("exa\"provider", loaded.tools.web_search_provider);
    try std.testing.expectEqualStrings("exa\\key", loaded.tools.web_search_exa_api_key);
    try std.testing.expectEqualStrings("brave\"key", loaded.tools.web_search_brave_api_key);
    try std.testing.expectEqualStrings("groq\"audio", loaded.audio_media.provider);
    try std.testing.expectEqualStrings("whisper\\model", loaded.audio_media.model);
    try std.testing.expectEqualStrings("https://audio.example/v1?x=\"y\"", loaded.audio_media.base_url.?);
    try std.testing.expectEqualStrings("en\"US", loaded.audio_media.language.?);
}

test "parseJson accepts integer semantic cache similarity threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = Config{
        .workspace_dir = "/tmp/nullalis",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = arena.allocator(),
    };
    try cfg.parseJson(
        \\{
        \\  "memory": {
        \\    "semantic_cache": {
        \\      "similarity_threshold": 1
        \\    }
        \\  }
        \\}
    );

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.memory.semantic_cache.similarity_threshold, 0.0001);
}

test "parseJson accepts float semantic cache similarity threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = Config{
        .workspace_dir = "/tmp/nullalis",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = arena.allocator(),
    };
    try cfg.parseJson(
        \\{
        \\  "memory": {
        \\    "semantic_cache": {
        \\      "similarity_threshold": 0.9
        \\    }
        \\  }
        \\}
    );

    try std.testing.expectApproxEqAbs(@as(f32, 0.9), cfg.memory.semantic_cache.similarity_threshold, 0.0001);
}

test "syncFlatFields propagates nested values" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.default_temperature = 1.5;
    cfg.memory.backend = "lucid";
    cfg.memory.auto_save = false;
    cfg.heartbeat.enabled = true;
    cfg.heartbeat.interval_minutes = 10;
    cfg.gateway.host = "0.0.0.0";
    cfg.gateway.port = 9999;
    cfg.autonomy.workspace_only = false;
    cfg.autonomy.max_actions_per_hour = 999;

    cfg.syncFlatFields();

    try std.testing.expectEqual(@as(f64, 1.5), cfg.temperature);
    try std.testing.expectEqualStrings("lucid", cfg.memory_backend);
    try std.testing.expect(!cfg.memory_auto_save);
    try std.testing.expect(cfg.heartbeat_enabled);
    try std.testing.expectEqual(@as(u32, 10), cfg.heartbeat_interval_minutes);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.gateway_host);
    try std.testing.expectEqual(@as(u16, 9999), cfg.gateway_port);
    try std.testing.expect(!cfg.workspace_only);
    try std.testing.expectEqual(@as(u32, 999), cfg.max_actions_per_hour);
}

// ── Security-critical defaults ───────────────────────────────────

test "gateway config requires pairing by default" {
    const g = GatewayConfig{};
    try std.testing.expect(g.require_pairing);
}

test "gateway config blocks public bind by default" {
    const g = GatewayConfig{};
    try std.testing.expect(!g.allow_public_bind);
}

test "secrets config default encrypts" {
    const s = SecretsConfig{};
    try std.testing.expect(s.encrypt);
}

// ── Validation edge cases ───────────────────────────────────────

test "validation rejects negative temperature" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .default_temperature = -1.0,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(Config.ValidationError.TemperatureOutOfRange, cfg.validate());
}

test "validation accepts boundary temperatures" {
    const cfg_zero = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .default_temperature = 0.0,
        .allocator = std.testing.allocator,
    };
    try cfg_zero.validate();

    const cfg_two = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .default_temperature = 2.0,
        .allocator = std.testing.allocator,
    };
    try cfg_two.validate();
}

test "validation rejects excessive retries" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_retries = 101;
    try std.testing.expectError(Config.ValidationError.InvalidRetryCount, cfg.validate());
}

test "validation rejects excessive backoff" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_backoff_ms = 700_000;
    try std.testing.expectError(Config.ValidationError.InvalidBackoffMs, cfg.validate());
}

test "validation accepts max boundary retries" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_retries = 100;
    try cfg.validate();
}

test "validation accepts max boundary backoff" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "x",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_backoff_ms = 600_000;
    try cfg.validate();
}

// ── JSON parse: sub-config sections ─────────────────────────────

test "json parse diagnostics section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"diagnostics": {"backend": "otel", "otel": {"endpoint": "http://localhost:4318", "service_name": "yc"}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("otel", cfg.diagnostics.backend);
    try std.testing.expectEqualStrings("http://localhost:4318", cfg.diagnostics.otel_endpoint.?);
    try std.testing.expectEqualStrings("yc", cfg.diagnostics.otel_service_name.?);
    allocator.free(cfg.diagnostics.backend);
    allocator.free(cfg.diagnostics.otel_endpoint.?);
    allocator.free(cfg.diagnostics.otel_service_name.?);
}

test "json parse scheduler section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"scheduler": {"enabled": false, "max_tasks": 128, "max_concurrent": 8}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.scheduler.enabled);
    try std.testing.expectEqual(@as(u32, 128), cfg.scheduler.max_tasks);
    try std.testing.expectEqual(@as(u32, 8), cfg.scheduler.max_concurrent);
}

test "json parse agent section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agent": {"compact_context": true, "max_tool_iterations": 20, "max_history_messages": 80, "parallel_tools": true, "parallel_tools_rollout_percent": 60, "tool_dispatcher": "xml", "token_limit": 64000, "session_ttl_secs": 600, "activation_mode": "always", "send_mode": "off", "queue_mode": "latest", "queue_debounce_ms": 250, "queue_cap": 12, "queue_drop": "newest", "tts_mode": "always", "tts_provider": "openai", "tts_limit_chars": 1200, "tts_summary": true, "tts_audio": true}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.agent.compact_context);
    try std.testing.expectEqual(@as(u32, 20), cfg.agent.max_tool_iterations);
    // Q1 (2026-04-27): max_history_messages deprecated — JSON value 80 is
    // accepted then forced to 0 (uncapped). Compaction is the sole governor.
    try std.testing.expectEqual(@as(u32, 0), cfg.agent.max_history_messages);
    try std.testing.expect(cfg.agent.parallel_tools);
    try std.testing.expectEqual(@as(u8, 60), cfg.agent.parallel_tools_rollout_percent);
    try std.testing.expectEqualStrings("xml", cfg.agent.tool_dispatcher);
    try std.testing.expectEqual(@as(u64, 64_000), cfg.agent.token_limit);
    try std.testing.expect(cfg.agent.token_limit_explicit);
    try std.testing.expectEqual(@as(?u64, 600), cfg.agent.session_ttl_secs);
    try std.testing.expectEqualStrings("always", cfg.agent.activation_mode);
    try std.testing.expectEqualStrings("off", cfg.agent.send_mode);
    try std.testing.expectEqualStrings("latest", cfg.agent.queue_mode);
    try std.testing.expectEqual(@as(u32, 250), cfg.agent.queue_debounce_ms);
    try std.testing.expectEqual(@as(u32, 12), cfg.agent.queue_cap);
    try std.testing.expectEqualStrings("newest", cfg.agent.queue_drop);
    try std.testing.expectEqualStrings("always", cfg.agent.tts_mode);
    try std.testing.expect(cfg.agent.tts_provider != null);
    try std.testing.expectEqualStrings("openai", cfg.agent.tts_provider.?);
    try std.testing.expectEqual(@as(u32, 1200), cfg.agent.tts_limit_chars);
    try std.testing.expect(cfg.agent.tts_summary);
    try std.testing.expect(cfg.agent.tts_audio);
    allocator.free(cfg.agent.tool_dispatcher);
    allocator.free(cfg.agent.activation_mode);
    allocator.free(cfg.agent.send_mode);
    allocator.free(cfg.agent.queue_mode);
    allocator.free(cfg.agent.queue_drop);
    allocator.free(cfg.agent.tts_mode);
    allocator.free(cfg.agent.tts_provider.?);
}

test "json parse agent parallel rollout percent clamps to bounds" {
    const allocator = std.testing.allocator;
    var cfg_low = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg_low.parseJson("{\"agent\":{\"parallel_tools_rollout_percent\":-1}}");
    try std.testing.expectEqual(@as(u8, 0), cfg_low.agent.parallel_tools_rollout_percent);

    var cfg_high = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg_high.parseJson("{\"agent\":{\"parallel_tools_rollout_percent\":200}}");
    try std.testing.expectEqual(@as(u8, 100), cfg_high.agent.parallel_tools_rollout_percent);
}

test "json parse agent token_limit explicit remains false when omitted" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agent": {"max_tool_iterations": 20}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(config_types.DEFAULT_AGENT_TOKEN_LIMIT, cfg.agent.token_limit);
    try std.testing.expect(!cfg.agent.token_limit_explicit);
}

// Enforcement test #1 (catches finding #1): the prior "json parse agent
// section" test passes `compact_context: true` EXPLICITLY — it pins the
// parse path, not the default. The compact_context regression was a
// silently-flipped DEFAULT; only a test that parses `{}` and asserts the
// default catches that class.
test "config hardening: agent.compact_context defaults to true" {
    const allocator = std.testing.allocator;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson("{}");
    try std.testing.expect(cfg.agent.compact_context);
}

// Enforcement test #2 (catches finding #4): the `sidecar` block must
// round-trip through the parser. Finding #4 was a struct + field +
// docstrings with NO parser — `Config.sidecar` was permanently the
// struct default. A test that parses a non-default sidecar block and
// asserts every field survives catches that class.
test "config hardening: sidecar block parses provider/model/enabled/narration_interval" {
    const allocator = std.testing.allocator;
    const json =
        \\{"sidecar": {"enabled": false, "provider": "together", "model": "meta-llama/Llama-3.3-70B-Instruct-Turbo", "narration_interval": 7}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.sidecar.enabled);
    try std.testing.expectEqualStrings("together", cfg.sidecar.provider);
    try std.testing.expectEqualStrings("meta-llama/Llama-3.3-70B-Instruct-Turbo", cfg.sidecar.model);
    try std.testing.expectEqual(@as(u32, 7), cfg.sidecar.narration_interval);
    allocator.free(cfg.sidecar.provider);
    allocator.free(cfg.sidecar.model);
}

test "json parse composio section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"composio": {"enabled": true, "api_key": "comp-key", "entity_id": "user1"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.composio.enabled);
    try std.testing.expectEqualStrings("comp-key", cfg.composio.api_key.?);
    try std.testing.expectEqualStrings("user1", cfg.composio.entity_id);
    allocator.free(cfg.composio.api_key.?);
    allocator.free(cfg.composio.entity_id);
}

test "json parse secrets section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"secrets": {"encrypt": false}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.secrets.encrypt);
}

test "json parse identity section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"identity": {"format": "aieos", "aieos_path": "id.json"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("aieos", cfg.identity.format);
    try std.testing.expectEqualStrings("id.json", cfg.identity.aieos_path.?);
    allocator.free(cfg.identity.format);
    allocator.free(cfg.identity.aieos_path.?);
}

// "json parse hardware section" test removed D19 (2026-04-25)
// alongside HardwareConfig + the parser branch in config_parse.zig.

test "json parse security section (legacy max_cpu_time_seconds alias)" {
    // v1.14.23 WARN 3.C: validates the back-compat alias path for
    // pre-rename `max_cpu_time_seconds` key. New configs should use
    // `max_cpu_time_secs` (covered by the test below).
    const allocator = std.testing.allocator;
    const json =
        \\{"security": {"sandbox": {"enabled": true, "backend": "firejail"}, "resources": {"max_memory_mb": 1024, "max_cpu_time_seconds": 120}, "audit": {"enabled": false, "log_path": "custom.log"}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.security.sandbox.enabled.?);
    try std.testing.expectEqual(SandboxBackend.firejail, cfg.security.sandbox.backend);
    try std.testing.expectEqual(@as(u32, 1024), cfg.security.resources.max_memory_mb);
    try std.testing.expectEqual(@as(u64, 120), cfg.security.resources.max_cpu_time_secs);
    try std.testing.expect(!cfg.security.audit.enabled);
    try std.testing.expectEqualStrings("custom.log", cfg.security.audit.log_path);
    allocator.free(cfg.security.audit.log_path);
}

test "json parse security section (canonical max_cpu_time_secs)" {
    // v1.14.23 WARN 3.C: canonical post-rename key. Both this and the
    // _seconds legacy alias must populate the same field.
    const allocator = std.testing.allocator;
    const json =
        \\{"security": {"resources": {"max_cpu_time_secs": 240}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(u64, 240), cfg.security.resources.max_cpu_time_secs);
}

test "json parse browser section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"browser": {"enabled": true, "backend": "auto", "native_headless": false}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.browser.enabled);
    try std.testing.expectEqualStrings("auto", cfg.browser.backend);
    // native_headless removed (dead field); unknown JSON keys are ignored by the parser
    allocator.free(cfg.browser.backend);
}

test "json parse empty object uses defaults" {
    const allocator = std.testing.allocator;
    const json = "{}";
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("openrouter", cfg.default_provider);
    try std.testing.expectEqual(@as(f64, 0.7), cfg.default_temperature);
    try std.testing.expect(cfg.secrets.encrypt);
}

test "json parse integer temperature coerced to float" {
    const allocator = std.testing.allocator;
    const json =
        \\{"default_temperature": 1}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(f64, 1.0), cfg.default_temperature);
}

test "json parse autonomy allowed commands" {
    const allocator = std.testing.allocator;
    const json =
        \\{"autonomy": {"allowed_commands": ["ls", "cat", "git status"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 3), cfg.autonomy.allowed_commands.len);
    try std.testing.expectEqualStrings("ls", cfg.autonomy.allowed_commands[0]);
    try std.testing.expectEqualStrings("cat", cfg.autonomy.allowed_commands[1]);
    try std.testing.expectEqualStrings("git status", cfg.autonomy.allowed_commands[2]);
    for (cfg.autonomy.allowed_commands) |cmd| allocator.free(cmd);
    allocator.free(cfg.autonomy.allowed_commands);
}

test "json parse autonomy allowed_paths" {
    const allocator = std.testing.allocator;
    const json =
        \\{"autonomy": {"allowed_paths": ["/Users/igor/projects", "/tmp/scratch"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.autonomy.allowed_paths.len);
    try std.testing.expectEqualStrings("/Users/igor/projects", cfg.autonomy.allowed_paths[0]);
    try std.testing.expectEqualStrings("/tmp/scratch", cfg.autonomy.allowed_paths[1]);
    for (cfg.autonomy.allowed_paths) |p| allocator.free(p);
    allocator.free(cfg.autonomy.allowed_paths);
}

test "json parse gateway paired tokens" {
    const allocator = std.testing.allocator;
    const json =
        \\{"gateway": {"paired_tokens": ["token-1", "token-2", "token-3"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 3), cfg.gateway.paired_tokens.len);
    try std.testing.expectEqualStrings("token-1", cfg.gateway.paired_tokens[0]);
    try std.testing.expectEqualStrings("token-2", cfg.gateway.paired_tokens[1]);
    try std.testing.expectEqualStrings("token-3", cfg.gateway.paired_tokens[2]);
    for (cfg.gateway.paired_tokens) |t| allocator.free(t);
    allocator.free(cfg.gateway.paired_tokens);
}

test "json parse browser allowed domains" {
    const allocator = std.testing.allocator;
    const json =
        \\{"browser": {"enabled": true, "allowed_domains": ["github.com", "docs.rs"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.browser.enabled);
    try std.testing.expectEqual(@as(usize, 2), cfg.browser.allowed_domains.len);
    try std.testing.expectEqualStrings("github.com", cfg.browser.allowed_domains[0]);
    try std.testing.expectEqualStrings("docs.rs", cfg.browser.allowed_domains[1]);
    for (cfg.browser.allowed_domains) |d| allocator.free(d);
    allocator.free(cfg.browser.allowed_domains);
}

test "json parse model routes" {
    const allocator = std.testing.allocator;
    const json =
        \\{"model_routes": [
        \\  {"hint": "reasoning", "provider": "openrouter", "model": "anthropic/claude-opus-4"},
        \\  {"hint": "fast", "provider": "groq", "model": "llama-3.3-70b", "api_key": "gsk_test"}
        \\]}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.model_routes.len);
    try std.testing.expectEqualStrings("reasoning", cfg.model_routes[0].hint);
    try std.testing.expectEqualStrings("openrouter", cfg.model_routes[0].provider);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4", cfg.model_routes[0].model);
    try std.testing.expect(cfg.model_routes[0].api_key == null);
    try std.testing.expectEqualStrings("fast", cfg.model_routes[1].hint);
    try std.testing.expectEqualStrings("groq", cfg.model_routes[1].provider);
    try std.testing.expectEqualStrings("llama-3.3-70b", cfg.model_routes[1].model);
    try std.testing.expectEqualStrings("gsk_test", cfg.model_routes[1].api_key.?);
    // Cleanup
    for (cfg.model_routes) |r| {
        allocator.free(r.hint);
        allocator.free(r.provider);
        allocator.free(r.model);
        if (r.api_key) |k| allocator.free(k);
    }
    allocator.free(cfg.model_routes);
}

test "json parse model routes skips invalid entries" {
    const allocator = std.testing.allocator;
    const json =
        \\{"model_routes": [
        \\  {"hint": "ok", "provider": "p", "model": "m"},
        \\  {"hint": "missing_model", "provider": "p"},
        \\  {"invalid": true}
        \\]}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.model_routes.len);
    try std.testing.expectEqualStrings("ok", cfg.model_routes[0].hint);
    allocator.free(cfg.model_routes[0].hint);
    allocator.free(cfg.model_routes[0].provider);
    allocator.free(cfg.model_routes[0].model);
    allocator.free(cfg.model_routes);
}

test "json parse agents" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"list": [
        \\  {"name": "researcher", "provider": "anthropic", "model": "claude-sonnet-4", "system_prompt": "Research things", "max_depth": 5},
        \\  {"name": "coder", "provider": "openai", "model": "gpt-4o", "api_key": "sk-test", "temperature": 0.3}
        \\]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.agents.len);
    try std.testing.expectEqualStrings("researcher", cfg.agents[0].name);
    try std.testing.expectEqualStrings("anthropic", cfg.agents[0].provider);
    try std.testing.expectEqualStrings("claude-sonnet-4", cfg.agents[0].model);
    try std.testing.expectEqualStrings("Research things", cfg.agents[0].system_prompt.?);
    try std.testing.expectEqual(@as(u32, 5), cfg.agents[0].max_depth);
    try std.testing.expect(cfg.agents[0].api_key == null);
    try std.testing.expectEqualStrings("coder", cfg.agents[1].name);
    try std.testing.expectEqualStrings("openai", cfg.agents[1].provider);
    try std.testing.expectEqualStrings("gpt-4o", cfg.agents[1].model);
    try std.testing.expectEqualStrings("sk-test", cfg.agents[1].api_key.?);
    try std.testing.expectEqual(@as(f64, 0.3), cfg.agents[1].temperature.?);
    try std.testing.expectEqual(@as(u32, 3), cfg.agents[1].max_depth);
    // Cleanup
    for (cfg.agents) |a| {
        allocator.free(a.name);
        allocator.free(a.provider);
        allocator.free(a.model);
        if (a.system_prompt) |sp| allocator.free(sp);
        if (a.api_key) |k| allocator.free(k);
    }
    allocator.free(cfg.agents);
}

test "json parse agents skips invalid entries" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"list": [
        \\  {"name": "ok", "provider": "p", "model": "m"},
        \\  {"name": "missing_model", "provider": "p"},
        \\  42
        \\]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.agents.len);
    try std.testing.expectEqualStrings("ok", cfg.agents[0].name);
    allocator.free(cfg.agents[0].name);
    allocator.free(cfg.agents[0].provider);
    allocator.free(cfg.agents[0].model);
    allocator.free(cfg.agents);
}

// ── Combined: all new fields in one JSON ────────────────────────

test "json parse all new fields together" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "model_routes": [{"hint": "fast", "provider": "groq", "model": "llama-3.3-70b"}],
        \\  "agents": {"list": [{"name": "helper", "provider": "anthropic", "model": "claude-haiku-3.5"}]},
        \\  "autonomy": {"allowed_commands": ["ls"]},
        \\  "gateway": {"paired_tokens": ["tok-1"]},
        \\  "browser": {"allowed_domains": ["example.com"]}
        \\}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.model_routes.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.agents.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.autonomy.allowed_commands.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.gateway.paired_tokens.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.browser.allowed_domains.len);
    // Cleanup
    allocator.free(cfg.model_routes[0].hint);
    allocator.free(cfg.model_routes[0].provider);
    allocator.free(cfg.model_routes[0].model);
    allocator.free(cfg.model_routes);
    allocator.free(cfg.agents[0].name);
    allocator.free(cfg.agents[0].provider);
    allocator.free(cfg.agents[0].model);
    allocator.free(cfg.agents);
    allocator.free(cfg.autonomy.allowed_commands[0]);
    allocator.free(cfg.autonomy.allowed_commands);
    allocator.free(cfg.gateway.paired_tokens[0]);
    allocator.free(cfg.gateway.paired_tokens);
    allocator.free(cfg.browser.allowed_domains[0]);
    allocator.free(cfg.browser.allowed_domains);
}

test "parse agents.defaults.model.primary" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"defaults": {"model": {"primary": "anthropic/claude-opus-4"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("anthropic", cfg.default_provider);
    try std.testing.expectEqualStrings("claude-opus-4", cfg.default_model.?);
    allocator.free(cfg.default_provider);
    allocator.free(cfg.default_model.?);
}

test "parse agents.list with model object" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"list": [{"name": "res", "provider": "anthropic", "model": {"primary": "claude-opus-4"}}]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.agents.len);
    try std.testing.expectEqualStrings("claude-opus-4", cfg.agents[0].model);
    allocator.free(cfg.agents[0].name);
    allocator.free(cfg.agents[0].provider);
    allocator.free(cfg.agents[0].model);
    allocator.free(cfg.agents);
}

test "parse agents.list with id field" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"list": [{"id": "researcher", "provider": "anthropic", "model": "claude-sonnet-4"}]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.agents.len);
    try std.testing.expectEqualStrings("researcher", cfg.agents[0].name);
    allocator.free(cfg.agents[0].name);
    allocator.free(cfg.agents[0].provider);
    allocator.free(cfg.agents[0].model);
    allocator.free(cfg.agents);
}

test "parse top-level bindings with snake_case fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "bindings": [
        \\    {
        \\      "agent_id": "helper",
        \\      "comment": "primary route",
        \\      "match": {
        \\        "channel": "signal",
        \\        "account_id": "phone",
        \\        "peer": {"kind": "group", "id": "grp-1"},
        \\        "guild_id": "guild-9",
        \\        "team_id": "team-2",
        \\        "roles": ["mod", "ops"]
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    try cfg.parseJson(json);

    try std.testing.expectEqual(@as(usize, 1), cfg.agent_bindings.len);
    const binding = cfg.agent_bindings[0];
    try std.testing.expectEqualStrings("helper", binding.agent_id);
    try std.testing.expectEqualStrings("primary route", binding.comment.?);
    try std.testing.expectEqualStrings("signal", binding.match.channel.?);
    try std.testing.expectEqualStrings("phone", binding.match.account_id.?);
    try std.testing.expectEqualStrings("guild-9", binding.match.guild_id.?);
    try std.testing.expectEqualStrings("team-2", binding.match.team_id.?);
    try std.testing.expectEqual(@as(usize, 2), binding.match.roles.len);
    try std.testing.expectEqualStrings("mod", binding.match.roles[0]);
    try std.testing.expectEqualStrings("ops", binding.match.roles[1]);
    try std.testing.expect(binding.match.peer != null);
    try std.testing.expectEqual(@as(@import("agent_routing.zig").ChatType, .group), binding.match.peer.?.kind);
    try std.testing.expectEqualStrings("grp-1", binding.match.peer.?.id);
}

test "ignore nested agents.bindings alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "agents": {
        \\    "bindings": [
        \\      {
        \\        "agent_id": "main",
        \\        "match": {
        \\          "channel": "telegram",
        \\          "peer": {"kind": "direct", "id": "12345"}
        \\        }
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    try cfg.parseJson(json);

    try std.testing.expectEqual(@as(usize, 0), cfg.agent_bindings.len);
}

// ── Environment variable override tests ─────────────────────────

test "applyEnvOverrides does not crash on default config" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    // Should not crash even when no NULLCLAW_* env vars are set
    cfg.applyEnvOverrides();
    // Default values should remain intact
    try std.testing.expectEqualStrings("openrouter", cfg.default_provider);
    try std.testing.expect(cfg.default_model == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.providers.len);
}

test "resolveConfigPaths uses default HOME path when override missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try Config.resolveConfigPaths(allocator, "/home/tester", null);
    try std.testing.expectEqualStrings("/home/tester/.nullalis/config.json", resolved.config_path);
    try std.testing.expectEqualStrings("/home/tester/.nullalis", resolved.config_dir);
    try std.testing.expectEqualStrings("/home/tester/.nullalis/workspace", resolved.workspace_dir);
}

test "resolveConfigPaths accepts absolute NULLALIS_CONFIG_PATH override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try Config.resolveConfigPaths(allocator, "/home/tester", "/tmp/nullalis-custom/config.json");
    try std.testing.expectEqualStrings("/tmp/nullalis-custom/config.json", resolved.config_path);
    try std.testing.expectEqualStrings("/tmp/nullalis-custom", resolved.config_dir);
    try std.testing.expectEqualStrings("/tmp/nullalis-custom/workspace", resolved.workspace_dir);
}

test "resolveConfigPaths ignores relative override and falls back to HOME default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try Config.resolveConfigPaths(allocator, "/home/tester", "config.json");
    try std.testing.expectEqualStrings("/home/tester/.nullalis/config.json", resolved.config_path);
    try std.testing.expectEqualStrings("/home/tester/.nullalis", resolved.config_dir);
    try std.testing.expectEqualStrings("/home/tester/.nullalis/workspace", resolved.workspace_dir);
}

test "json parse mcp_servers" {
    const allocator = std.testing.allocator;
    const json =
        \\{"mcp_servers": {
        \\  "filesystem": {
        \\    "command": "npx",
        \\    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        \\  },
        \\  "git": {
        \\    "command": "mcp-server-git"
        \\  }
        \\}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.mcp_servers.len);
    // Find filesystem entry (order may vary due to hash map)
    var found_fs = false;
    var found_git = false;
    for (cfg.mcp_servers) |s| {
        if (std.mem.eql(u8, s.name, "filesystem")) {
            found_fs = true;
            try std.testing.expectEqualStrings("npx", s.command);
            try std.testing.expectEqual(@as(usize, 3), s.args.len);
            try std.testing.expectEqualStrings("-y", s.args[0]);
        }
        if (std.mem.eql(u8, s.name, "git")) {
            found_git = true;
            try std.testing.expectEqualStrings("mcp-server-git", s.command);
            try std.testing.expectEqual(@as(usize, 0), s.args.len);
        }
    }
    try std.testing.expect(found_fs);
    try std.testing.expect(found_git);
    // Cleanup
    for (cfg.mcp_servers) |s| {
        allocator.free(s.name);
        allocator.free(s.command);
        for (s.args) |a| allocator.free(a);
        allocator.free(s.args);
    }
    allocator.free(cfg.mcp_servers);
}

test "json parse mcp_servers with env" {
    const allocator = std.testing.allocator;
    const json =
        \\{"mcp_servers": {
        \\  "myserver": {
        \\    "command": "/usr/bin/server",
        \\    "args": ["--verbose"],
        \\    "env": {"NODE_ENV": "production", "DEBUG": "true"}
        \\  }
        \\}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    const s = cfg.mcp_servers[0];
    try std.testing.expectEqualStrings("myserver", s.name);
    try std.testing.expectEqualStrings("/usr/bin/server", s.command);
    try std.testing.expectEqual(@as(usize, 1), s.args.len);
    try std.testing.expectEqual(@as(usize, 2), s.env.len);
    // Find env entries (order may vary)
    var found_node = false;
    var found_debug = false;
    for (s.env) |e| {
        if (std.mem.eql(u8, e.key, "NODE_ENV")) {
            found_node = true;
            try std.testing.expectEqualStrings("production", e.value);
        }
        if (std.mem.eql(u8, e.key, "DEBUG")) {
            found_debug = true;
            try std.testing.expectEqualStrings("true", e.value);
        }
    }
    try std.testing.expect(found_node);
    try std.testing.expect(found_debug);
    // Cleanup
    allocator.free(s.name);
    allocator.free(s.command);
    for (s.args) |a| allocator.free(a);
    allocator.free(s.args);
    for (s.env) |e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    allocator.free(s.env);
    allocator.free(cfg.mcp_servers);
}

test "json parse providers section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models": {"providers": {"openrouter": {"api_key": "sk-or-abc"}, "groq": {"api_key": "gsk_123", "base_url": "https://custom.groq.dev"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.providers.len);
    try std.testing.expectEqualStrings("sk-or-abc", cfg.getProviderKey("openrouter").?);
    try std.testing.expectEqualStrings("gsk_123", cfg.getProviderKey("groq").?);
    try std.testing.expectEqualStrings("https://custom.groq.dev", cfg.getProviderBaseUrl("groq").?);
    try std.testing.expect(cfg.getProviderBaseUrl("openrouter") == null);
    // Cleanup
    for (cfg.providers) |e| {
        allocator.free(e.name);
        if (e.api_key) |k| allocator.free(k);
        if (e.base_url) |b| allocator.free(b);
    }
    allocator.free(cfg.providers);
}

test "save writes provider native_tools when false" {
    if (!comptime @hasField(ProviderEntry, "native_tools")) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };
    cfg.providers = &.{
        .{
            .name = "groq",
            .api_key = "gsk_test",
            .native_tools = false,
        },
    };

    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"native_tools\": false") != null);
}

test "json parse tools.media.audio section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tools": {"media": {"audio": {"enabled": true, "language": "en", "models": [{"provider": "openai", "model": "whisper-1", "base_url": "https://api.openai.com/v1/audio/transcriptions"}]}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.audio_media.enabled);
    try std.testing.expectEqualStrings("openai", cfg.audio_media.provider);
    try std.testing.expectEqualStrings("whisper-1", cfg.audio_media.model);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/audio/transcriptions", cfg.audio_media.base_url.?);
    try std.testing.expectEqualStrings("en", cfg.audio_media.language.?);
    allocator.free(cfg.audio_media.provider);
    allocator.free(cfg.audio_media.model);
    allocator.free(cfg.audio_media.base_url.?);
    allocator.free(cfg.audio_media.language.?);
}

test "json parse top-level audio_media alias section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"audio_media": {"enabled": true, "provider": "together", "model": "openai/whisper-large-v3", "base_url": "https://api.together.xyz/v1/audio/transcriptions", "language": "en"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.audio_media.enabled);
    try std.testing.expectEqualStrings("together", cfg.audio_media.provider);
    try std.testing.expectEqualStrings("openai/whisper-large-v3", cfg.audio_media.model);
    try std.testing.expectEqualStrings("https://api.together.xyz/v1/audio/transcriptions", cfg.audio_media.base_url.?);
    try std.testing.expectEqualStrings("en", cfg.audio_media.language.?);
    allocator.free(cfg.audio_media.provider);
    allocator.free(cfg.audio_media.model);
    allocator.free(cfg.audio_media.base_url.?);
    allocator.free(cfg.audio_media.language.?);
}

test "json parse top-level audio_media alias models override direct fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"audio_media": {"enabled": true, "provider": "openai", "model": "whisper-1", "base_url": "https://api.openai.com/v1/audio/transcriptions", "models": [{"provider": "together", "model": "openai/whisper-large-v3", "base_url": "https://api.together.xyz/v1/audio/transcriptions"}]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.audio_media.enabled);
    try std.testing.expectEqualStrings("together", cfg.audio_media.provider);
    try std.testing.expectEqualStrings("openai/whisper-large-v3", cfg.audio_media.model);
    try std.testing.expectEqualStrings("https://api.together.xyz/v1/audio/transcriptions", cfg.audio_media.base_url.?);
    allocator.free(cfg.audio_media.provider);
    allocator.free(cfg.audio_media.model);
    allocator.free(cfg.audio_media.base_url.?);
}

test "getProviderKey returns null for missing provider" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(cfg.getProviderKey("nonexistent") == null);
    try std.testing.expect(cfg.defaultProviderKey() == null);
}

test "providers defaults to empty" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 0), cfg.providers.len);
}

test "audio_media defaults" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(cfg.audio_media.enabled);
    try std.testing.expectEqualStrings("groq", cfg.audio_media.provider);
    try std.testing.expectEqualStrings("whisper-large-v3", cfg.audio_media.model);
    try std.testing.expect(cfg.audio_media.base_url == null);
    try std.testing.expect(cfg.audio_media.language == null);
}

test "defaultProviderKey returns key for default provider" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents":{"defaults":{"model":{"primary":"groq/llama-3.3-70b"}}},"models":{"providers":{"groq":{"api_key":"gsk_found"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("gsk_found", cfg.defaultProviderKey().?);
    // Cleanup
    allocator.free(cfg.default_provider);
    allocator.free(cfg.default_model.?);
    for (cfg.providers) |e| {
        allocator.free(e.name);
        if (e.api_key) |k| allocator.free(k);
        if (e.base_url) |b| allocator.free(b);
    }
    allocator.free(cfg.providers);
}

test "tools.media.audio with language only parses correctly" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tools": {"media": {"audio": {"language": "ru"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("ru", cfg.audio_media.language.?);
    // provider/model remain defaults (string literals, not allocated)
    try std.testing.expectEqualStrings("groq", cfg.audio_media.provider);
    try std.testing.expectEqualStrings("whisper-large-v3", cfg.audio_media.model);
    allocator.free(cfg.audio_media.language.?);
}

test "parse agents.defaults.heartbeat with every string" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"defaults": {"heartbeat": {"every": "30m"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.heartbeat.enabled);
    try std.testing.expectEqual(@as(u32, 30), cfg.heartbeat.interval_minutes);
}

test "parse agents.defaults.heartbeat with hours" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"defaults": {"heartbeat": {"every": "2h"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.heartbeat.enabled);
    try std.testing.expectEqual(@as(u32, 120), cfg.heartbeat.interval_minutes);
}

test "parse agents.defaults.heartbeat disabled" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": {"defaults": {"heartbeat": {"every": "30m", "enabled": false}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.heartbeat.enabled);
    try std.testing.expectEqual(@as(u32, 30), cfg.heartbeat.interval_minutes);
}

test "tools.media.audio disabled" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tools": {"media": {"audio": {"enabled": false}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.audio_media.enabled);
    // defaults remain
    try std.testing.expectEqualStrings("groq", cfg.audio_media.provider);
}

test "parse telegram accounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {"main": {"bot_token": "123:ABC", "tenant_user_id": "42", "allow_from": ["user1"], "reply_in_private": false, "proxy": "socks5://host:1080"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.channels.telegram.len > 0);
    const tg = cfg.channels.telegram[0];
    try std.testing.expectEqualStrings("main", tg.account_id);
    try std.testing.expectEqualStrings("123:ABC", tg.bot_token);
    try std.testing.expectEqualStrings("42", tg.tenant_user_id.?);
    try std.testing.expectEqual(@as(usize, 1), tg.allow_from.len);
    try std.testing.expectEqualStrings("user1", tg.allow_from[0]);
    try std.testing.expect(!tg.reply_in_private);
    try std.testing.expectEqualStrings("socks5://host:1080", tg.proxy.?);
    allocator.free(tg.account_id);
    allocator.free(tg.bot_token);
    allocator.free(tg.tenant_user_id.?);
    for (tg.allow_from) |u| allocator.free(u);
    allocator.free(tg.allow_from);
    allocator.free(tg.proxy.?);
    allocator.free(cfg.channels.telegram);
}

test "parse telegram multi-account sorted alphabetically" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {"main": {"bot_token": "main:tok"}, "default": {"bot_token": "default:tok"}, "backup": {"bot_token": "backup:tok"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 3), cfg.channels.telegram.len);
    // Sorted alphabetically: backup < default < main
    try std.testing.expectEqualStrings("backup", cfg.channels.telegram[0].account_id);
    try std.testing.expectEqualStrings("default", cfg.channels.telegram[1].account_id);
    try std.testing.expectEqualStrings("main", cfg.channels.telegram[2].account_id);
    // Free all accounts
    for (cfg.channels.telegram) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.bot_token);
    }
    allocator.free(cfg.channels.telegram);
}

test "parse telegram accounts keeps single custom account id" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {"phone_1": {"bot_token": "123:ABC"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.channels.telegram.len > 0);
    const tg = cfg.channels.telegram[0];
    try std.testing.expectEqualStrings("phone_1", tg.account_id);
    try std.testing.expectEqualStrings("123:ABC", tg.bot_token);
    allocator.free(tg.account_id);
    allocator.free(tg.bot_token);
    allocator.free(cfg.channels.telegram);
}

test "parse discord accounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"discord": {"accounts": {"main": {"token": "disc-tok", "guild_id": "12345", "allow_from": ["u1"], "require_mention": true}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.channels.discord.len > 0);
    const dc = cfg.channels.discord[0];
    try std.testing.expectEqualStrings("main", dc.account_id);
    try std.testing.expectEqualStrings("disc-tok", dc.token);
    try std.testing.expectEqualStrings("12345", dc.guild_id.?);
    try std.testing.expect(dc.require_mention);
    allocator.free(dc.account_id);
    allocator.free(dc.token);
    allocator.free(dc.guild_id.?);
    for (dc.allow_from) |u| allocator.free(u);
    allocator.free(dc.allow_from);
    allocator.free(cfg.channels.discord);
}

test "parse discord mention_only is ignored (snake_case only)" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"discord": {"accounts": {"main": {"token": "disc-tok", "mention_only": true}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.discord.len);
    try std.testing.expect(!cfg.channels.discord[0].require_mention);
    allocator.free(cfg.channels.discord[0].account_id);
    allocator.free(cfg.channels.discord[0].token);
    allocator.free(cfg.channels.discord);
}

test "parse slack accounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"slack": {"accounts": {"main": {"bot_token": "xoxb-123", "app_token": "xapp-456", "allow_from": ["u1"]}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.channels.slack.len > 0);
    const sc = cfg.channels.slack[0];
    try std.testing.expectEqualStrings("main", sc.account_id);
    try std.testing.expectEqualStrings("xoxb-123", sc.bot_token);
    try std.testing.expectEqualStrings("xapp-456", sc.app_token.?);
    try std.testing.expectEqualStrings("pairing", sc.dm_policy);
    allocator.free(sc.account_id);
    allocator.free(sc.bot_token);
    allocator.free(sc.app_token.?);
    for (sc.allow_from) |u| allocator.free(u);
    allocator.free(sc.allow_from);
    allocator.free(cfg.channels.slack);
}

test "parse irc accounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"irc": {"accounts": {"freenode": {"host": "irc.libera.chat", "nick": "bot", "port": 6667, "channels": ["#test"]}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.irc.len);
    const ic = cfg.channels.irc[0];
    try std.testing.expectEqualStrings("freenode", ic.account_id);
    try std.testing.expectEqualStrings("irc.libera.chat", ic.host);
    try std.testing.expectEqualStrings("bot", ic.nick);
    try std.testing.expectEqual(@as(u16, 6667), ic.port);
    try std.testing.expectEqual(@as(usize, 1), ic.channels.len);
    allocator.free(ic.account_id);
    allocator.free(ic.host);
    allocator.free(ic.nick);
    for (ic.channels) |c| allocator.free(c);
    allocator.free(ic.channels);
    allocator.free(cfg.channels.irc);
}

test "parse matrix accounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"matrix": {"accounts": {"main": {"homeserver": "https://matrix.org", "access_token": "syt_abc", "room_id": "!room:matrix.org", "user_id": "@bot:matrix.org", "group_allow_from": ["@alice:matrix.org"], "group_policy": "open"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.matrix.len);
    const mc = cfg.channels.matrix[0];
    try std.testing.expectEqualStrings("main", mc.account_id);
    try std.testing.expectEqualStrings("https://matrix.org", mc.homeserver);
    try std.testing.expectEqualStrings("syt_abc", mc.access_token);
    try std.testing.expectEqualStrings("!room:matrix.org", mc.room_id);
    try std.testing.expectEqualStrings("@bot:matrix.org", mc.user_id.?);
    try std.testing.expectEqualStrings("open", mc.group_policy);
    try std.testing.expectEqual(@as(usize, 1), mc.group_allow_from.len);
    try std.testing.expectEqualStrings("@alice:matrix.org", mc.group_allow_from[0]);
    allocator.free(mc.account_id);
    allocator.free(mc.homeserver);
    allocator.free(mc.access_token);
    allocator.free(mc.room_id);
    allocator.free(mc.user_id.?);
    allocator.free(mc.group_policy);
    for (mc.group_allow_from) |entry| allocator.free(entry);
    allocator.free(mc.group_allow_from);
    allocator.free(cfg.channels.matrix);
}

test "parse mattermost accounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{"channels": {"mattermost": {"accounts": {"main": {"bot_token": "mm-token", "base_url": "https://chat.example.com", "allow_from": ["user-a"], "group_allow_from": ["@alice"], "dm_policy": "open", "group_policy": "allowlist", "chatmode": "onchar", "onchar_prefixes": ["!"], "require_mention": false}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);

    try std.testing.expectEqual(@as(usize, 1), cfg.channels.mattermost.len);
    const mm = cfg.channels.mattermost[0];
    try std.testing.expectEqualStrings("main", mm.account_id);
    try std.testing.expectEqualStrings("mm-token", mm.bot_token);
    try std.testing.expectEqualStrings("https://chat.example.com", mm.base_url);
    try std.testing.expectEqual(@as(usize, 1), mm.allow_from.len);
    try std.testing.expectEqualStrings("user-a", mm.allow_from[0]);
    try std.testing.expectEqual(@as(usize, 1), mm.group_allow_from.len);
    try std.testing.expectEqualStrings("@alice", mm.group_allow_from[0]);
    try std.testing.expectEqualStrings("open", mm.dm_policy);
    try std.testing.expectEqualStrings("allowlist", mm.group_policy);
    try std.testing.expectEqualStrings("onchar", mm.chatmode);
    try std.testing.expectEqual(@as(usize, 1), mm.onchar_prefixes.len);
    try std.testing.expectEqualStrings("!", mm.onchar_prefixes[0]);
    try std.testing.expect(!mm.require_mention);
}

test "parse lark accounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"lark": {"accounts": {"main": {"app_id": "cli_abc", "app_secret": "sec123", "use_feishu": true}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.lark.len);
    const lc = cfg.channels.lark[0];
    try std.testing.expectEqualStrings("main", lc.account_id);
    try std.testing.expectEqualStrings("cli_abc", lc.app_id);
    try std.testing.expectEqualStrings("sec123", lc.app_secret);
    try std.testing.expect(lc.use_feishu);
    allocator.free(lc.account_id);
    allocator.free(lc.app_id);
    allocator.free(lc.app_secret);
    allocator.free(cfg.channels.lark);
}

// "parse dingtalk accounts" test deleted Sprint 8 (S8.4+S8.6, 2026-04-24)
// alongside the channel itself.

test "parse whatsapp accounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"whatsapp": {"accounts": {"main": {"access_token": "wa-tok", "phone_number_id": "12345", "verify_token": "vtok", "app_secret": "sec", "allow_from": ["+1234"]}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.whatsapp.len);
    const wc = cfg.channels.whatsapp[0];
    try std.testing.expectEqualStrings("main", wc.account_id);
    try std.testing.expectEqualStrings("wa-tok", wc.access_token);
    try std.testing.expectEqualStrings("12345", wc.phone_number_id);
    try std.testing.expectEqualStrings("vtok", wc.verify_token);
    try std.testing.expectEqualStrings("sec", wc.app_secret.?);
    try std.testing.expectEqual(@as(usize, 1), wc.allow_from.len);
    allocator.free(wc.account_id);
    allocator.free(wc.access_token);
    allocator.free(wc.phone_number_id);
    allocator.free(wc.verify_token);
    allocator.free(wc.app_secret.?);
    for (wc.allow_from) |u| allocator.free(u);
    allocator.free(wc.allow_from);
    allocator.free(cfg.channels.whatsapp);
}

test "parse signal multi-account sorted alphabetically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"channels": {"signal": {"accounts": {"z-main": {"http_url": "http://localhost:8082", "account": "+155502", "ignore_attachments": true}, "a-main": {"http_url": "http://localhost:8081", "account": "+155501"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.signal.len);
    try std.testing.expectEqualStrings("a-main", cfg.channels.signal[0].account_id);
    try std.testing.expectEqualStrings("+155501", cfg.channels.signal[0].account);
    try std.testing.expectEqualStrings("z-main", cfg.channels.signal[1].account_id);
    try std.testing.expect(cfg.channels.signal[1].ignore_attachments);
}

test "parse qq accounts include allowlist and allowed_groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"channels": {"qq": {"accounts": {"qq-backup": {"app_id": "app2", "bot_token": "tok2"}, "qq-main": {"app_id": "app1", "app_secret": "sec1", "bot_token": "tok1", "group_policy": "allowlist", "allowed_groups": ["group-a", "group-b"], "allow_from": ["user-a"]}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.qq.len);
    try std.testing.expectEqualStrings("qq-backup", cfg.channels.qq[0].account_id);
    try std.testing.expectEqualStrings("qq-main", cfg.channels.qq[1].account_id);
    try std.testing.expectEqual(config_types.QQGroupPolicy.allowlist, cfg.channels.qq[1].group_policy);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.qq[1].allowed_groups.len);
    try std.testing.expectEqualStrings("group-a", cfg.channels.qq[1].allowed_groups[0]);
    try std.testing.expectEqualStrings("group-b", cfg.channels.qq[1].allowed_groups[1]);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.qq[1].allow_from.len);
    try std.testing.expectEqualStrings("user-a", cfg.channels.qq[1].allow_from[0]);
}

test "parse onebot multi-account sorted alphabetically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"channels": {"onebot": {"accounts": {"west": {"url": "ws://west.local:6700"}, "east": {"url": "ws://east.local:6700", "group_trigger_prefix": "/bot"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.onebot.len);
    try std.testing.expectEqualStrings("east", cfg.channels.onebot[0].account_id);
    try std.testing.expectEqualStrings("ws://east.local:6700", cfg.channels.onebot[0].url);
    try std.testing.expectEqualStrings("/bot", cfg.channels.onebot[0].group_trigger_prefix.?);
    try std.testing.expectEqualStrings("west", cfg.channels.onebot[1].account_id);
}

test "parse onebot account_id in payload is overridden by account key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"channels": {"onebot": {"accounts": {"edge": {"account_id": "wrong", "url": "ws://edge.local:6700"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.onebot.len);
    try std.testing.expectEqualStrings("edge", cfg.channels.onebot[0].account_id);
    try std.testing.expectEqualStrings("ws://edge.local:6700", cfg.channels.onebot[0].url);
}

test "parse maixcam multi-account sorted with custom names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"channels": {"maixcam": {"accounts": {"cam-z": {"port": 8888, "name": "vision-z"}, "cam-a": {"port": 7777, "name": "vision-a", "allow_from": ["device-1"]}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.maixcam.len);
    try std.testing.expectEqualStrings("cam-a", cfg.channels.maixcam[0].account_id);
    try std.testing.expectEqualStrings("vision-a", cfg.channels.maixcam[0].name);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.maixcam[0].allow_from.len);
    try std.testing.expectEqualStrings("device-1", cfg.channels.maixcam[0].allow_from[0]);
    try std.testing.expectEqualStrings("cam-z", cfg.channels.maixcam[1].account_id);
    try std.testing.expectEqual(@as(u16, 8888), cfg.channels.maixcam[1].port);
}

test "multi-account channels keep all accounts sorted by account id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"channels": {"line": {"accounts": {"main": {"access_token": "line-main", "channel_secret": "line-main-secret"}, "default": {"access_token": "line-default", "channel_secret": "line-default-secret"}}}, "whatsapp": {"accounts": {"main": {"access_token": "wa-main", "phone_number_id": "100", "verify_token": "main-v"}, "default": {"access_token": "wa-default", "phone_number_id": "200", "verify_token": "default-v"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.line.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.whatsapp.len);
    try std.testing.expectEqualStrings("default", cfg.channels.line[0].account_id);
    try std.testing.expectEqualStrings("line-default", cfg.channels.line[0].access_token);
    try std.testing.expectEqualStrings("main", cfg.channels.line[1].account_id);
    try std.testing.expectEqualStrings("default", cfg.channels.whatsapp[0].account_id);
    try std.testing.expectEqualStrings("wa-default", cfg.channels.whatsapp[0].access_token);
    try std.testing.expectEqualStrings("main", cfg.channels.whatsapp[1].account_id);
}

test "multi-account channels without default keep sorted order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"channels": {"lark": {"accounts": {"backup": {"app_id": "app-b", "app_secret": "sec-b"}, "main": {"app_id": "app-main", "app_secret": "sec-main"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.lark.len);
    try std.testing.expectEqualStrings("backup", cfg.channels.lark[0].account_id);
    try std.testing.expectEqualStrings("app-b", cfg.channels.lark[0].app_id);
    try std.testing.expectEqualStrings("main", cfg.channels.lark[1].account_id);
    try std.testing.expectEqualStrings("app-main", cfg.channels.lark[1].app_id);
}

test "parse imessage config" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"imessage": {"enabled": true, "allow_from": ["user@icloud.com"]}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.channels.imessage.len);
    const ic = cfg.channels.imessage[0];
    try std.testing.expectEqualStrings("default", ic.account_id);
    try std.testing.expect(ic.enabled);
    try std.testing.expectEqual(@as(usize, 1), ic.allow_from.len);
    for (ic.allow_from) |u| allocator.free(u);
    allocator.free(ic.allow_from);
    allocator.free(cfg.channels.imessage);
}

test "parse imessage multi-account and preferred primary" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"imessage": {"accounts": {"main": {"enabled": true}, "default": {"enabled": false}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.imessage.len);

    const primary = cfg.channels.imessagePrimary();
    try std.testing.expect(primary != null);
    try std.testing.expectEqualStrings("default", primary.?.account_id);
    try std.testing.expect(!primary.?.enabled);

    for (cfg.channels.imessage) |acc| allocator.free(acc.account_id);
    allocator.free(cfg.channels.imessage);
}

test "json parse reasoning_effort" {
    const allocator = std.testing.allocator;
    const json =
        \\{"reasoning_effort": "high"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("high", cfg.reasoning_effort.?);
    allocator.free(cfg.reasoning_effort.?);
}

test "json parse invalid reasoning_effort ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\{"reasoning_effort": "invalid"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.reasoning_effort == null);
}

test "json parse reasoning_effort medium" {
    const allocator = std.testing.allocator;
    const json =
        \\{"reasoning_effort": "medium"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("medium", cfg.reasoning_effort.?);
    allocator.free(cfg.reasoning_effort.?);
}

test "json parse reasoning_effort low" {
    const allocator = std.testing.allocator;
    const json =
        \\{"reasoning_effort": "low"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("low", cfg.reasoning_effort.?);
    allocator.free(cfg.reasoning_effort.?);
}

test "unknown foreign fields silently ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models": {"bedrock_discovery": true, "providers": {}}, "tts": {"enabled": true}, "session": {}, "ui": {}, "skills": []}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    // Should not crash — unknown fields are silently ignored
    try std.testing.expectEqual(@as(usize, 0), cfg.providers.len);
}

// ═══════════════════════════════════════════════════════════════════════════
// Parity tests: multi-account config, account list helpers, session config
// ═══════════════════════════════════════════════════════════════════════════

test "multi-account: empty accounts object returns empty slice" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 0), cfg.channels.telegram.len);
}

test "multi-account: missing accounts key returns empty slice" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 0), cfg.channels.telegram.len);
}

test "multi-account: missing channel config returns empty slice" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 0), cfg.channels.telegram.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.channels.discord.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.channels.slack.len);
}

test "multi-account: sorted alphabetically across channels" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"discord": {"accounts": {"z-server": {"token": "zt"}, "a-server": {"token": "at"}, "m-server": {"token": "mt"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 3), cfg.channels.discord.len);
    try std.testing.expectEqualStrings("a-server", cfg.channels.discord[0].account_id);
    try std.testing.expectEqualStrings("m-server", cfg.channels.discord[1].account_id);
    try std.testing.expectEqualStrings("z-server", cfg.channels.discord[2].account_id);
    for (cfg.channels.discord) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.token);
    }
    allocator.free(cfg.channels.discord);
}

test "multi-account: telegram primary falls back to first account when no default/main exists" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {"alpha": {"bot_token": "a-tok"}, "beta": {"bot_token": "b-tok"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    const primary = cfg.channels.telegramPrimary();
    try std.testing.expect(primary != null);
    try std.testing.expectEqualStrings("alpha", primary.?.account_id);
    for (cfg.channels.telegram) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.bot_token);
    }
    allocator.free(cfg.channels.telegram);
}

test "multi-account: primary prefers default then main account ids" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {"zeta": {"bot_token": "z-tok"}, "default": {"bot_token": "d-tok"}, "main": {"bot_token": "m-tok"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    const primary = cfg.channels.telegramPrimary();
    try std.testing.expect(primary != null);
    try std.testing.expectEqualStrings("default", primary.?.account_id);
    try std.testing.expectEqualStrings("d-tok", primary.?.bot_token);

    for (cfg.channels.telegram) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.bot_token);
    }
    allocator.free(cfg.channels.telegram);
}

test "multi-account: primary returns null for empty slice" {
    const cfg_ch = config_types.ChannelsConfig{};
    try std.testing.expect(cfg_ch.telegramPrimary() == null);
    try std.testing.expect(cfg_ch.discordPrimary() == null);
    try std.testing.expect(cfg_ch.slackPrimary() == null);
    try std.testing.expect(cfg_ch.signalPrimary() == null);
    try std.testing.expect(cfg_ch.imessagePrimary() == null);
    try std.testing.expect(cfg_ch.mattermostPrimary() == null);
    try std.testing.expect(cfg_ch.qqPrimary() == null);
    try std.testing.expect(cfg_ch.onebotPrimary() == null);
    try std.testing.expect(cfg_ch.maixcamPrimary() == null);
}

test "multi-account: account config overrides base fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {"work": {"bot_token": "work-tok", "reply_in_private": true}, "personal": {"bot_token": "pers-tok"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.channels.telegram.len);
    // personal < work alphabetically
    try std.testing.expectEqualStrings("personal", cfg.channels.telegram[0].account_id);
    try std.testing.expectEqualStrings("pers-tok", cfg.channels.telegram[0].bot_token);
    try std.testing.expect(cfg.channels.telegram[0].reply_in_private); // default is true
    try std.testing.expectEqualStrings("work", cfg.channels.telegram[1].account_id);
    try std.testing.expectEqualStrings("work-tok", cfg.channels.telegram[1].bot_token);
    try std.testing.expect(cfg.channels.telegram[1].reply_in_private);
    for (cfg.channels.telegram) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.bot_token);
    }
    allocator.free(cfg.channels.telegram);
}

test "multi-account: multiple channels configured simultaneously" {
    const allocator = std.testing.allocator;
    const json =
        \\{"channels": {"telegram": {"accounts": {"main": {"bot_token": "tg-tok"}}}, "discord": {"accounts": {"main": {"token": "dc-tok"}}}, "slack": {"accounts": {"main": {"bot_token": "sl-tok"}}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.channels.telegram.len > 0);
    try std.testing.expect(cfg.channels.discord.len > 0);
    try std.testing.expect(cfg.channels.slack.len > 0);
    try std.testing.expectEqualStrings("tg-tok", cfg.channels.telegram[0].bot_token);
    try std.testing.expectEqualStrings("dc-tok", cfg.channels.discord[0].token);
    try std.testing.expectEqualStrings("sl-tok", cfg.channels.slack[0].bot_token);
    for (cfg.channels.telegram) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.bot_token);
    }
    allocator.free(cfg.channels.telegram);
    for (cfg.channels.discord) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.token);
    }
    allocator.free(cfg.channels.discord);
    for (cfg.channels.slack) |acc| {
        allocator.free(acc.account_id);
        allocator.free(acc.bot_token);
    }
    allocator.free(cfg.channels.slack);
}

test "session config: parse dm_scope with dash format" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"dm_scope": "per-peer"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(config_types.DmScope.per_peer, cfg.session.dm_scope);
}

test "session config: parse dm_scope with underscore format" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"dm_scope": "per_peer"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(config_types.DmScope.per_peer, cfg.session.dm_scope);
}

test "session config: parse per-account-channel-peer scope" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"dm_scope": "per-account-channel-peer"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(config_types.DmScope.per_account_channel_peer, cfg.session.dm_scope);
}

test "session config: default dm_scope is main" {
    const allocator = std.testing.allocator;
    const json =
        \\{}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(config_types.DmScope.main, cfg.session.dm_scope);
}

test "session config: parse idle_minutes" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"idle_minutes": 30}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(u32, 30), cfg.session.idle_minutes);
}

test "session config: ignores idleMinutes camelCase alias" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"idleMinutes": 45}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(u32, 60), cfg.session.idle_minutes);
}

test "session config: parse identity_links map format" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"identity_links": {"alice": ["telegram:111", "discord:222"]}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.session.identity_links.len);
    try std.testing.expectEqualStrings("alice", cfg.session.identity_links[0].canonical);
    try std.testing.expectEqual(@as(usize, 2), cfg.session.identity_links[0].peers.len);
    allocator.free(cfg.session.identity_links[0].canonical);
    for (cfg.session.identity_links[0].peers) |p| allocator.free(p);
    allocator.free(cfg.session.identity_links[0].peers);
    allocator.free(cfg.session.identity_links);
}

test "session config: parse identity_links array format" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"identity_links": [{"canonical": "bob", "peers": ["slack:999"]}]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.session.identity_links.len);
    try std.testing.expectEqualStrings("bob", cfg.session.identity_links[0].canonical);
    try std.testing.expectEqual(@as(usize, 1), cfg.session.identity_links[0].peers.len);
    try std.testing.expectEqualStrings("slack:999", cfg.session.identity_links[0].peers[0]);
    allocator.free(cfg.session.identity_links[0].canonical);
    for (cfg.session.identity_links[0].peers) |p| allocator.free(p);
    allocator.free(cfg.session.identity_links[0].peers);
    allocator.free(cfg.session.identity_links);
}

test "session config: empty session block uses defaults" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(config_types.DmScope.main, cfg.session.dm_scope);
    try std.testing.expectEqual(@as(u32, 60), cfg.session.idle_minutes);
    try std.testing.expectEqual(@as(usize, 0), cfg.session.identity_links.len);
}

test "session config: all dm_scope values accepted" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ "main", config_types.DmScope.main },
        .{ "per-peer", config_types.DmScope.per_peer },
        .{ "per-channel-peer", config_types.DmScope.per_channel_peer },
        .{ "per-account-channel-peer", config_types.DmScope.per_account_channel_peer },
        .{ "per_peer", config_types.DmScope.per_peer },
        .{ "per_channel_peer", config_types.DmScope.per_channel_peer },
        .{ "per_account_channel_peer", config_types.DmScope.per_account_channel_peer },
    };
    inline for (cases) |c| {
        const json = "{\"session\": {\"dm_scope\": \"" ++ c[0] ++ "\"}}";
        var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
        try cfg.parseJson(json);
        try std.testing.expectEqual(c[1], cfg.session.dm_scope);
    }
}

test "gateway config parses internal_service_tokens" {
    const allocator = std.testing.allocator;
    const json =
        \\{"gateway": {"internal_service_tokens": ["svc-1", "svc-2"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.gateway.internal_service_tokens.len);
    try std.testing.expectEqualStrings("svc-1", cfg.gateway.internal_service_tokens[0]);
    try std.testing.expectEqualStrings("svc-2", cfg.gateway.internal_service_tokens[1]);
    for (cfg.gateway.internal_service_tokens) |t| allocator.free(t);
    allocator.free(cfg.gateway.internal_service_tokens);
}

test "gateway config parses extension_tokens with token_previous rotation field" {
    // Plan-8 (2026-06-06) — the rotation-window previous token must
    // round-trip through config parsing. Entry 0 has a previous token
    // (window open); entry 1 omits it (null); entry 2 sets "" which
    // must normalize to null so a blank token can't be admitted.
    const allocator = std.testing.allocator;
    const json =
        \\{"gateway": {"extension_tokens": [
        \\  {"token": "new-a", "user_id": "alice", "token_previous": "old-a"},
        \\  {"token": "tok-b", "user_id": "bob"},
        \\  {"token": "tok-c", "user_id": "carol", "token_previous": ""}
        \\]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    const ext = cfg.gateway.extension_tokens;
    try std.testing.expectEqual(@as(usize, 3), ext.len);

    try std.testing.expectEqualStrings("new-a", ext[0].token);
    try std.testing.expectEqualStrings("alice", ext[0].user_id);
    try std.testing.expectEqualStrings("old-a", ext[0].token_previous.?);

    try std.testing.expectEqualStrings("tok-b", ext[1].token);
    try std.testing.expect(ext[1].token_previous == null);

    try std.testing.expectEqualStrings("tok-c", ext[2].token);
    // "" must normalize to null (not an empty-string previous token).
    try std.testing.expect(ext[2].token_previous == null);

    for (ext) |e| {
        allocator.free(e.token);
        allocator.free(e.user_id);
        if (e.token_previous) |p| allocator.free(p);
    }
    allocator.free(ext);
}

test "secret runtime overrides set internal token and postgres connection string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };

    const internal_token = try allocator.dupe(u8, "prod-internal-token-1234");
    const connection_string = try allocator.dupe(u8, "postgresql://zaki:zaki@127.0.0.1:5432/zaki");

    cfg.applySecretRuntimeOverrides(internal_token, connection_string);

    try std.testing.expectEqual(@as(usize, 1), cfg.gateway.internal_service_tokens.len);
    try std.testing.expectEqualStrings("prod-internal-token-1234", cfg.gateway.internal_service_tokens[0]);
    try std.testing.expectEqualStrings("postgresql://zaki:zaki@127.0.0.1:5432/zaki", cfg.state.postgres.connection_string);
}

test "tenant config parses enabled and data_root" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tenant": {"enabled": true, "data_root": "/var/lib/nullalis/users"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.tenant.enabled);
    try std.testing.expectEqualStrings("/var/lib/nullalis/users", cfg.tenant.data_root);
    allocator.free(cfg.tenant.data_root);
}

test "session config parses cross_channel_shared_main" {
    const allocator = std.testing.allocator;
    const json =
        \\{"session": {"cross_channel_shared_main": false}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.session.cross_channel_shared_main);
}

test "profile zaki_bot enables http request defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"profile": "zaki_bot"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("zaki_bot", cfg.profile);
    try std.testing.expect(cfg.http_request.enabled);
    try std.testing.expect(!cfg.browser.enabled);
    // Primary route: Moonshot native API with the bare `kimi-k2.6` ID.
    try std.testing.expectEqualStrings("moonshot", cfg.default_provider);
    try std.testing.expectEqualStrings("kimi-k2.6", cfg.default_model.?);
    // Together stays a cross-provider fallback via the `provider/model` ref
    // form — runtime_bundle splits it into a per-provider model override
    // (Together's `moonshotai/Kimi-K2.6` ID). No `model_fallbacks` entry.
    try std.testing.expectEqual(@as(usize, 1), cfg.reliability.fallback_providers.len);
    try std.testing.expectEqualStrings("together/moonshotai/Kimi-K2.6", cfg.reliability.fallback_providers[0]);
    try std.testing.expectEqual(@as(usize, 0), cfg.reliability.model_fallbacks.len);
    try std.testing.expectEqualStrings("postgres_hybrid", cfg.memory.profile);
    try std.testing.expectEqualStrings("postgres", cfg.memory.backend);
    try std.testing.expectEqualStrings("together", cfg.memory.search.provider);
    try std.testing.expect(cfg.memory.search.query.hybrid.enabled);
    try std.testing.expectEqualStrings("pgvector", cfg.memory.search.store.kind);
    try std.testing.expectEqualStrings("on", cfg.memory.reliability.rollout_mode);
    try std.testing.expect(cfg.memory.search.query.hybrid.mmr.enabled);
    try std.testing.expect(cfg.memory.search.query.hybrid.temporal_decay.enabled);
}

test "profile defaults do not override explicit http request disable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"profile": "zaki_bot", "http_request": {"enabled": false}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.http_request.enabled);
    try std.testing.expectEqualStrings("moonshot", cfg.default_provider);
    try std.testing.expectEqualStrings("kimi-k2.6", cfg.default_model.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.reliability.fallback_providers.len);
    try std.testing.expectEqualStrings("together/moonshotai/Kimi-K2.6", cfg.reliability.fallback_providers[0]);
}

test "profile defaults do not override explicit model primary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"profile": "zaki_bot", "agents": {"defaults": {"model": {"primary": "anthropic/claude-opus-4"}}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("anthropic", cfg.default_provider);
    try std.testing.expectEqualStrings("claude-opus-4", cfg.default_model.?);
    try std.testing.expectEqual(@as(usize, 0), cfg.reliability.fallback_providers.len);
}

test "zaki_bot validation requires provider entry token and postgres" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
        .profile = "zaki_bot",
        .default_provider = "together-ai",
        .default_model = "moonshotai/Kimi-K2.6",
    };

    cfg.providers = &.{
        .{ .name = "together-ai", .api_key = "together-valid-key", .base_url = "https://api.together.xyz/v1" },
    };
    cfg.state.backend = "postgres";
    cfg.applySecretRuntimeOverrides(
        try allocator.dupe(u8, "prod-internal-token-1234"),
        try allocator.dupe(u8, "postgresql://zaki:zaki@127.0.0.1:5432/zaki"),
    );

    try cfg.validate();
}

test "zaki_bot validation rejects missing provider config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
        .profile = "zaki_bot",
        .default_provider = "together-ai",
        .default_model = "moonshotai/Kimi-K2.6",
    };
    cfg.state.backend = "postgres";
    cfg.applySecretRuntimeOverrides(
        try allocator.dupe(u8, "prod-internal-token-1234"),
        try allocator.dupe(u8, "postgresql://zaki:zaki@127.0.0.1:5432/zaki"),
    );

    try std.testing.expectError(Config.ValidationError.MissingDefaultProviderConfig, cfg.validate());
}

test "zaki_bot validation rejects missing together api key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
        .profile = "zaki_bot",
        .default_provider = "together-ai",
        .default_model = "moonshotai/Kimi-K2.6",
    };

    cfg.providers = &.{
        .{ .name = "together-ai", .base_url = "https://api.together.xyz/v1" },
    };
    cfg.state.backend = "postgres";
    cfg.applySecretRuntimeOverrides(
        try allocator.dupe(u8, "prod-internal-token-1234"),
        try allocator.dupe(u8, "postgresql://zaki:zaki@127.0.0.1:5432/zaki"),
    );

    try std.testing.expectError(Config.ValidationError.MissingTogetherApiKey, cfg.validate());
}

test "zaki_bot validation rejects placeholder internal service token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
        .profile = "zaki_bot",
        .default_provider = "together-ai",
        .default_model = "moonshotai/Kimi-K2.6",
    };

    cfg.providers = &.{
        .{ .name = "together-ai", .api_key = "together-valid-key", .base_url = "https://api.together.xyz/v1" },
    };
    cfg.state.backend = "postgres";
    cfg.applySecretRuntimeOverrides(
        try allocator.dupe(u8, "REPLACE_WITH_STRONG_RANDOM_TOKEN"),
        try allocator.dupe(u8, "postgresql://zaki:zaki@127.0.0.1:5432/zaki"),
    );

    try std.testing.expectError(Config.ValidationError.InvalidInternalServiceToken, cfg.validate());
}

test "zaki_bot validation rejects placeholder postgres connection string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
        .profile = "zaki_bot",
        .default_provider = "together-ai",
        .default_model = "moonshotai/Kimi-K2.6",
    };

    cfg.providers = &.{
        .{ .name = "together-ai", .api_key = "together-valid-key", .base_url = "https://api.together.xyz/v1" },
    };
    cfg.state.backend = "postgres";
    cfg.applySecretRuntimeOverrides(
        try allocator.dupe(u8, "prod-internal-token-1234"),
        try allocator.dupe(u8, "REPLACE_WITH_POSTGRES_CONNECTION_STRING"),
    );

    try std.testing.expectError(Config.ValidationError.InvalidPostgresConnectionString, cfg.validate());
}

test "tools config parses web_search_provider" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tools": {"web_search_provider": "exa"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("exa", cfg.tools.web_search_provider);
    allocator.free(cfg.tools.web_search_provider);
}

test "tools config parses web search api keys" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tools": {"web_search_exa_api_key": "exa-test", "web_search_brave_api_key": "brave-test"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("exa-test", cfg.tools.web_search_exa_api_key);
    try std.testing.expectEqualStrings("brave-test", cfg.tools.web_search_brave_api_key);
    allocator.free(cfg.tools.web_search_exa_api_key);
    allocator.free(cfg.tools.web_search_brave_api_key);
}

test "legacy top-level web search keys map into tools config" {
    const allocator = std.testing.allocator;
    const json =
        \\{"exa_api_key":"exa-legacy","brave_api_key":"brave-legacy"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("exa-legacy", cfg.tools.web_search_exa_api_key);
    try std.testing.expectEqualStrings("brave-legacy", cfg.tools.web_search_brave_api_key);
    allocator.free(cfg.tools.web_search_exa_api_key);
    allocator.free(cfg.tools.web_search_brave_api_key);
}

test "tools web search keys override legacy top-level keys" {
    const allocator = std.testing.allocator;
    const json =
        \\{"exa_api_key":"exa-legacy","brave_api_key":"brave-legacy","tools":{"web_search_exa_api_key":"exa-tools","web_search_brave_api_key":"brave-tools"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("exa-tools", cfg.tools.web_search_exa_api_key);
    try std.testing.expectEqualStrings("brave-tools", cfg.tools.web_search_brave_api_key);
    allocator.free(cfg.tools.web_search_exa_api_key);
    allocator.free(cfg.tools.web_search_brave_api_key);
}

test "save and parse preserve profile" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{base});
    defer allocator.free(config_path);

    var cfg_arena = std.heap.ArenaAllocator.init(allocator);
    defer cfg_arena.deinit();
    var cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = cfg_arena.allocator(),
    };
    try cfg.parseJson("{\"profile\": \"zaki_bot\"}");

    try cfg.save();

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = arena.allocator(),
    };
    try loaded.parseJson(content);

    try std.testing.expectEqualStrings("zaki_bot", loaded.profile);
    try std.testing.expect(loaded.http_request.enabled);
}
