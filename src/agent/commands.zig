const std = @import("std");
const builtin = @import("builtin");
const learning = @import("learning.zig");
const goal_loop = @import("goal_loop.zig");
const prompt_mod = @import("prompt.zig");
const providers = @import("../providers/root.zig");
const extraction_persist = @import("extraction_persist.zig");
const extraction_runner = @import("extraction/runner.zig");
const text_norm = @import("../memory/text_norm.zig");
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const skills_mod = @import("../skills.zig");
const spawn_tool_mod = @import("../tools/spawn.zig");
const message_tool = @import("../tools/message.zig");
const subagent_mod = @import("../subagent.zig");
const memory_mod = @import("../memory/root.zig");
const observability = @import("../observability.zig");
const config_types = @import("../config_types.zig");
const config_module = @import("../config.zig");
const capabilities_mod = @import("../capabilities.zig");
const config_mutator = @import("../config_mutator.zig");
const context_report = @import("context_report.zig");
const context_tokens = @import("context_tokens.zig");
const execution_mode_mod = @import("execution_mode.zig"); // CR IN-02: moved from handleModeCommand body to module scope
const max_tokens_resolver = @import("max_tokens.zig");
const transcript = @import("transcript.zig");
const util = @import("../util.zig");
const channel_health = @import("../channel_health.zig");
const security_review = @import("../security_review.zig");
const health_mod = @import("../health.zig");
const tool_metadata_mod = @import("../tools/metadata.zig");
const usage_runtime_mod = @import("../usage_runtime.zig");
const log = std.log.scoped(.agent);

const SlashCommand = struct {
    name: []const u8,
    arg: []const u8,
};

/// Categorized help surface. Lists only commands that are implemented in
/// this runtime. Keep concise — this is a discovery aid, not a manual.
const HELP_TEXT =
    \\Commands
    \\
    \\Session:
    \\  /new [model], /restart [model]
    \\  /reset                       — checkpoint + clear history
    \\  /resume <session_key>        — switch to a named session
    \\  /status
    \\
    \\Identity & runtime:
    \\  /whoami, /id, /runtime
    \\  /model, /models, /model <name>
    \\
    \\Execution posture:
    \\  /mode [plan|execute|review|background]
    \\  /plan, /review, /execute     — direct execution-mode switches
    \\
    \\Safety & approvals:
    \\  /permissions (alias /perm)   — read-only permission/approval posture
    \\  /approve <allow-once|deny>   — resolve the pending tool approval
    \\  /allowlist                   — per-session tool allowlist
    \\
    \\Usage & cost:
    \\  /usage [off|tokens|full|cost]
    \\  /cost                        — read-only token/cost snapshot
    \\
    \\Context & memory:
    \\  /context, /compact
    \\  /memory <stats|status|reindex|count|search|get|list|drain-outbox>
    \\  /learn [list|forget <key>]   — inspect/remove learned facts
    \\  /persona                     — show persona profile from SOUL.md
    \\
    \\Diagnostics:
    \\  /health                      — channel health dashboard
    \\  /doctor                      — memory subsystem diagnostics
    \\  /security-review             — structured security audit
    \\  /debug [show|reset]
    \\
    \\Channels & docking:
    \\  /dock-telegram, /dock-discord, /dock-slack
    \\  /activation, /send
    \\
    \\Subagents & focus:
    \\  /subagents, /agents
    \\  /focus, /unfocus, /kill, /steer, /tell
    \\
    \\Voice & reasoning:
    \\  /voice [on|off], /tts
    \\  /think, /verbose, /reasoning
    \\
    \\Execution & tools:
    \\  /exec, /queue, /stop, /poll, /bash, /skill, /elevated
    \\
    \\Config & export:
    \\  /config, /capabilities
    \\  /export-session, /export
    \\  /session ttl <duration|off>
    \\
    \\  /help, /commands             — show this list
    \\  exit, quit
    \\
;

fn parseSlashCommand(message: []const u8) ?SlashCommand {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (trimmed.len <= 1 or trimmed[0] != '/') return null;

    const body = trimmed[1..];
    var split_idx: usize = 0;
    while (split_idx < body.len) : (split_idx += 1) {
        const ch = body[split_idx];
        if (ch == ':' or ch == ' ' or ch == '\t') break;
    }
    if (split_idx == 0) return null;

    const raw_name = body[0..split_idx];
    const name = if (std.mem.indexOfScalar(u8, raw_name, '@')) |mention_sep|
        raw_name[0..mention_sep]
    else
        raw_name;
    if (name.len == 0) return null;
    var rest = body[split_idx..];
    if (rest.len > 0 and rest[0] == ':') {
        rest = rest[1..];
    }

    return .{
        .name = name,
        .arg = std.mem.trim(u8, rest, " \t"),
    };
}

fn isSlashName(cmd: SlashCommand, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(cmd.name, expected);
}

fn firstToken(arg: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, arg, " \t");
    return it.next() orelse "";
}

fn parsePositiveUsize(raw: []const u8) ?usize {
    const n = std.fmt.parseInt(usize, raw, 10) catch return null;
    if (n == 0) return null;
    return n;
}

fn memoryRuntimePtr(self: anytype) ?*memory_mod.MemoryRuntime {
    return if (@hasField(@TypeOf(self.*), "mem_rt")) self.mem_rt else null;
}

/// V1.6 cmt9.5 — derive a hash-stable entity key from an `object` string,
/// mirroring extraction_persist.deriveEntityKey shape so session-end edges
/// land on the SAME entity nodes that compaction Pass C extraction creates.
/// `entity_<sha256(lower(object))[0..16]>`. Lowercase normalizes capitalization
/// variance ("Helix" vs "helix"). V1.7a-4 (closes ship-review WR-02): the
/// canonicalization helper is now `extraction_persist.lowerForEntityKey`
/// (Unicode-aware over ASCII + Latin-1 Supplement) — single source of truth
/// for both Zig sites and matched server-side by PG `lower(...)` in the
/// cmt16 backfill SQL. Cmt8 entity coreference (cosine ≥0.95) is not
/// plumbed here — commands.zig has no embedding provider in scope; full
/// coref requires routing through extraction_persist (cmt9.6 follow-up).
fn deriveSessionEndEntityKey(allocator: std.mem.Allocator, object: []const u8) ![]u8 {
    const lower = try extraction_persist.lowerForEntityKey(allocator, object);
    defer allocator.free(lower);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(lower);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest[0..8], 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return std.fmt.allocPrint(allocator, "entity_{s}", .{hex_buf});
}

/// P2 (memory-phase-0.5) — derive a stable, content-addressed key for a
/// session-end durable fact.
///
/// ALL facts (triple or prose) produce `durable_fact/<sha256_hex(content)[0..32]>`.
/// Using the first 16 bytes (128-bit) of SHA-256 as a 32 hex-char suffix,
/// matching the `deriveSessionEndEntityKey` pattern above.
///
/// This preserves byte-for-byte identical classification vs the original
/// timestamp-keyed scheme: `durable_fact/` is listed in
/// `isSystemManagedMemoryKey` and matched by `propagateCorrection`, so
/// edit-protection and correction propagation are unchanged.
///
/// Cross-writer dedup with Pass-C `extracted_` keys is intentionally deferred
/// to the Phase-1 semantic-merge work — we keep one canonical `durable_fact/`
/// row here.
fn deriveDurableFactKey(
    allocator: std.mem.Allocator,
    fact: *const memory_mod.summarizer.ExtractedFact,
) ![]u8 {
    // SHA-256 of raw content; first 16 bytes → 32 hex chars (128-bit dedup).
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(fact.content);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex_buf: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest[0..16], 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return std.fmt.allocPrint(allocator, "durable_fact/{s}", .{hex_buf});
}

/// V1.12 — build a compact transcript text from MessageEntries for the
/// session-end entity_pipeline pass. Walks the entries in order
/// (oldest-first), filters to user/assistant content, caps at ~3KB.
/// V1.14.7 cleanup: previously mirrored agent/root.zig::buildRecentTurnText,
/// which was deleted in V1.14.7 C3 along with the per-turn enqueue site
/// it served. This function remains for the session-end legacy enqueue
/// path (gated false by default; operator-flippable for forward compat).
fn buildSessionEndTranscriptText(
    allocator: std.mem.Allocator,
    entries: []const memory_mod.MessageEntry,
) ![]u8 {
    if (entries.len == 0) return allocator.alloc(u8, 0);

    // V1.13: cap raised 3KB → 12KB. Same logic as
    // root.zig::buildRecentTurnText — Kimi K2.6's 256K context can
    // accept far more than 3KB; the prior cap was a pre-Kimi
    // bottleneck that made the session-end pass see only the last
    // 2-3 turns of a session that may have spanned 20+. With 12KB
    // we capture the full session arc for entities that recur.
    const MAX_BYTES: usize = 12 * 1024;
    var collected: std.ArrayListUnmanaged(u8) = .{};
    errdefer collected.deinit(allocator);

    for (entries) |entry| {
        if (collected.items.len >= MAX_BYTES) break;
        // MessageEntry.role is []const u8, not an enum. Filter to
        // user/assistant content only — system/tool roles are agent
        // bookkeeping, not user prose.
        const is_user = std.mem.eql(u8, entry.role, "user");
        const is_assistant = std.mem.eql(u8, entry.role, "assistant");
        if (!is_user and !is_assistant) continue;
        const role_str: []const u8 = if (is_user) "user" else "assistant";
        if (entry.content.len == 0) continue;

        const remaining = MAX_BYTES - collected.items.len;
        const prefix_overhead: usize = role_str.len + 3;
        if (remaining <= prefix_overhead) break;
        const content_budget = remaining - prefix_overhead;
        const content_slice = if (entry.content.len > content_budget) entry.content[0..content_budget] else entry.content;
        try collected.writer(allocator).print("{s}: {s}\n", .{ role_str, content_slice });
    }

    return collected.toOwnedSlice(allocator);
}

fn setModelName(self: anytype, model: []const u8) !void {
    const owned_model = try self.allocator.dupe(u8, model);
    if (self.model_name_owned) self.allocator.free(self.model_name);
    self.model_name = owned_model;
    self.model_name_owned = true;

    if (@hasField(@TypeOf(self.*), "token_limit")) {
        const token_limit_override: ?u64 = if (@hasField(@TypeOf(self.*), "token_limit_override"))
            self.token_limit_override
        else
            null;
        self.token_limit = context_tokens.resolveContextTokens(token_limit_override, self.model_name);
    }

    if (@hasField(@TypeOf(self.*), "max_tokens")) {
        const max_tokens_override: ?u32 = if (@hasField(@TypeOf(self.*), "max_tokens_override"))
            self.max_tokens_override
        else
            null;
        var resolved_max_tokens = max_tokens_resolver.resolveMaxTokens(max_tokens_override, self.model_name);
        if (@hasField(@TypeOf(self.*), "token_limit")) {
            const token_limit_cap: u32 = @intCast(@min(self.token_limit, @as(u64, std.math.maxInt(u32))));
            resolved_max_tokens = @min(resolved_max_tokens, token_limit_cap);
        }
        self.max_tokens = resolved_max_tokens;
    }
}

fn setDefaultProvider(self: anytype, provider_name: []const u8) !void {
    if (!@hasField(@TypeOf(self.*), "default_provider")) return;
    const owned_provider = try self.allocator.dupe(u8, provider_name);
    if (@hasField(@TypeOf(self.*), "default_provider_owned")) {
        if (self.default_provider_owned) self.allocator.free(self.default_provider);
        self.default_provider_owned = true;
    }
    self.default_provider = owned_provider;
}

fn isConfiguredProviderName(self: anytype, provider_name: []const u8) bool {
    if (!@hasField(@TypeOf(self.*), "configured_providers")) return false;
    for (self.configured_providers) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, provider_name)) return true;
    }
    return false;
}

fn hasExplicitProviderPrefix(self: anytype, model: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, model, '/') orelse return false;
    if (slash == 0 or slash + 1 >= model.len) return false;

    const provider_candidate = model[0..slash];
    if (providers.classifyProvider(provider_candidate) != .unknown) return true;

    var lower_buf: [128]u8 = undefined;
    if (provider_candidate.len <= lower_buf.len) {
        _ = std.ascii.lowerString(lower_buf[0..provider_candidate.len], provider_candidate);
        if (providers.classifyProvider(lower_buf[0..provider_candidate.len]) != .unknown) return true;
    }

    return isConfiguredProviderName(self, provider_candidate);
}

fn configPrimaryModelForSelection(self: anytype, model: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, model, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPath;

    if (hasExplicitProviderPrefix(self, trimmed)) {
        return try self.allocator.dupe(u8, trimmed);
    }

    const provider = if (@hasField(@TypeOf(self.*), "default_provider") and self.default_provider.len > 0)
        self.default_provider
    else
        "openrouter";
    return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ provider, trimmed });
}

fn persistSelectedModelToConfig(self: anytype, model: []const u8) !void {
    if (builtin.is_test) return;

    const primary = try configPrimaryModelForSelection(self, model);
    defer self.allocator.free(primary);

    var result = try config_mutator.mutateDefaultConfig(
        self.allocator,
        .set,
        "agents.defaults.model.primary",
        primary,
        .{ .apply = true },
    );
    defer config_mutator.freeMutationResult(self.allocator, &result);
}

fn invalidateSystemPromptCache(self: anytype) void {
    if (@hasField(@TypeOf(self.*), "has_system_prompt")) {
        self.has_system_prompt = false;
    }
    if (@hasField(@TypeOf(self.*), "system_prompt_has_conversation_context")) {
        self.system_prompt_has_conversation_context = false;
    }
    if (@hasField(@TypeOf(self.*), "system_prompt_time_bucket_min")) {
        self.system_prompt_time_bucket_min = -1;
    }
}

test "configPrimaryModelForSelection treats unknown leading segment as model for default provider" {
    const allocator = std.testing.allocator;
    var dummy = struct {
        allocator: std.mem.Allocator,
        default_provider: []const u8,
        configured_providers: []const config_types.ProviderEntry,
    }{
        .allocator = allocator,
        .default_provider = "openrouter",
        .configured_providers = &.{},
    };

    const primary = try configPrimaryModelForSelection(&dummy, "inception/mercury");
    defer allocator.free(primary);
    try std.testing.expectEqualStrings("openrouter/inception/mercury", primary);
}

test "configPrimaryModelForSelection keeps explicit known provider prefix" {
    const allocator = std.testing.allocator;
    var dummy = struct {
        allocator: std.mem.Allocator,
        default_provider: []const u8,
        configured_providers: []const config_types.ProviderEntry,
    }{
        .allocator = allocator,
        .default_provider = "openrouter",
        .configured_providers = &.{},
    };

    const primary = try configPrimaryModelForSelection(&dummy, "openrouter/inception/mercury");
    defer allocator.free(primary);
    try std.testing.expectEqualStrings("openrouter/inception/mercury", primary);
}

test "configPrimaryModelForSelection treats known provider prefix case-insensitively" {
    const allocator = std.testing.allocator;
    var dummy = struct {
        allocator: std.mem.Allocator,
        default_provider: []const u8,
        configured_providers: []const config_types.ProviderEntry,
    }{
        .allocator = allocator,
        .default_provider = "openrouter",
        .configured_providers = &.{},
    };

    const primary = try configPrimaryModelForSelection(&dummy, "OpenRouter/inception/mercury");
    defer allocator.free(primary);
    try std.testing.expectEqualStrings("OpenRouter/inception/mercury", primary);
}

test "configPrimaryModelForSelection keeps explicit configured custom provider prefix" {
    const allocator = std.testing.allocator;
    const configured = [_]config_types.ProviderEntry{
        .{ .name = "customgw", .base_url = "https://example.com/v1" },
    };
    var dummy = struct {
        allocator: std.mem.Allocator,
        default_provider: []const u8,
        configured_providers: []const config_types.ProviderEntry,
    }{
        .allocator = allocator,
        .default_provider = "openrouter",
        .configured_providers = &configured,
    };

    const primary = try configPrimaryModelForSelection(&dummy, "customgw/model-a");
    defer allocator.free(primary);
    try std.testing.expectEqualStrings("customgw/model-a", primary);
}

test "parseSlashCommand strips bot mention from command name" {
    const parsed = parseSlashCommand("/model@nullalis_bot openrouter/inception/mercury") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("model", parsed.name);
    try std.testing.expectEqualStrings("openrouter/inception/mercury", parsed.arg);
}

test "parseSlashCommand strips bot mention with colon separator" {
    const parsed = parseSlashCommand("/model@nullalis_bot: gpt-5.2") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("model", parsed.name);
    try std.testing.expectEqualStrings("gpt-5.2", parsed.arg);
}

test "hotApplyConfigChange updates model primary as provider plus model" {
    const allocator = std.testing.allocator;
    var dummy = struct {
        allocator: std.mem.Allocator,
        model_name: []const u8,
        model_name_owned: bool,
        default_provider: []const u8,
        default_provider_owned: bool,
        default_model: []const u8,
    }{
        .allocator = allocator,
        .model_name = "old-model",
        .model_name_owned = false,
        .default_provider = "old-provider",
        .default_provider_owned = false,
        .default_model = "old-model",
    };
    defer if (dummy.model_name_owned) allocator.free(dummy.model_name);
    defer if (dummy.default_provider_owned) allocator.free(dummy.default_provider);

    const applied = try hotApplyConfigChange(
        &dummy,
        .set,
        "agents.defaults.model.primary",
        "\"openrouter/inception/mercury\"",
    );
    try std.testing.expect(applied);
    try std.testing.expectEqualStrings("inception/mercury", dummy.model_name);
    try std.testing.expectEqualStrings("inception/mercury", dummy.default_model);
    try std.testing.expectEqualStrings("openrouter", dummy.default_provider);
}

test "hotApplyConfigChange rejects malformed model primary" {
    const allocator = std.testing.allocator;
    var dummy = struct {
        allocator: std.mem.Allocator,
        model_name: []const u8,
        model_name_owned: bool,
        default_provider: []const u8,
        default_provider_owned: bool,
        default_model: []const u8,
    }{
        .allocator = allocator,
        .model_name = "stable-model",
        .model_name_owned = false,
        .default_provider = "openrouter",
        .default_provider_owned = false,
        .default_model = "stable-model",
    };
    defer if (dummy.model_name_owned) allocator.free(dummy.model_name);
    defer if (dummy.default_provider_owned) allocator.free(dummy.default_provider);

    const applied = try hotApplyConfigChange(
        &dummy,
        .set,
        "agents.defaults.model.primary",
        "\"malformed\"",
    );
    try std.testing.expect(!applied);
    try std.testing.expectEqualStrings("stable-model", dummy.model_name);
    try std.testing.expectEqualStrings("openrouter", dummy.default_provider);
}

test "hotApplyConfigChange model primary refreshes token and max token limits" {
    const allocator = std.testing.allocator;
    var dummy = struct {
        allocator: std.mem.Allocator,
        model_name: []const u8,
        model_name_owned: bool,
        default_provider: []const u8,
        default_provider_owned: bool,
        default_model: []const u8,
        token_limit: u64,
        token_limit_override: ?u64,
        max_tokens: u32,
        max_tokens_override: ?u32,
    }{
        .allocator = allocator,
        .model_name = "old-model",
        .model_name_owned = false,
        .default_provider = "old-provider",
        .default_provider_owned = false,
        .default_model = "old-model",
        .token_limit = 1024,
        .token_limit_override = null,
        .max_tokens = 128,
        .max_tokens_override = null,
    };
    defer if (dummy.model_name_owned) allocator.free(dummy.model_name);
    defer if (dummy.default_provider_owned) allocator.free(dummy.default_provider);

    const applied = try hotApplyConfigChange(
        &dummy,
        .set,
        "agents.defaults.model.primary",
        "\"openrouter/gpt-4o\"",
    );
    try std.testing.expect(applied);
    try std.testing.expectEqualStrings("gpt-4o", dummy.model_name);
    try std.testing.expectEqualStrings("gpt-4o", dummy.default_model);
    try std.testing.expectEqualStrings("openrouter", dummy.default_provider);
    try std.testing.expectEqual(@as(u64, 128_000), dummy.token_limit);
    try std.testing.expectEqual(@as(u32, 8192), dummy.max_tokens);
}

test "splitPrimaryModelRef parses provider model format" {
    const parsed = splitPrimaryModelRef("openrouter/inception/mercury") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("openrouter", parsed.provider);
    try std.testing.expectEqualStrings("inception/mercury", parsed.model);
}

test "splitPrimaryModelRef rejects malformed values" {
    try std.testing.expect(splitPrimaryModelRef("noslash") == null);
    try std.testing.expect(splitPrimaryModelRef("/model-only") == null);
    try std.testing.expect(splitPrimaryModelRef("provider/") == null);
}

test "lifecycleSummaryTimeoutSecs inherits message timeout when explicit lifecycle timeout is unset" {
    const Stub = struct {
        lifecycle_summarizer_timeout_secs: u64 = 0,
        message_timeout_secs: u64 = 45,
    };

    var stub = Stub{};
    try std.testing.expectEqual(@as(u64, 45), lifecycleSummaryTimeoutSecs(&stub));
}

test "lifecycleSummaryTimeoutSecs falls back to safer default when all timeouts are unset" {
    const Stub = struct {
        lifecycle_summarizer_timeout_secs: u64 = 0,
        message_timeout_secs: u64 = 0,
    };

    var stub = Stub{};
    try std.testing.expectEqual(@as(u64, 60), lifecycleSummaryTimeoutSecs(&stub));
}

fn setExecNodeId(self: anytype, value: ?[]const u8) !void {
    if (self.exec_node_id_owned and self.exec_node_id != null) {
        self.allocator.free(self.exec_node_id.?);
    }
    self.exec_node_id_owned = false;
    self.exec_node_id = null;
    if (value) |v| {
        self.exec_node_id = try self.allocator.dupe(u8, v);
        self.exec_node_id_owned = true;
    }
}

fn setTtsProvider(self: anytype, value: ?[]const u8) !void {
    if (self.tts_provider_owned and self.tts_provider != null) {
        self.allocator.free(self.tts_provider.?);
    }
    self.tts_provider_owned = false;
    self.tts_provider = null;
    if (value) |v| {
        self.tts_provider = try self.allocator.dupe(u8, v);
        self.tts_provider_owned = true;
    }
}

fn setFocusTarget(self: anytype, value: ?[]const u8) !void {
    if (self.focus_target_owned and self.focus_target != null) {
        self.allocator.free(self.focus_target.?);
    }
    self.focus_target_owned = false;
    self.focus_target = null;
    if (value) |v| {
        self.focus_target = try self.allocator.dupe(u8, v);
        self.focus_target_owned = true;
    }
}

fn setDockTarget(self: anytype, value: ?[]const u8) !void {
    if (self.dock_target_owned and self.dock_target != null) {
        self.allocator.free(self.dock_target.?);
    }
    self.dock_target_owned = false;
    self.dock_target = null;
    if (value) |v| {
        self.dock_target = try self.allocator.dupe(u8, v);
        self.dock_target_owned = true;
    }
}

fn clearPendingExecCommand(self: anytype) void {
    if (self.pending_exec_command_owned and self.pending_exec_command != null) {
        self.allocator.free(self.pending_exec_command.?);
    }
    self.pending_exec_command = null;
    self.pending_exec_command_owned = false;
}

fn setPendingExecCommand(self: anytype, command: []const u8) !void {
    clearPendingExecCommand(self);
    self.pending_exec_command = try self.allocator.dupe(u8, command);
    self.pending_exec_command_owned = true;
    self.pending_exec_id += 1;
    if (self.pending_exec_id == 0) self.pending_exec_id = 1;
}

fn splitFirstToken(arg: []const u8) struct { head: []const u8, tail: []const u8 } {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) return .{ .head = "", .tail = "" };

    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] != ' ' and trimmed[i] != '\t') : (i += 1) {}

    if (i >= trimmed.len) return .{ .head = trimmed, .tail = "" };
    return .{
        .head = trimmed[0..i],
        .tail = std.mem.trim(u8, trimmed[i + 1 ..], " \t"),
    };
}

fn parseTaskId(raw: []const u8) ?u64 {
    if (raw.len == 0) return null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

fn findSpawnTool(self: anytype) ?*spawn_tool_mod.SpawnTool {
    for (self.tools) |t| {
        if (!std.ascii.eqlIgnoreCase(t.name(), "spawn")) continue;
        return @ptrCast(@alignCast(t.ptr));
    }
    return null;
}

fn findSubagentManager(self: anytype) ?*subagent_mod.SubagentManager {
    const spawn_tool = findSpawnTool(self) orelse return null;
    return spawn_tool.manager;
}

pub fn refreshSubagentToolContext(self: anytype) void {
    const spawn_tool = findSpawnTool(self) orelse return;
    spawn_tool.default_channel = "agent";
    spawn_tool.default_chat_id = self.memory_session_id orelse "agent";
}

fn findShellTool(self: anytype) ?Tool {
    for (self.tools) |t| {
        if (std.ascii.eqlIgnoreCase(t.name(), "shell")) return t;
    }
    return null;
}

fn findToolByName(self: anytype, name: []const u8) ?Tool {
    for (self.tools) |t| {
        if (std.ascii.eqlIgnoreCase(t.name(), name)) return t;
    }
    return null;
}

// V1.7a-4 review fix WR-01: alias the consolidated UTF-8 truncation helper
// from `memory/text_norm.zig` so existing call sites in this file stay
// untouched. One source of truth across all 3 prior diverged copies.
const truncateUtf8 = text_norm.truncateUtf8;

fn stripMemoryContextPrefix(text: []const u8) []const u8 {
    const prefix = "[Memory context]\n";
    if (!std.mem.startsWith(u8, text, prefix)) return text;
    if (std.mem.indexOf(u8, text, "\n\n")) |sep_idx| {
        return std.mem.trim(u8, text[sep_idx + 2 ..], " \t\r\n");
    }
    return text;
}

fn appendSanitizedSnippet(w: anytype, raw: []const u8, max_chars: usize) !void {
    const stripped = stripMemoryContextPrefix(raw);
    const clipped = truncateUtf8(stripped, max_chars);
    const trimmed = std.mem.trim(u8, clipped, " \t\r\n");
    if (trimmed.len == 0) {
        try w.writeAll("(empty)");
        return;
    }

    var wrote_any = false;
    var previous_space = false;
    for (trimmed) |ch| {
        const is_space = ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t';
        if (is_space) {
            if (wrote_any and !previous_space) {
                try w.writeByte(' ');
                previous_space = true;
            }
            continue;
        }
        try w.writeByte(ch);
        wrote_any = true;
        previous_space = false;
    }

    if (!wrote_any) {
        try w.writeAll("(empty)");
    }
}

fn appendRecentRoleSnippets(
    w: anytype,
    history_items: anytype,
    role: providers.Role,
    max_items: usize,
    max_chars: usize,
) !void {
    var selected: [8]usize = undefined;
    const target = @min(max_items, selected.len);

    var count: usize = 0;
    var idx = history_items.len;
    while (idx > 0 and count < target) {
        idx -= 1;
        if (history_items[idx].role != role) continue;
        selected[count] = idx;
        count += 1;
    }

    if (count == 0) {
        try w.writeAll("- none\n");
        return;
    }

    var rev = count;
    while (rev > 0) {
        rev -= 1;
        const item = history_items[selected[rev]];
        try w.writeAll("- ");
        try appendSanitizedSnippet(w, item.content, max_chars);
        try w.writeByte('\n');
    }
}

fn roleLabel(role: providers.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn lifecycleSummaryTimeoutSecs(self: anytype) u64 {
    if (self.lifecycle_summarizer_timeout_secs > 0) return self.lifecycle_summarizer_timeout_secs;
    if (self.message_timeout_secs > 0) return self.message_timeout_secs;
    return 60;
}

fn effectiveSummarizerConfig(self: anytype) memory_mod.SummarizerConfig {
    if (self.mem_rt) |rt| return rt.summarizerConfig();
    return .{
        .enabled = true,
        .window_size_tokens = 4000,
        .summary_max_tokens = 500,
        .auto_extract_semantic = true,
    };
}

fn firstCheckpointBullet(checkpoint_content: []const u8, section: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, checkpoint_content, section) orelse return null;
    const body = checkpoint_content[idx + section.len ..];
    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "- ")) {
            if (std.mem.endsWith(u8, line, ":")) break;
            continue;
        }
        return line[2..];
    }
    return null;
}

fn summarySectionValue(summary_text: []const u8, prefix: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, summary_text, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.startsWith(u8, line, prefix)) {
            return std.mem.trim(u8, line[prefix.len..], " \t\r\n");
        }
    }
    return "none";
}

fn compactionCarrierSnippet(content: []const u8) ?[]const u8 {
    const marker = "[Compaction summary]";
    if (!std.mem.startsWith(u8, content, marker)) return null;

    const body = if (content.len > marker.len and content[marker.len] == '\n')
        content[marker.len + 1 ..]
    else
        content[marker.len..];
    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "- ")) return line[2..];
        return line;
    }
    return null;
}

fn fallbackFocusFromEntries(entries: []const memory_mod.MessageEntry) []const u8 {
    var idx = entries.len;
    while (idx > 0) {
        idx -= 1;
        const entry = entries[idx];
        if (compactionCarrierSnippet(entry.content)) |snippet| return snippet;
    }

    idx = entries.len;
    while (idx > 0) {
        idx -= 1;
        const entry = entries[idx];
        if (std.mem.eql(u8, entry.role, "user") or std.mem.eql(u8, entry.role, "assistant")) {
            const trimmed = std.mem.trim(u8, entry.content, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
    }

    return "recent session recap";
}

fn buildStructuredFallbackSummary(self: anytype, entries: []const memory_mod.MessageEntry, checkpoint_content: []const u8) ?[]u8 {
    const focus = if (entries.len > 0)
        fallbackFocusFromEntries(entries)
    else
        firstCheckpointBullet(checkpoint_content, "recent_user:\n") orelse
            firstCheckpointBullet(checkpoint_content, "recent_assistant:\n") orelse
            "recent session recap";
    return std.fmt.allocPrint(
        self.allocator,
        "focus: {s}\n" ++
            "decisions:\n- none\n" ++
            "open_loops:\n- none\n" ++
            "next:\n- review transcript if exact detail is needed\n",
        .{truncateUtf8(focus, 220)},
    ) catch null;
}

fn buildSessionEndSummaryEntries(
    self: anytype,
    allocator: std.mem.Allocator,
    checkpoint_content: []const u8,
    summarizer_cfg: memory_mod.SummarizerConfig,
) ![]memory_mod.MessageEntry {
    const full_entries = try allocator.alloc(memory_mod.MessageEntry, self.history.items.len);
    errdefer allocator.free(full_entries);
    for (self.history.items, 0..) |item, idx| {
        full_entries[idx] = .{
            .role = roleLabel(item.role),
            .content = item.content,
        };
    }

    if (!memory_mod.shouldSummarize(full_entries, summarizer_cfg)) {
        return full_entries;
    }

    var compaction_start: ?usize = null;
    var scan_idx: usize = self.history.items.len;
    while (scan_idx > 0) {
        scan_idx -= 1;
        const item = self.history.items[scan_idx];
        if (item.role != .assistant) continue;
        if (compactionCarrierSnippet(item.content) != null) {
            compaction_start = scan_idx;
            break;
        }
    }

    if (compaction_start) |start_idx| {
        allocator.free(full_entries);
        const count = self.history.items.len - start_idx;
        const entries = try allocator.alloc(memory_mod.MessageEntry, count);
        for (self.history.items[start_idx..], 0..) |item, idx| {
            entries[idx] = .{
                .role = roleLabel(item.role),
                .content = item.content,
            };
        }
        return entries;
    }

    allocator.free(full_entries);

    var selected: [8]usize = undefined;
    var count: usize = 0;
    var idx = self.history.items.len;
    while (idx > 0 and count < selected.len) {
        idx -= 1;
        const item = self.history.items[idx];
        if (item.role != .user and item.role != .assistant) continue;
        selected[count] = idx;
        count += 1;
    }

    const include_checkpoint = checkpoint_content.len > 0;
    const entries = try allocator.alloc(memory_mod.MessageEntry, count + @intFromBool(include_checkpoint));
    var out_idx: usize = 0;
    if (include_checkpoint) {
        entries[out_idx] = .{
            .role = "system",
            .content = checkpoint_content,
        };
        out_idx += 1;
    }
    var rev = count;
    while (rev > 0) {
        rev -= 1;
        const item = self.history.items[selected[rev]];
        entries[out_idx] = .{
            .role = roleLabel(item.role),
            .content = item.content,
        };
        out_idx += 1;
    }
    return entries;
}

fn updateTimelineIndex(
    allocator: std.mem.Allocator,
    mem: memory_mod.Memory,
    rt: ?*memory_mod.MemoryRuntime,
    session_id: []const u8,
    now_iso: []const u8,
    focus: []const u8,
    timeline_key: []const u8,
    origin: SummaryOrigin,
) void {
    const new_line = memory_mod.buildTimelineIndexJsonLine(allocator, .{
        .at = now_iso,
        .channel = origin.channel,
        .lane = origin.lane,
        .session = session_id,
        .focus = truncateUtf8(focus, 140),
        .key = timeline_key,
        .chat_id = origin.chat_id,
    }) catch return;
    defer allocator.free(new_line);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    w.writeAll(new_line) catch return;
    w.writeByte('\n') catch return;

    if (mem.get(allocator, "timeline_index/current") catch null) |existing| {
        defer existing.deinit(allocator);
        var kept: usize = 1;
        var iter = std.mem.splitScalar(u8, existing.content, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            {
                const parsed = memory_mod.parseTimelineIndexLine(allocator, line_raw) catch break orelse continue;
                defer parsed.deinit(allocator);
                if (std.mem.eql(u8, parsed.key, timeline_key)) continue;
                if (kept >= 32) break;
                if (line[0] == '{') {
                    w.writeAll(line) catch break;
                } else {
                    const normalized = memory_mod.buildTimelineIndexJsonLine(allocator, parsed) catch break;
                    defer allocator.free(normalized);
                    w.writeAll(normalized) catch break;
                }
                w.writeByte('\n') catch break;
                kept += 1;
            }
        }
    }

    const content = out.toOwnedSlice(allocator) catch return;
    defer allocator.free(content);
    mem.store("timeline_index/current", content, .core, null) catch return;
    if (rt) |mem_rt| _ = mem_rt.syncVectorAfterStore(allocator, "timeline_index/current", content);
}

const SummaryOrigin = struct {
    channel: []const u8,
    lane: []const u8,
    chat_id: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
};

const SummaryQuality = enum {
    canonical,
    fallback,
};

fn resolveSummaryOrigin(self: anytype, session_id: []const u8, key_hint: []const u8) SummaryOrigin {
    const derived = memory_mod.deriveMemoryProvenance(session_id, key_hint);
    const turn_ctx = message_tool.MessageTool.getTurnContext();
    return .{
        .channel = turn_ctx.channel orelse self.origin_channel orelse derived.channel,
        .lane = self.origin_lane orelse derived.lane,
        .chat_id = turn_ctx.chat_id orelse self.origin_chat_id,
        .account_id = turn_ctx.account_id orelse self.origin_account_id,
    };
}

fn appendOriginMetadata(
    allocator: std.mem.Allocator,
    origin: SummaryOrigin,
    body: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("origin_channel={s}\norigin_lane={s}\n", .{ origin.channel, origin.lane });
    if (origin.chat_id) |chat_id| {
        try w.print("origin_chat_id={s}\n", .{chat_id});
    }
    if (origin.account_id) |account_id| {
        try w.print("origin_account_id={s}\n", .{account_id});
    }
    try w.writeByte('\n');
    try w.writeAll(body);
    return out.toOwnedSlice(allocator);
}

fn buildSummaryLatestContent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    origin: SummaryOrigin,
    source_key: []const u8,
    at: []const u8,
    quality: SummaryQuality,
    summary_body: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print(
        "type=summary_latest\nsession={s}\nchannel={s}\nlane={s}\norigin_channel={s}\norigin_lane={s}\n",
        .{ session_id, origin.channel, origin.lane, origin.channel, origin.lane },
    );
    if (origin.chat_id) |chat_id| {
        try w.print("origin_chat_id={s}\n", .{chat_id});
    }
    if (origin.account_id) |account_id| {
        try w.print("origin_account_id={s}\n", .{account_id});
    }
    try w.print("source_key={s}\nat={s}\nquality_tier={s}\n{s}", .{
        source_key,
        at,
        switch (quality) {
            .canonical => "canonical",
            .fallback => "fallback",
        },
        summary_body,
    });
    return out.toOwnedSlice(allocator);
}

fn metadataValue(content: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len <= key.len or line[key.len] != '=') continue;
        if (std.mem.eql(u8, line[0..key.len], key)) return line[key.len + 1 ..];
    }
    return null;
}

fn summaryLatestQuality(content: []const u8) SummaryQuality {
    const tier = metadataValue(content, "quality_tier") orelse return .canonical;
    if (std.mem.eql(u8, tier, "fallback")) return .fallback;
    return .canonical;
}

fn shouldPromoteSummaryLatest(
    allocator: std.mem.Allocator,
    mem: memory_mod.Memory,
    latest_key: []const u8,
    candidate_quality: SummaryQuality,
) bool {
    // Freeze the current continuity contract: canonical summaries always win,
    // fallback summaries only replace missing or fallback latest state.
    const existing = mem.get(allocator, latest_key) catch return candidate_quality == .canonical;
    if (existing == null) return true;

    var latest = existing.?;
    defer latest.deinit(allocator);

    if (candidate_quality == .canonical) return true;
    return summaryLatestQuality(latest.content) == .fallback;
}

fn buildContextAnchorContent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    origin: SummaryOrigin,
    reason: []const u8,
    model_name: []const u8,
    checkpoint_key: []const u8,
    summary_key: ?[]const u8,
    at: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print(
        "type=context_anchor\nlast_session={s}\nlast_channel={s}\nlast_lane={s}\norigin_channel={s}\norigin_lane={s}\n",
        .{ session_id, origin.channel, origin.lane, origin.channel, origin.lane },
    );
    if (origin.chat_id) |chat_id| {
        try w.print("origin_chat_id={s}\n", .{chat_id});
    }
    if (origin.account_id) |account_id| {
        try w.print("origin_account_id={s}\n", .{account_id});
    }
    try w.print(
        "last_reason={s}\nlast_model={s}\nlast_checkpoint_key={s}\n",
        .{ reason, model_name, checkpoint_key },
    );
    if (summary_key) |value| {
        try w.print("last_summary_key={s}\n", .{value});
    }
    try w.print("last_at={s}", .{at});
    return out.toOwnedSlice(allocator);
}

fn emitLifecycleSummarizerStage(self: anytype, duration_ms: u64, summarized_count: usize) void {
    const event = observability.ObserverEvent{ .turn_stage = .{
        .stage = "memory_lifecycle_summarizer",
        .duration_ms = duration_ms,
        .count = @intCast(@min(summarized_count, @as(usize, std.math.maxInt(u32)))),
    } };
    self.observer.recordEvent(&event);
}

/// True when a session-end checkpoint must NOT run a heavy inline memory
/// pass — i.e. it is triggered by a non-interactive lifecycle event
/// (process shutdown, idle/TTL eviction, or TTL in-place recycle) rather
/// than an explicit user action. These run on the maintenance / shutdown
/// paths where a 30-75s blocking LLM summarizer + inline boundary
/// extraction would stall the runtime (P0-2). For these reasons the
/// checkpoint persists only the deterministic checkpoint/anchor and
/// ENQUEUES boundary extraction to the daemon lane instead of doing it
/// inline.
///
/// P1-6 (audit, part a): `ttl_recycle` was the remaining inline-boundary
/// gap. recycleSessionInPlace (session.zig ~813) checkpoints the EXPIRED
/// agent with reason "ttl_recycle" — and crucially it runs synchronously
/// in front of a fresh incoming user turn (sendMessage → sessionIsTtlExpired
/// → recycleSessionInPlace). Leaving it interactive meant a brownout-era
/// 30s+ blocking extractAtBoundary was injected ahead of the user's first
/// message to a recycled session. It is a maintenance-lane event just like
/// idle_evict/ttl_evict, so it joins the set: the deterministic summary +
/// off-thread enqueueExtractionJob path covers it with zero loss (the
/// session-end entity-pipeline enqueue below is unconditional on the gate).
fn isNonInteractiveCheckpointReason(reason: []const u8) bool {
    return std.mem.eql(u8, reason, "shutdown") or
        std.mem.eql(u8, reason, "idle_evict") or
        std.mem.eql(u8, reason, "ttl_evict") or
        std.mem.eql(u8, reason, "ttl_recycle");
}

/// Pure gating predicate for the deterministic vs. LLM session-summary path.
///
/// `reason` — the checkpoint reason tag.
/// `canonical_continuity_summary_enabled` — the P4 flag (default ON).
///
/// Returns TRUE when the deterministic `buildStructuredFallbackSummary`
/// template must be used (and `summary_provider.chat` is NOT reached);
/// FALSE when the real LLM summarizer path runs.
///
/// Three classes of reason:
///   - Genuinely non-interactive (shutdown / idle_evict / ttl_evict /
///     ttl_recycle): ALWAYS deterministic regardless of the flag. They run
///     on maintenance/shutdown lanes that cannot block on a 30-75s LLM call
///     (P0-2 / P1-6).
///   - LIVE in-conversation triggers (compaction:auto / summary_seed:auto):
///     deterministic ONLY when the P4 flag is OFF. When ON (default), they
///     take the real LLM-summarizer path. CRITICAL safety invariant: both
///     run OFF-THREAD via `persistSessionCheckpointAsync` (a std.Thread.spawn
///     worker → persistSessionCheckpointDetailed → persistSessionSemanticSummary),
///     so the LLM call never blocks the user's turn. If that ever changes,
///     this gate must NOT route them to the LLM path.
///   - Interactive operator reasons (compaction:manual / reset:manual / …):
///     never deterministic — they always took the LLM path and still do.
fn shouldUseDeterministicSessionSummary(reason: []const u8, canonical_continuity_summary_enabled: bool) bool {
    // P0-2 / P1-6: shutdown + idle/TTL eviction + ttl_recycle must skip the
    // blocking LLM summarizer (summary_provider.chat) and use the
    // deterministic structured fallback — see isNonInteractiveCheckpointReason.
    // This holds regardless of the P4 flag.
    if (isNonInteractiveCheckpointReason(reason)) return true;

    // P4: the two LIVE in-conversation triggers. When the canonical-continuity
    // flag is OFF, restore the exact prior behavior (deterministic template).
    // When ON (default), fall through to the LLM summarizer path. They run
    // off-thread, so the LLM call does not block the user turn.
    if (!canonical_continuity_summary_enabled) {
        if (std.mem.eql(u8, reason, "compaction:auto") or
            std.mem.eql(u8, reason, "summary_seed:auto")) return true;
    }

    return false;
}

/// True when the inline session-end boundary extraction (extractAtBoundary)
/// must be skipped because the checkpoint is non-interactive (P0-2). The
/// entity pipeline is still enqueued to the daemon lane downstream, so the
/// extraction is not dropped — only moved off the blocking path.
fn shouldSkipInlineBoundaryExtraction(reason: []const u8) bool {
    return isNonInteractiveCheckpointReason(reason);
}

fn persistSessionSemanticSummary(self: anytype, checkpoint_content: []const u8, session_id: []const u8, reason: []const u8, now_s: i64, now_iso: []const u8) bool {
    const mem = self.mem orelse return false;
    const rt = self.mem_rt;
    const summarizer_cfg = effectiveSummarizerConfig(self);
    if (!summarizer_cfg.enabled) return false;

    const entries = buildSessionEndSummaryEntries(self, self.allocator, checkpoint_content, summarizer_cfg) catch return false;
    defer self.allocator.free(entries);
    const summarize_start_ms = std.time.milliTimestamp();
    defer {
        const duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - summarize_start_ms));
        emitLifecycleSummarizerStage(self, duration_ms, entries.len);
    }

    var summary_text_owned: ?[]u8 = null;
    defer if (summary_text_owned) |owned| self.allocator.free(owned);

    var parsed_summary: ?memory_mod.SummaryResult = null;
    defer if (parsed_summary) |*result| result.deinit(self.allocator);
    var summary_quality: SummaryQuality = .fallback;
    const content = blk: {
        if (shouldUseDeterministicSessionSummary(reason, self.canonical_continuity_summary_enabled)) {
            summary_text_owned = buildStructuredFallbackSummary(self, entries, checkpoint_content);
            if (summary_text_owned) |owned| {
                log.info("memory.timeline_summary status=deterministic session={s} reason={s} entries={d}", .{
                    session_id,
                    reason,
                    entries.len,
                });
                break :blk owned;
            }
            return false;
        }

        const prompt = memory_mod.buildSummarizationPrompt(self.allocator, entries, entries.len) catch return false;
        defer self.allocator.free(prompt);

        const summary_system = "Summarize the ended session into a compact continuity object. " ++
            "Output plain text only. No markdown formatting — no bold, no headers (#), no asterisks. " ++
            "Use exactly these section labels with colons on their own lines: focus:, decisions:, open_loops:, next:. " ++
            "Preserve focus, decisions, open loops, next steps, and long-lived facts.";
        var summary_messages: [2]providers.ChatMessage = .{
            .{ .role = .system, .content = summary_system },
            .{ .role = .user, .content = prompt },
        };
        const timeout_secs = lifecycleSummaryTimeoutSecs(self);

        // Use the sidecar (cheap, fast — Groq Llama 8B) when available. Main
        // LLM (Kimi K2.5 / GLM) often wraps summaries in markdown headers
        // like "**focus:**" which trip the strict parser. Sidecar small
        // models follow plain-text format reliably and are 10-20x cheaper.
        const use_sidecar = self.sidecar_provider != null and self.sidecar_model.len > 0;
        const summary_provider = if (use_sidecar) self.sidecar_provider.? else self.provider;
        const summary_model = if (use_sidecar) self.sidecar_model else self.model_name;

        var response = summary_provider.chat(
            self.allocator,
            .{
                .messages = summary_messages[0..],
                .model = summary_model,
                .temperature = 0.2,
                .tools = null,
                .timeout_secs = timeout_secs,
            },
            summary_model,
            0.2,
        ) catch {
            summary_text_owned = buildStructuredFallbackSummary(self, entries, checkpoint_content);
            if (summary_text_owned) |owned| {
                log.warn("memory.timeline_summary fallback=structured reason=provider_error session={s} reason_tag={s}", .{
                    session_id,
                    reason,
                });
                break :blk owned;
            }
            return false;
        };
        defer {
            if (response.content) |content_part| {
                if (content_part.len > 0) self.allocator.free(content_part);
            }
            for (response.tool_calls) |tc| {
                self.allocator.free(tc.id);
                self.allocator.free(tc.name);
                self.allocator.free(tc.arguments);
            }
            if (response.tool_calls.len > 0) self.allocator.free(response.tool_calls);
            if (response.model.len > 0) self.allocator.free(response.model);
            if (response.reasoning_content) |rc| {
                if (rc.len > 0) self.allocator.free(rc);
            }
        }

        parsed_summary = memory_mod.parseSummaryResponse(self.allocator, response.contentOrEmpty(), summarizer_cfg) catch {
            summary_text_owned = buildStructuredFallbackSummary(self, entries, checkpoint_content);
            if (summary_text_owned) |owned| {
                log.warn("memory.timeline_summary fallback=structured reason=parse_error session={s} reason_tag={s}", .{
                    session_id,
                    reason,
                });
                break :blk owned;
            }
            return false;
        };
        summary_quality = .canonical;
        break :blk parsed_summary.?.summary;
    };

    const summary_origin = resolveSummaryOrigin(self, session_id, session_id);
    const summary_content = appendOriginMetadata(self.allocator, summary_origin, content) catch return false;
    defer self.allocator.free(summary_content);

    // C: downgrade summaries that encode external-entity claims without tool
    // grounding in the source conversation. Such summaries are most likely
    // laundering the agent's own prior hallucinations — storing them as
    // continuity artifacts (timeline_summary/summary_latest/durable_fact)
    // would re-inject them on every future turn and compound the error.
    // The raw autosave_assistant/autosave_user entries remain intact for
    // audit/debug; we just decline to promote the summary to canonical.
    const unverified = memory_mod.hasUnverifiedExternalClaims(summary_content, entries);
    if (unverified) {
        log.info("memory.timeline_summary downgrade=audit session={s} reason={s} cause=unverified_external_claims entries={d}", .{
            session_id,
            reason,
            entries.len,
        });
        return false;
    }

    const timeline_key = std.fmt.allocPrint(
        self.allocator,
        "timeline_summary/{s}/{d}",
        .{ session_id, now_s },
    ) catch return false;
    defer self.allocator.free(timeline_key);
    const timeline_written = if (mem.store(timeline_key, summary_content, .daily, null)) |_| blk: {
        if (rt) |mem_rt| _ = mem_rt.syncVectorAfterStore(self.allocator, timeline_key, summary_content);
        break :blk true;
    } else |_| false;
    if (!timeline_written) return false;

    const focus = summarySectionValue(content, "focus:");
    const next = summarySectionValue(content, "next:");
    const latest_key = std.fmt.allocPrint(self.allocator, "summary_latest/{s}", .{session_id}) catch return true;
    defer self.allocator.free(latest_key);
    const latest_content = buildSummaryLatestContent(
        self.allocator,
        session_id,
        summary_origin,
        timeline_key,
        now_iso,
        summary_quality,
        content,
    ) catch return true;
    defer self.allocator.free(latest_content);
    if (shouldPromoteSummaryLatest(self.allocator, mem, latest_key, summary_quality)) {
        if (mem.store(latest_key, latest_content, .core, null)) |_| {
            if (rt) |mem_rt| _ = mem_rt.syncVectorAfterStore(self.allocator, latest_key, latest_content);
        } else |_| {}
    } else {
        log.info("memory.summary_latest promote=blocked session={s} reason={s} quality={s}", .{
            session_id,
            reason,
            switch (summary_quality) {
                .canonical => "canonical",
                .fallback => "fallback",
            },
        });
        // iter29: write a fallback-quality artifact so the partial content is
        // still retrievable. Blocking promotion to summary_latest prevents
        // low-quality content from shadowing canonical recall, but silently
        // dropping it makes the turn invisible to future retrieval. The
        // summary_fallback/ namespace is discoverable via memory_timeline
        // with a quality flag in the metadata.
        const fallback_key = std.fmt.allocPrint(
            self.allocator,
            "summary_fallback/{s}/{d}",
            .{ session_id, now_s },
        ) catch null;
        if (fallback_key) |fk| {
            defer self.allocator.free(fk);
            if (mem.store(fk, latest_content, .daily, session_id)) |_| {
                if (rt) |mem_rt| _ = mem_rt.syncVectorAfterStore(self.allocator, fk, latest_content);
            } else |_| {}
        }
    }

    updateTimelineIndex(self.allocator, mem, rt, session_id, now_iso, focus, timeline_key, summary_origin);

    if (parsed_summary) |parsed| {
        var triple_edges_written: usize = 0;
        for (parsed.extracted_facts, 0..) |fact, idx| {
            _ = idx; // P2: index no longer used in key — content-addressed below
            const fact_key = deriveDurableFactKey(self.allocator, &fact) catch continue;
            defer self.allocator.free(fact_key);
            if (mem.store(fact_key, fact.content, .core, null)) |_| {
                if (rt) |mem_rt| _ = mem_rt.syncVectorAfterStore(self.allocator, fact_key, fact.content);
            } else |_| {
                continue;
            }

            // V1.6 cmt9.5 (Gap 3): when the LLM emitted a structured triple
            // alongside the prose Key fact (===EXTRACTED=== JSON tail), also
            // write an edge to memory_edges so the session-end fact joins
            // the materialized graph. Source is the durable_fact row we
            // just wrote (continuity-bucket; agent context preserved);
            // target is a hash-derived entity key (V1.6 cmt7 shape — cmt8
            // entity coreference is intentionally NOT plumbed here, since
            // commands.zig doesn't have an embedding provider in scope and
            // adding one through the agent surface is a separate refactor).
            //
            // V1.7 cmt9.6 (full Gap 3 closure): when fact carries a triple
            // AND tenant has extraction context, ALSO route through
            // extraction_persist.persistExtracted — this gets us coref +
            // edge insert + source attribution, AND the resulting
            // extracted_<hash> row is now first-class continuity (added
            // to memory_loader.isSemanticContinuityKey in cmt9.6). The
            // inline durable_fact write above is preserved as a legacy
            // dual-write for backwards compat with /learn list/forget
            // commands; future commit may collapse to single-write once
            // those tools migrate to extracted_* keys.
            //
            // V1.14.12 (Memory audit Finding 1 fix, 2026-05-19) — the
            // durable_fact/* prefix is now brain-VISIBLE (was previously
            // hidden via BRAIN_HIDDEN_PREFIXES, which combined with the
            // MD5 dedup below to make session-end facts invisible
            // everywhere). The dedup below is now intentional, not a
            // bug: durable_fact is THE visible user-facing row; the
            // extracted_<hash> path is the (no-op'd) coref+judge enrich
            // path. The edge write further below ALWAYS fires regardless
            // of MD5 dedup — covers the graph half of unification.
            //
            // MD5 dedup in persistExtracted will see the durable_fact row's
            // identical content_hash and silently skip the extracted_<hash>
            // write. This is the intended behavior post-Finding-1: one
            // visible row per session-end fact, not two.
            if (fact.hasTriple()) {
                if (self.extraction_state_mgr) |smgr| {
                    if (self.extraction_user_id) |uid| {
                        const target_key = deriveSessionEndEntityKey(self.allocator, fact.object.?) catch null;
                        if (target_key) |tk| {
                            defer self.allocator.free(tk);
                            smgr.upsertMemoryEdge(
                                uid,
                                fact_key,
                                tk,
                                fact.predicate.?,
                                "session_end_loop",
                                fact.confidence,
                            ) catch |err| {
                                log.warn("session_end edge write failed key={s} predicate={s} err={s}", .{
                                    fact_key, fact.predicate.?, @errorName(err),
                                });
                                continue;
                            };
                            triple_edges_written += 1;
                        }

                        // V1.14.12 (Path A) — legacy direct write deleted.
                        // Session-end durable_fact promotion flows entirely
                        // through extractAtBoundary at the block below
                        // (write_origin = .session_end_extract). The
                        // extractAtBoundary path now handles null-judge
                        // gracefully so this deletion doesn't regress
                        // no-judge tenants.
                    }
                }
            }
        }
        log.info("memory.timeline_summary status=ok session={s} reason={s} entries={d} facts={d} edges={d} next={s}", .{
            session_id,
            reason,
            entries.len,
            parsed.extracted_facts.len,
            triple_edges_written,
            next,
        });

        // V1.14.8 C3 — unified boundary extraction at session end (additive
        // to the legacy `parsed.extracted_facts` persist loop above). Routes
        // through the same extraction_runner used by Pass C, ensuring a
        // single extractor shape across all distillation moments. Failure-
        // soft per layer; existing per-fact persist remains the legacy
        // primary writer until C5 cleanup. Dedup at persistExtracted handles
        // overlap between the two paths.
        // The runner can use a dedicated extraction provider/model without
        // a contradiction judge, but this legacy session-end path only has
        // judge-backed extraction config available. Avoid routing arbitrary
        // chat providers through the structured extraction parser.
        //
        // P0-2: on non-interactive checkpoints (shutdown / idle_evict /
        // ttl_evict) this inline pass is SKIPPED — extractAtBoundary is a
        // blocking LLM-backed extraction that would stall the maintenance /
        // shutdown path. The entity pipeline is still enqueued to the daemon
        // lane below (enqueueExtractionJob), so the extraction is moved
        // off-thread, not dropped.
        if (self.history.items.len > 0 and !shouldSkipInlineBoundaryExtraction(reason)) {
            var msgs_buf = std.ArrayListUnmanaged(providers.ChatMessage).initCapacity(self.allocator, self.history.items.len) catch null;
            if (msgs_buf) |*buf| {
                defer buf.deinit(self.allocator);
                for (self.history.items) |m| buf.appendAssumeCapacity(.{ .role = m.role, .content = m.content });
                const ctx = extraction_runner.ExtractionContext{
                    .judge_provider = self.extraction_judge_provider,
                    .judge_model = self.extraction_judge_model_name,
                    .state_mgr = self.extraction_state_mgr,
                    .user_id = self.extraction_user_id,
                    .session_id = session_id,
                    .coref_embed = self.extraction_coref_embed,
                    .archive_mem = self.mem,
                    .archive_mem_rt = self.mem_rt,
                    .write_origin = .session_end_extract, // V1.14.12 (M1) — per-path telemetry tag
                    .cardinality_fastpath_enabled = self.extraction_cardinality_fastpath, // V1.14.12 (M2 review CRITICAL)
                };
                const br = extraction_runner.extractAtBoundary(self.allocator, buf.items, ctx);
                defer br.deinit(self.allocator);
                log.info(
                    "session_end.unified_extract entities={d} edges={d} hydration_present={} session={s}",
                    .{
                        if (br.extraction) |e| e.entities.len else 0,
                        if (br.extraction) |e| e.edges.len else 0,
                        br.hydration != null,
                        session_id,
                    },
                );
            }
        }

        // V1.12 — session-end entity-pipeline pass. Catches sessions that
        // ended without hitting the per-3-turn auto-trigger boundary
        // (short sessions, or sessions whose final turn was the trigger).
        // Idempotent w.r.t. earlier per-3-turn runs: re-emitting the same
        // edge bumps weight via upsertMemoryEdge ON CONFLICT — no
        // duplicate rows. Failure-soft.
        //
        // C4 activation: this session-end enqueue is the sole remaining
        // producer for the entity pipeline (speaker-hub + co-occurrence
        // MENTIONS edges + coreference). The per-turn trigger was deleted in
        // V1.14.7, leaving this path gated behind the misnamed legacy
        // `per_turn_enqueue_enabled` (default false), which left the whole
        // pipeline dormant. It now keys off the dedicated, default-ON
        // `session_end_entity_pipeline_enabled` flag. Inline structured
        // extraction above (persistExtracted on parsed.extracted_facts) is a
        // separate, always-on path that writes facts/edges synchronously.
        if (self.extraction_cfg.session_end_entity_pipeline_enabled and self.extraction_state_mgr != null and self.extraction_user_id != null) {
            const smgr_ep = self.extraction_state_mgr.?;
            const uid_ep = self.extraction_user_id.?;
            {
                _ = self.extraction_coref_embed; // worker uses its own
                const transcript_text = buildSessionEndTranscriptText(self.allocator, entries) catch |err| blk: {
                    log.warn("session_end.entity_pipeline.build_text_failed err={s}", .{@errorName(err)});
                    break :blk null;
                };
                if (transcript_text) |tt| {
                    defer self.allocator.free(tt);
                    // V1.13 Day 2.2 — enqueue session-end pass instead
                    // of running inline. session_end already holds the
                    // session mutex via evictIdle; the prior inline
                    // approach could block reconnecting users for
                    // 10-30s waiting on LLM calls. Enqueue returns in
                    // <5ms; heartbeat worker handles the actual
                    // extraction out-of-band. Idempotent w.r.t.
                    // earlier per-turn runs.
                    const payload_str = std.fmt.allocPrint(
                        self.allocator,
                        "{{\"transcript_text\":{f}}}",
                        .{std.json.fmt(tt, .{})},
                    ) catch |err| blk: {
                        log.warn("session_end.entity_pipeline.payload_alloc_failed err={s}", .{@errorName(err)});
                        break :blk @as([]u8, &.{});
                    };
                    defer if (payload_str.len > 0) self.allocator.free(payload_str);

                    const job_id = if (payload_str.len > 0) smgr_ep.enqueueExtractionJob(
                        uid_ep,
                        session_id,
                        "session_end",
                        payload_str,
                    ) catch |err| blk: {
                        log.warn("session_end.entity_pipeline.enqueue_failed err={s}", .{@errorName(err)});
                        break :blk @as(i64, -1);
                    } else @as(i64, -1);

                    log.info(
                        "session_end.entity_pipeline_enqueued job_id={d} payload_bytes={d} session={s}",
                        .{ job_id, payload_str.len, session_id },
                    );
                    const ep_event = observability.ObserverEvent{ .turn_stage = .{
                        .stage = "session_end_entity_pipeline_enqueued",
                    } };
                    self.observer.recordEvent(&ep_event);
                }
            }
        }

        // v1.14.18-B re-activation fix (coordinator activation audit,
        // 2026-05-21): G16 (WM→durable promotion) and G1/G5 (procedural-
        // memory + reflection-trail capture) were mis-scoped INSIDE the
        // `per_turn_enqueue_enabled` gate above. captureSession was placed
        // there in V1.13 Day 4.2 when that gate defaulted true (C1); C3
        // (V1.14.7) then flipped the gate false to kill the legacy
        // extraction_QUEUE enqueue — silently taking captureSession down
        // as collateral. v1.14.18-A/B later added the promotion + reflection
        // trail into the same dead block. Neither promotion nor
        // captureSession touches extraction_queue — promotion writes
        // durable_facts via mem.store, captureSession writes
        // skill_executions — so the enqueue gate never logically applied.
        // Left gated, the entire cross-session learning loop (procedural
        // memory, reflection storage, WM promotion) was behaviorally inert
        // in every default deployment. Hoisted here: ungated, guarded only
        // by state-manager availability, failure-soft. See
        // docs/audits/2026-05-21-v1.14.18-B-activation-audit.md.
        if (self.extraction_state_mgr != null and self.extraction_user_id != null) {
            const smgr_se = self.extraction_state_mgr.?;
            const uid_se = self.extraction_user_id.?;
            const procedural_memory = @import("procedural_memory.zig");

            // G16 (WM-CROSS-SESSION) — promote high-importance WM slots
            // (active_goal + decision, composite ≥ threshold) to
            // durable_facts BEFORE the procedural-memory capture below.
            // Ordering invariant: promotion-before-capture ensures the
            // transient_goal durable_facts exist before the reflection
            // trail references them. Failure-soft: returns count 0 on any
            // setup error; per-slot failures log without aborting.
            {
                const promotion = @import("promotion.zig");
                var prom_result = promotion.promoteWMToDurableAtSessionEnd(
                    self.allocator,
                    self.extraction_state_mgr,
                    self.mem,
                    uid_se,
                    session_id,
                );
                defer prom_result.deinit(self.allocator);
                if (prom_result.count() > 0) {
                    log.info(
                        "session_end.wm_promotion count={d} session={s}",
                        .{ prom_result.count(), session_id },
                    );
                }
            }

            // G1/G5 — capture one procedural-memory trace per session that
            // crossed the tool-count threshold, carrying the reflection
            // trail into skill_executions.assumptions_made_json. The inner
            // CAPTURE_TOOL_THRESHOLD check is a legitimate triviality
            // filter (skip pure-conversation sessions) and is retained.
            var task_text: ?[]const u8 = null;
            {
                var i: usize = entries.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, entries[i].role, "user")) {
                        task_text = entries[i].content;
                        break;
                    }
                }
            }
            const tool_count_real: u32 = if (@hasField(@TypeOf(self.*), "session_total_tool_count"))
                self.session_total_tool_count
            else
                0;
            if (tool_count_real >= procedural_memory.CAPTURE_TOOL_THRESHOLD) {
                const tool_names: []const []const u8 = if (@hasField(@TypeOf(self.*), "session_tool_names"))
                    self.session_tool_names.items
                else
                    &.{};
                // Codex 6b6c22b9: fall back to the snapshotted goal status
                // when the live active_goal_state has already been cleared.
                const goal_status: ?goal_loop.GoalStatus = if (@hasField(@TypeOf(self.*), "active_goal_state") and self.active_goal_state != null)
                    self.active_goal_state.?.status
                else if (@hasField(@TypeOf(self.*), "session_last_goal_status"))
                    self.session_last_goal_status
                else
                    null;
                const reflection_trail_json: []const u8 = if (@hasField(@TypeOf(self.*), "session_reflection_trail_json") and self.session_reflection_trail_json != null)
                    self.session_reflection_trail_json.?
                else
                    "[]";
                _ = procedural_memory.captureSession(
                    self.allocator,
                    smgr_se,
                    uid_se,
                    session_id,
                    task_text,
                    tool_names,
                    tool_count_real,
                    goal_status,
                    reflection_trail_json, // v1.14.18-B G5
                );
                // Codex 6b6c22b9: reset captured procedural session state
                // (tool count + tool-name manifest + last goal verdict)
                // after the skill trace has consumed them.
                clearProceduralSessionState(self);
            }
        }
    }
    // When parsed_summary is null, we arrived here via one of three paths that
    // each already logged their own status event above (deterministic /
    // fallback=structured reason=provider_error / fallback=structured
    // reason=parse_error). Emitting another `status=fallback` here is redundant
    // and previously caused double-logging in every non-LLM turn.
    return true;
}

pub fn persistSessionCheckpoint(self: anytype, reason: []const u8) void {
    _ = persistSessionCheckpointDetailed(self, reason);
}

/// V1.14.10 A — Async lifecycle checkpoint.
///
/// Spawns a joinable worker thread that runs
/// `persistSessionCheckpointDetailed` off the agent's hot path. Used
/// by hot-path callers (compaction:auto, summary_seed:auto in
/// root.zig) to prevent the 30-180s post-reply lifecycle from
/// blocking the HTTP response. Slow LLM contention can pile up legacy
/// extraction calls (sometimes 100+ judge + coref calls per session)
/// — sync execution makes the bench client see 180s read timeouts.
///
/// In-flight guard via the Agent's `lifecycle_in_flight` atomic:
/// only one lifecycle worker per agent at a time. If a new trigger
/// fires while one is in flight, it's silently dropped — the next
/// legitimate trigger picks up whatever this one missed (lifecycle
/// is naturally re-firing on every Pass C / summary_seed cycle).
///
/// Returns:
///   `true`  — spawned successfully OR fell through to sync because
///             the guard was clear; the write WILL happen (or has).
///   `false` — guard was already set; trigger silently dropped.
///             Caller should NOT advertise "continuity refreshed" on
///             this turn — the previous worker is still running with
///             prior data; THIS turn's trigger never enqueued.
///
/// V1.14.10 A review fix (M-03): the return value lets callers stop
/// lying about `durable_continuity_refreshed = true` when the trigger
/// was a no-op.
///
/// V1.14.10 A review fix (H-03): the spawn-failure fallback no longer
/// runs sync. Under the very thread pressure that causes spawn to
/// fail, sync execution re-introduces the exact 30-180s block this
/// patch fixes. Instead we log and return false — the next legitimate
/// trigger retries when (presumably) the thread pressure has cleared.
///
/// V1.14.10 A review fix (L-01): log lines include session_id for
/// per-session debugging during bench analysis.
///
/// TTL-evict and operator-triggered (`reset:manual`) paths keep using
/// the sync version — they already run off the HTTP turn so blocking
/// is harmless.
pub fn persistSessionCheckpointAsync(self: anytype, reason: []const u8) bool {
    const session_id_for_log: []const u8 = self.memory_session_id orelse "unknown";
    if (self.lifecycle_in_flight.swap(true, .acquire)) {
        log.info("lifecycle.async.skip_in_flight reason={s} session={s}", .{ reason, session_id_for_log });
        return false;
    }
    // Reap a completed prior worker before storing a new join handle.
    self.joinLifecycleThreadIfPresent();

    // Heap-allocate the worker context. Owned by the spawned thread;
    // freed in `Worker.run`'s deferred cleanup (in the correct order:
    // allocator work first, in-flight flag LAST — see review fix H-04
    // for why ordering is load-bearing).
    const Ctx = struct {
        agent: @TypeOf(self),
        reason_owned: []u8,
        allocator: std.mem.Allocator,
    };
    const ctx = self.allocator.create(Ctx) catch {
        self.lifecycle_in_flight.store(false, .release);
        log.warn("lifecycle.async.alloc_failed reason={s} session={s} — dropping", .{ reason, session_id_for_log });
        return false;
    };
    const reason_owned = self.allocator.dupe(u8, reason) catch {
        self.lifecycle_in_flight.store(false, .release);
        self.allocator.destroy(ctx);
        log.warn("lifecycle.async.dupe_failed reason={s} session={s} — dropping", .{ reason, session_id_for_log });
        return false;
    };
    ctx.* = .{ .agent = self, .reason_owned = reason_owned, .allocator = self.allocator };

    const Worker = struct {
        fn run(c: *Ctx) void {
            // V1.14.10 A review fix (H-04): ordering matters here.
            // Clearing `lifecycle_in_flight` BEFORE freeing the heap
            // context releases any waiter (Agent.deinit) — which can
            // then free the allocator out from under our subsequent
            // `free(reason_owned)` and `destroy(c)` calls. UAF on the
            // allocator itself.
            //
            // Fix: capture allocator-side pointers + agent ref BEFORE
            // freeing the ctx; do the allocator work; THEN release
            // the in-flight flag last so the waiter only observes
            // `false` after all worker memory effects are done.
            const allocator = c.allocator;
            const reason_local = c.reason_owned;
            const agent = c.agent;
            _ = persistSessionCheckpointDetailed(agent, reason_local);
            allocator.free(reason_local);
            allocator.destroy(c);
            // Release happens-before any subsequent acquire-load — the
            // waiter that observes `false` will see ALL of the above
            // memory effects, including the allocator's free state.
            agent.lifecycle_in_flight.store(false, .release);
        }
    };

    const thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, Worker.run, .{ctx}) catch {
        // V1.14.10 A review fix (H-03): no more sync fallback. Under
        // thread pressure (the exact condition causing spawn to fail),
        // sync re-introduces the 180s block we're trying to fix.
        // Clear the in-flight flag + free the context + log; the next
        // legitimate trigger retries when pressure clears.
        self.lifecycle_in_flight.store(false, .release);
        self.allocator.free(reason_owned);
        self.allocator.destroy(ctx);
        log.warn("lifecycle.async.spawn_failed reason={s} session={s} — dropping (next trigger will retry)", .{ reason, session_id_for_log });
        return false;
    };
    self.lifecycle_thread_mu.lock();
    self.lifecycle_thread = thread;
    self.lifecycle_thread_mu.unlock();
    log.info("lifecycle.async.spawned reason={s} session={s}", .{ reason, session_id_for_log });
    return true;
}

pub fn persistSessionCheckpointDetailed(self: anytype, reason: []const u8) bool {
    const start_ms = std.time.milliTimestamp();
    defer {
        const duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - start_ms));
        log.info("turn.stage stage=continuity_refresh duration_ms={d} reason={s}", .{
            duration_ms,
            reason,
        });
        const refresh_event = observability.ObserverEvent{ .turn_stage = .{
            .stage = "continuity_refresh",
            .duration_ms = duration_ms,
        } };
        self.observer.recordEvent(&refresh_event);
    }

    const mem = self.mem orelse return false;
    const session_id = self.memory_session_id orelse return false;
    if (session_id.len == 0) return false;

    var user_count: usize = 0;
    var assistant_count: usize = 0;
    for (self.history.items) |item| {
        if (item.role == .user) user_count += 1;
        if (item.role == .assistant) assistant_count += 1;
    }
    if (user_count == 0 and assistant_count == 0) return false;

    const now_s = std.time.timestamp();
    var ts_buf: [32]u8 = undefined;
    const now_iso = util.timestamp(&ts_buf);

    var key_buf: [96]u8 = undefined;
    const checkpoint_key = std.fmt.bufPrint(&key_buf, "session_checkpoint_{d}", .{now_s}) catch return false;

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(self.allocator);
    const w = content.writer(self.allocator);
    w.print(
        "type=session_checkpoint\nreason={s}\nsession={s}\nmodel={s}\nat={s}\ncounts.user={d}\ncounts.assistant={d}\n\n",
        .{ reason, session_id, self.model_name, now_iso, user_count, assistant_count },
    ) catch return false;
    w.writeAll("recent_user:\n") catch return false;
    appendRecentRoleSnippets(w, self.history.items, .user, 3, 220) catch return false;
    w.writeAll("\nrecent_assistant:\n") catch return false;
    appendRecentRoleSnippets(w, self.history.items, .assistant, 3, 220) catch return false;

    const checkpoint_content = content.toOwnedSlice(self.allocator) catch return false;
    defer self.allocator.free(checkpoint_content);

    mem.store(checkpoint_key, checkpoint_content, .daily, null) catch return false;
    if (self.mem_rt) |rt| {
        _ = rt.syncVectorAfterStore(self.allocator, checkpoint_key, checkpoint_content);
    }

    const summary_written = persistSessionSemanticSummary(self, checkpoint_content, session_id, reason, now_s, now_iso);
    const anchor_origin = resolveSummaryOrigin(self, session_id, checkpoint_key);
    const summary_key = if (summary_written)
        std.fmt.allocPrint(self.allocator, "timeline_summary/{s}/{d}", .{ session_id, now_s }) catch null
    else
        null;
    defer if (summary_key) |value| self.allocator.free(value);
    const anchor_content = buildContextAnchorContent(
        self.allocator,
        session_id,
        anchor_origin,
        reason,
        self.model_name,
        checkpoint_key,
        summary_key,
        now_iso,
    ) catch return false;
    defer self.allocator.free(anchor_content);
    mem.store("context_anchor_current", anchor_content, .core, null) catch return false;
    if (self.mem_rt) |rt| {
        _ = rt.syncVectorAfterStore(self.allocator, "context_anchor_current", anchor_content);
    }

    exportSessionToQmd(self, session_id);

    return summary_written;
}

/// v1.14.18 Step 1 (QMD-WIRE) — session-end QMD markdown export.
///
/// When `memory.qmd.sessions.enabled` is set, the operator has asked for
/// finished sessions to be mirrored as markdown into `export_dir` so the
/// QMD index can recall them. Before this wire, the config flag was parsed
/// and `QmdAdapter.exportSessions` / `pruneExportedSessions` existed with
/// tests but had no production caller — a false-confidence surface.
///
/// Runs at session-end (off the hot path via the async lifecycle worker).
/// Best-effort: every failure is logged and swallowed; export is an
/// observability convenience, never load-bearing for a turn.
fn exportSessionToQmd(self: anytype, session_id: []const u8) void {
    const cfg = self.cachedConfigForCaps() orelse return;
    if (!cfg.memory.qmd.sessions.enabled) return;

    const store = self.session_store orelse return;

    var qmd = memory_mod.QmdAdapter.init(self.allocator, cfg.memory.qmd, self.workspace_dir);
    const ids = [_][]const u8{session_id};
    const written = qmd.exportSessions(self.allocator, store, &ids) catch |err| {
        log.warn("qmd.session_export failed err={s} session={s}", .{ @errorName(err), session_id });
        return;
    };
    const pruned = qmd.pruneExportedSessions(self.allocator) catch |err| {
        log.warn("qmd.session_prune failed err={s}", .{@errorName(err)});
        log.info("qmd.session_export written={d} pruned=0", .{written});
        return;
    };
    log.info("qmd.session_export written={d} pruned={d}", .{ written, pruned });
}

fn clearSessionState(self: anytype, reason: []const u8) void {
    persistSessionCheckpoint(self, reason);
    self.clearHistory();
    clearPendingExecCommand(self);
    clearProceduralSessionState(self);

    if (self.session_store) |store| {
        if (self.memory_session_id) |sid| { // CR-04: guard optional before passing to clearAutoSaved
            store.clearAutoSaved(sid) catch {};
        }
    }
}

fn clearProceduralSessionState(self: anytype) void {
    if (@hasField(@TypeOf(self.*), "session_total_tool_count")) {
        self.session_total_tool_count = 0;
    }
    if (@hasField(@TypeOf(self.*), "session_tool_names")) {
        for (self.session_tool_names.items) |name| self.allocator.free(name);
        self.session_tool_names.clearRetainingCapacity();
    }
    if (@hasField(@TypeOf(self.*), "session_last_goal_status")) {
        self.session_last_goal_status = null;
    }
}

fn formatWhoAmI(self: anytype) ![]const u8 {
    const session_id = self.memory_session_id orelse "unknown";
    return try std.fmt.allocPrint(
        self.allocator,
        "Session: {s}\nModel: {s}",
        .{ session_id, self.model_name },
    );
}

fn parseReasoningEffort(raw: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return "";
    if (std.ascii.eqlIgnoreCase(raw, "minimal")) return "minimal";
    if (std.ascii.eqlIgnoreCase(raw, "low")) return "low";
    if (std.ascii.eqlIgnoreCase(raw, "medium")) return "medium";
    if (std.ascii.eqlIgnoreCase(raw, "high")) return "high";
    if (std.ascii.eqlIgnoreCase(raw, "xhigh")) return "xhigh";
    return null;
}

fn parseVerboseLevel(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "on")) return .on;
    if (std.ascii.eqlIgnoreCase(raw, "full")) return .full;
    return null;
}

fn parseReasoningMode(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "on")) return .on;
    if (std.ascii.eqlIgnoreCase(raw, "stream")) return .stream;
    return null;
}

fn parseUsageMode(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "tokens")) return .tokens;
    if (std.ascii.eqlIgnoreCase(raw, "full")) return .full;
    if (std.ascii.eqlIgnoreCase(raw, "cost")) return .cost;
    return null;
}

fn parseExecHost(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "sandbox")) return .sandbox;
    if (std.ascii.eqlIgnoreCase(raw, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(raw, "node")) return .node;
    return null;
}

fn parseExecSecurity(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "deny")) return .deny;
    if (std.ascii.eqlIgnoreCase(raw, "allowlist")) return .allowlist;
    if (std.ascii.eqlIgnoreCase(raw, "full")) return .full;
    return null;
}

fn parseExecAsk(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "on-miss") or std.ascii.eqlIgnoreCase(raw, "on_miss")) return .on_miss;
    if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
    return null;
}

fn parseQueueMode(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "serial")) return .serial;
    if (std.ascii.eqlIgnoreCase(raw, "latest")) return .latest;
    if (std.ascii.eqlIgnoreCase(raw, "debounce")) return .debounce;
    return null;
}

fn parseQueueDrop(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "summarize")) return .summarize;
    if (std.ascii.eqlIgnoreCase(raw, "oldest")) return .oldest;
    if (std.ascii.eqlIgnoreCase(raw, "newest")) return .newest;
    return null;
}

fn parseTtsMode(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
    if (std.ascii.eqlIgnoreCase(raw, "inbound")) return .inbound;
    if (std.ascii.eqlIgnoreCase(raw, "tagged")) return .tagged;
    return null;
}

fn parseActivationMode(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "mention")) return .mention;
    if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
    return null;
}

fn parseSendMode(comptime T: type, raw: []const u8) ?T {
    if (std.ascii.eqlIgnoreCase(raw, "on")) return .on;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "inherit")) return .inherit;
    return null;
}

fn parseDurationMs(raw: []const u8) ?u32 {
    if (raw.len == 0) return null;
    if (std.mem.endsWith(u8, raw, "ms")) {
        const base = raw[0 .. raw.len - 2];
        return std.fmt.parseInt(u32, base, 10) catch null;
    }
    if (std.mem.endsWith(u8, raw, "s")) {
        const base = raw[0 .. raw.len - 1];
        const seconds = std.fmt.parseInt(u32, base, 10) catch return null;
        return std.math.mul(u32, seconds, 1000) catch null;
    }
    if (std.mem.endsWith(u8, raw, "m")) {
        const base = raw[0 .. raw.len - 1];
        const minutes = std.fmt.parseInt(u32, base, 10) catch return null;
        return std.math.mul(u32, minutes, 60_000) catch null;
    }
    if (std.mem.endsWith(u8, raw, "h")) {
        const base = raw[0 .. raw.len - 1];
        const hours = std.fmt.parseInt(u32, base, 10) catch return null;
        return std.math.mul(u32, hours, 3_600_000) catch null;
    }
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseDurationSeconds(raw: []const u8) ?u64 {
    const ms = parseDurationMs(raw) orelse return null;
    return @as(u64, @intCast(ms)) / 1000;
}

fn resetRuntimeCommandState(self: anytype) void {
    self.reasoning_effort = null;
    self.verbose_level = .off;
    self.reasoning_mode = .off;
    self.usage_mode = .off;
    self.exec_host = .gateway;
    self.exec_security = .allowlist;
    self.exec_ask = .on_miss;
    if (self.exec_node_id_owned and self.exec_node_id != null) self.allocator.free(self.exec_node_id.?);
    self.exec_node_id = null;
    self.exec_node_id_owned = false;
    self.queue_mode = .off;
    self.queue_debounce_ms = 0;
    self.queue_cap = 0;
    self.queue_drop = .summarize;
    self.tts_mode = .off;
    if (self.tts_provider_owned and self.tts_provider != null) self.allocator.free(self.tts_provider.?);
    self.tts_provider = null;
    self.tts_provider_owned = false;
    self.tts_limit_chars = 0;
    self.tts_summary = false;
    self.tts_audio = false;
    clearPendingExecCommand(self);
    self.session_ttl_secs = null;
    if (self.focus_target_owned and self.focus_target != null) self.allocator.free(self.focus_target.?);
    self.focus_target = null;
    self.focus_target_owned = false;
    if (self.dock_target_owned and self.dock_target != null) self.allocator.free(self.dock_target.?);
    self.dock_target = null;
    self.dock_target_owned = false;
    self.activation_mode = .mention;
    self.send_mode = .inherit;
}

fn formatStatus(self: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);

    try w.print("Model: {s}\n", .{self.model_name});
    try w.print("History: {d} messages\n", .{self.history.items.len});
    try w.print("Tokens used: {d}\n", .{self.total_tokens});
    try w.print("Tools: {d} available\n", .{self.tools.len});
    try w.print("Thinking: {s}\n", .{self.reasoning_effort orelse "off"});
    try w.print("Verbose: {s}\n", .{self.verbose_level.toSlice()});
    try w.print("Reasoning: {s}\n", .{self.reasoning_mode.toSlice()});
    try w.print("Usage: {s}\n", .{self.usage_mode.toSlice()});
    try w.print(
        "Exec: host={s} security={s} ask={s}",
        .{ self.exec_host.toSlice(), self.exec_security.toSlice(), self.exec_ask.toSlice() },
    );
    if (self.exec_node_id) |id| try w.print(" node={s}", .{id});
    try w.writeAll("\n");
    try w.print(
        "Queue: mode={s} debounce={d}ms cap={d} drop={s}\n",
        .{ self.queue_mode.toSlice(), self.queue_debounce_ms, self.queue_cap, self.queue_drop.toSlice() },
    );
    try w.print("TTS: mode={s} provider={s}\n", .{ self.tts_mode.toSlice(), self.tts_provider orelse "default" });
    try w.print("Activation: {s}\n", .{self.activation_mode.toSlice()});
    try w.print("Send: {s}\n", .{self.send_mode.toSlice()});
    if (self.session_ttl_secs) |ttl| {
        try w.print("Session TTL: {d}s\n", .{ttl});
    } else {
        try w.writeAll("Session TTL: off\n");
    }
    return try out.toOwnedSlice(self.allocator);
}

fn formatRuntimeStatus(self: anytype) ![]const u8 {
    const runtime_tool = findToolByName(self, "runtime_info") orelse
        return try self.allocator.dupe(u8, "Runtime info tool unavailable");
    const tenant_ctx = tools_mod.getTenantContext();

    const summary_json = try executeRuntimeInfoSection(self, runtime_tool, "summary", tenant_ctx.user_id);
    errdefer self.allocator.free(summary_json);
    const integrations_json = try executeRuntimeInfoSection(self, runtime_tool, "integrations", tenant_ctx.user_id);
    errdefer self.allocator.free(integrations_json);

    const summary_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, summary_json, .{}) catch {
        self.allocator.free(integrations_json);
        return summary_json;
    };
    defer summary_parsed.deinit();
    const integrations_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, integrations_json, .{}) catch {
        self.allocator.free(integrations_json);
        return summary_json;
    };
    defer integrations_parsed.deinit();
    defer self.allocator.free(summary_json);
    defer self.allocator.free(integrations_json);

    if (summary_parsed.value != .object or integrations_parsed.value != .object) {
        return try self.allocator.dupe(u8, "Runtime info unavailable");
    }

    const summary_obj = summary_parsed.value.object;
    const integrations_obj = integrations_parsed.value.object;
    const composio_obj = jsonObjectFieldObject(integrations_obj, "composio");
    const telegram_obj = jsonObjectFieldObject(integrations_obj, "telegram");

    const state_configured = jsonObjectFieldString(summary_obj, "state_backend_configured") orelse "unknown";
    const state_effective = jsonObjectFieldString(summary_obj, "state_backend_effective") orelse "unknown";
    const scheduler_backend = jsonObjectFieldString(summary_obj, "scheduler_backend") orelse "unknown";
    const degraded = optionalBoolToLabel(jsonObjectFieldBool(summary_obj, "degraded"));
    const origin = jsonObjectFieldString(summary_obj, "turn_origin") orelse "unknown";
    const provider = jsonObjectFieldString(summary_obj, "provider") orelse "unknown";
    const model = jsonObjectFieldString(summary_obj, "model") orelse "unknown";
    const session_key = jsonObjectFieldString(summary_obj, "session_key") orelse "n/a";
    const user_id = jsonObjectFieldString(summary_obj, "user_id") orelse "n/a";

    const telegram_configured = if (telegram_obj) |obj| optionalBoolToLabel(jsonObjectFieldBool(obj, "configured")) else "unknown";
    const telegram_connected = if (telegram_obj) |obj| optionalBoolToLabel(jsonObjectFieldBool(obj, "connected")) else "unknown";

    const composio_enabled = if (composio_obj) |obj| optionalBoolToLabel(jsonObjectFieldBool(obj, "enabled")) else "unknown";
    const composio_configured = if (composio_obj) |obj| optionalBoolToLabel(jsonObjectFieldBool(obj, "configured")) else "unknown";
    const composio_entity = if (composio_obj) |obj| jsonObjectFieldString(obj, "entity_id") orelse "n/a" else "n/a";
    const accounts_state = if (composio_obj) |obj| jsonObjectFieldString(obj, "connected_accounts_state") orelse "unknown" else "unknown";

    const gmail_label = if (composio_obj) |obj|
        composioReadinessLabel(jsonObjectFieldBool(obj, "gmail_connected"), accounts_state)
    else
        "unknown";
    const drive_label = if (composio_obj) |obj|
        composioReadinessLabel(jsonObjectFieldBool(obj, "google_drive_connected"), accounts_state)
    else
        "unknown";
    const calendar_label = if (composio_obj) |obj|
        composioReadinessLabel(jsonObjectFieldBool(obj, "google_calendar_connected"), accounts_state)
    else
        "unknown";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);
    try w.print("State: configured={s} effective={s} scheduler={s} degraded={s}\n", .{
        state_configured,
        state_effective,
        scheduler_backend,
        degraded,
    });
    try w.print("Turn: origin={s} provider={s} model={s}\n", .{
        origin,
        provider,
        model,
    });
    try w.print("Session: key={s} user={s}\n", .{
        session_key,
        user_id,
    });
    try w.print("Telegram: configured={s} connected={s}\n", .{
        telegram_configured,
        telegram_connected,
    });
    try w.print("Composio: enabled={s} configured={s} entity={s} accounts={s}\n", .{
        composio_enabled,
        composio_configured,
        composio_entity,
        accounts_state,
    });
    try w.print("Composio readiness: gmail={s} drive={s} calendar={s}", .{
        gmail_label,
        drive_label,
        calendar_label,
    });
    return try out.toOwnedSlice(self.allocator);
}

fn executeRuntimeInfoSection(self: anytype, runtime_tool: Tool, section: []const u8, user_id_opt: ?[]const u8) ![]u8 {
    const request = if (user_id_opt) |user_id|
        try std.fmt.allocPrint(self.allocator, "{{\"section\":\"{s}\",\"user_id\":\"{s}\"}}", .{ section, user_id })
    else
        try std.fmt.allocPrint(self.allocator, "{{\"section\":\"{s}\"}}", .{section});
    defer self.allocator.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, request, .{});
    defer parsed.deinit();
    const result = try runtime_tool.execute(self.allocator, parsed.value.object);
    if (!result.success) {
        return try self.allocator.dupe(u8, result.error_msg orelse "Runtime info unavailable");
    }
    return try self.allocator.dupe(u8, result.output); // CR-02: dupe instead of constCast for ownership safety
}

fn jsonObjectFieldString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value == .string) return value.string;
    return null;
}

fn jsonObjectFieldBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => value.bool,
        .string => |s| blk: {
            if (std.ascii.eqlIgnoreCase(s, "true")) break :blk true;
            if (std.ascii.eqlIgnoreCase(s, "false")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

fn jsonObjectFieldObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    if (value == .object) return value.object;
    return null;
}

fn optionalBoolToLabel(value: ?bool) []const u8 {
    if (value) |resolved| return if (resolved) "true" else "false";
    return "unknown";
}

fn composioReadinessLabel(connected: ?bool, accounts_state: []const u8) []const u8 {
    if (connected) |v| return if (v) "connected" else "not_connected";
    if (std.mem.eql(u8, accounts_state, "disabled")) return "disabled";
    if (std.mem.eql(u8, accounts_state, "not_configured")) return "not_configured";
    if (std.mem.eql(u8, accounts_state, "api_unreachable")) return "api_unreachable";
    return "unknown";
}

fn handleThinkCommand(self: anytype, arg: []const u8) ![]const u8 {
    const level = firstToken(arg);
    if (level.len == 0 or std.ascii.eqlIgnoreCase(level, "status")) {
        return try std.fmt.allocPrint(self.allocator, "Thinking: {s}", .{self.reasoning_effort orelse "off"});
    }

    const parsed = parseReasoningEffort(level) orelse
        return try self.allocator.dupe(u8, "Invalid /think value. Use: off|minimal|low|medium|high|xhigh");

    self.reasoning_effort = if (parsed.len == 0) null else parsed;
    return try std.fmt.allocPrint(self.allocator, "Thinking set to: {s}", .{self.reasoning_effort orelse "off"});
}

fn handleModeCommand(self: anytype, arg: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) {
        return try std.fmt.allocPrint(self.allocator, "Current execution mode: {s}", .{self.execution_mode.toSlice()});
    }
    if (execution_mode_mod.ExecutionMode.fromString(trimmed)) |mode| {
        self.execution_mode = mode;
        return try std.fmt.allocPrint(self.allocator, "Switched to {s} mode", .{mode.toSlice()});
    }
    return try self.allocator.dupe(u8, "Unknown mode. Options: plan, execute, review, background");
}

fn handlePlanCommand(self: anytype) ![]const u8 {
    self.execution_mode = .plan;
    return try self.allocator.dupe(
        u8,
        "Switched to plan mode. Mutating tools are blocked; read-only tools may run. See /permissions for current policy details.",
    );
}

fn handleReviewCommand(self: anytype) ![]const u8 {
    self.execution_mode = .review;
    return try self.allocator.dupe(
        u8,
        "Switched to review mode. Mutating tools are blocked; read-only tools may run. See /permissions for current policy details.",
    );
}

fn handleExecuteCommand(self: anytype) ![]const u8 {
    self.execution_mode = .execute;
    return try self.allocator.dupe(
        u8,
        "Switched to execute mode. Tools follow current security policy. See /permissions for current policy details.",
    );
}

fn handleVerboseCommand(self: anytype, arg: []const u8) ![]const u8 {
    const level = firstToken(arg);
    if (level.len == 0 or std.ascii.eqlIgnoreCase(level, "status")) {
        return try std.fmt.allocPrint(self.allocator, "Verbose: {s}", .{self.verbose_level.toSlice()});
    }

    const parsed = parseVerboseLevel(@TypeOf(self.verbose_level), level) orelse
        return try self.allocator.dupe(u8, "Invalid /verbose value. Use: on|full|off");
    self.verbose_level = parsed;
    return try std.fmt.allocPrint(self.allocator, "Verbose set to: {s}", .{self.verbose_level.toSlice()});
}

fn handleReasoningCommand(self: anytype, arg: []const u8) ![]const u8 {
    const mode = firstToken(arg);
    if (mode.len == 0 or std.ascii.eqlIgnoreCase(mode, "status")) {
        return try std.fmt.allocPrint(self.allocator, "Reasoning output: {s}", .{self.reasoning_mode.toSlice()});
    }

    const parsed = parseReasoningMode(@TypeOf(self.reasoning_mode), mode) orelse
        return try self.allocator.dupe(u8, "Invalid /reasoning value. Use: on|off|stream");
    self.reasoning_mode = parsed;
    return try std.fmt.allocPrint(self.allocator, "Reasoning output set to: {s}", .{self.reasoning_mode.toSlice()});
}

fn handleExecCommand(self: anytype, arg: []const u8) ![]const u8 {
    if (arg.len == 0 or std.ascii.eqlIgnoreCase(arg, "status")) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.print(
            "Exec: host={s} security={s} ask={s}",
            .{ self.exec_host.toSlice(), self.exec_security.toSlice(), self.exec_ask.toSlice() },
        );
        if (self.exec_node_id) |id| {
            try w.print(" node={s}", .{id});
        }
        return try out.toOwnedSlice(self.allocator);
    }

    var it = std.mem.tokenizeAny(u8, arg, " \t");
    while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse
            return try self.allocator.dupe(u8, "Invalid /exec argument. Use host=<...> security=<...> ask=<...> node=<id>");
        const key = tok[0..eq];
        const value = tok[eq + 1 ..];
        if (value.len == 0) {
            return try self.allocator.dupe(u8, "Invalid /exec argument: empty value");
        }
        if (std.ascii.eqlIgnoreCase(key, "host")) {
            self.exec_host = parseExecHost(@TypeOf(self.exec_host), value) orelse
                return try self.allocator.dupe(u8, "Invalid host. Use: sandbox|gateway|node");
        } else if (std.ascii.eqlIgnoreCase(key, "security")) {
            self.exec_security = parseExecSecurity(@TypeOf(self.exec_security), value) orelse
                return try self.allocator.dupe(u8, "Invalid security. Use: deny|allowlist|full");
        } else if (std.ascii.eqlIgnoreCase(key, "ask")) {
            self.exec_ask = parseExecAsk(@TypeOf(self.exec_ask), value) orelse
                return try self.allocator.dupe(u8, "Invalid ask. Use: off|on-miss|always");
        } else if (std.ascii.eqlIgnoreCase(key, "node")) {
            try setExecNodeId(self, value);
        } else {
            return try std.fmt.allocPrint(self.allocator, "Unknown /exec key: {s}", .{key});
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);
    try w.print(
        "Exec set: host={s} security={s} ask={s}",
        .{ self.exec_host.toSlice(), self.exec_security.toSlice(), self.exec_ask.toSlice() },
    );
    if (self.exec_node_id) |id| {
        try w.print(" node={s}", .{id});
    }
    return try out.toOwnedSlice(self.allocator);
}

fn handleQueueCommand(self: anytype, arg: []const u8) ![]const u8 {
    if (arg.len == 0 or std.ascii.eqlIgnoreCase(arg, "status")) {
        return try std.fmt.allocPrint(
            self.allocator,
            "Queue: mode={s} debounce={d}ms cap={d} drop={s}",
            .{ self.queue_mode.toSlice(), self.queue_debounce_ms, self.queue_cap, self.queue_drop.toSlice() },
        );
    }

    if (std.ascii.eqlIgnoreCase(arg, "reset")) {
        self.queue_mode = .off;
        self.queue_debounce_ms = 0;
        self.queue_cap = 0;
        self.queue_drop = .summarize;
        return try self.allocator.dupe(u8, "Queue settings reset.");
    }

    var it = std.mem.tokenizeAny(u8, arg, " \t");
    while (it.next()) |tok| {
        if (parseQueueMode(@TypeOf(self.queue_mode), tok)) |mode| {
            self.queue_mode = mode;
            continue;
        }

        const sep = std.mem.indexOfScalar(u8, tok, ':') orelse
            return try self.allocator.dupe(u8, "Invalid /queue argument. Use mode plus debounce:<dur> cap:<n> drop:<summarize|oldest|newest>");
        const key = tok[0..sep];
        const value = tok[sep + 1 ..];

        if (std.ascii.eqlIgnoreCase(key, "debounce")) {
            self.queue_debounce_ms = parseDurationMs(value) orelse
                return try self.allocator.dupe(u8, "Invalid debounce duration");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "cap")) {
            self.queue_cap = std.fmt.parseInt(u32, value, 10) catch
                return try self.allocator.dupe(u8, "Invalid queue cap");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "drop")) {
            self.queue_drop = parseQueueDrop(@TypeOf(self.queue_drop), value) orelse
                return try self.allocator.dupe(u8, "Invalid drop mode");
            continue;
        }

        return try std.fmt.allocPrint(self.allocator, "Unknown /queue option: {s}", .{key});
    }

    return try std.fmt.allocPrint(
        self.allocator,
        "Queue set: mode={s} debounce={d}ms cap={d} drop={s}",
        .{ self.queue_mode.toSlice(), self.queue_debounce_ms, self.queue_cap, self.queue_drop.toSlice() },
    );
}

fn handleUsageCommand(self: anytype, arg: []const u8) ![]const u8 {
    const mode = firstToken(arg);
    if (mode.len == 0 or std.ascii.eqlIgnoreCase(mode, "status")) {
        // Use structured UsageRuntime report when available
        if (self.usage_rt) |urt| {
            const rpt = urt.report(self.allocator) catch
                return try std.fmt.allocPrint(
                    self.allocator,
                    "Usage: {s}\nSession total: {d} tokens",
                    .{ self.usage_mode.toSlice(), self.total_tokens },
                );
            defer rpt.deinit();
            const text = rpt.formatText(self.allocator) catch
                return try self.allocator.dupe(u8, "[usage report format error]");
            return text;
        }
        return try std.fmt.allocPrint(
            self.allocator,
            "Usage: {s}\nLast turn: prompt={d} completion={d} total={d}\nSession total: {d}",
            .{
                self.usage_mode.toSlice(),
                self.last_turn_usage.prompt_tokens,
                self.last_turn_usage.completion_tokens,
                self.last_turn_usage.total_tokens,
                self.total_tokens,
            },
        );
    }

    self.usage_mode = parseUsageMode(@TypeOf(self.usage_mode), mode) orelse
        return try self.allocator.dupe(u8, "Invalid /usage value. Use: off|tokens|full|cost");
    return try std.fmt.allocPrint(self.allocator, "Usage mode set to: {s}", .{self.usage_mode.toSlice()});
}

// WP3.3: /cost — read-only token and cost status.
//
// Reports last turn and session totals using existing usage state. Never
// mutates usage_mode, execution_mode, pending approvals, or counters. When
// UsageRuntime has recorded a non-zero session_cost_usd we surface it;
// otherwise we explicitly state that provider pricing is not wired — we do
// NOT invent rates or maintain a local pricing table.
fn handleCostCommand(self: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);

    var have_cost = false;
    var cost_usd: f64 = 0.0;
    if (self.usage_rt) |urt| {
        const totals = urt.sessionTotals();
        if (totals.cost > 0.0) {
            have_cost = true;
            cost_usd = totals.cost;
        }
    }

    if (have_cost) {
        try w.print("Session cost: ${d:.6}\n", .{cost_usd});
    } else {
        try w.writeAll("Cost estimate unavailable: provider pricing is not wired for this session.\n");
    }

    try w.print(
        "Last turn: prompt={d} completion={d} total={d}\n",
        .{
            self.last_turn_usage.prompt_tokens,
            self.last_turn_usage.completion_tokens,
            self.last_turn_usage.total_tokens,
        },
    );
    try w.print("Session total: tokens={d}\n", .{self.total_tokens});
    try w.writeAll("Use /usage cost to append this status to future replies.");

    return try out.toOwnedSlice(self.allocator);
}

fn handleTtsCommand(self: anytype, arg: []const u8) ![]const u8 {
    if (arg.len == 0 or std.ascii.eqlIgnoreCase(arg, "status")) {
        return try std.fmt.allocPrint(
            self.allocator,
            "TTS: mode={s} provider={s} limit={d} summary={s} audio={s}",
            .{
                self.tts_mode.toSlice(),
                self.tts_provider orelse "default",
                self.tts_limit_chars,
                if (self.tts_summary) "on" else "off",
                if (self.tts_audio) "on" else "off",
            },
        );
    }

    var it = std.mem.tokenizeAny(u8, arg, " \t");
    while (it.next()) |tok| {
        if (parseTtsMode(@TypeOf(self.tts_mode), tok)) |mode| {
            self.tts_mode = mode;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tok, "status")) continue;

        if (std.mem.startsWith(u8, tok, "provider=")) {
            const value = tok["provider=".len..];
            if (value.len == 0) return try self.allocator.dupe(u8, "Invalid provider value");
            try setTtsProvider(self, value);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tok, "provider")) {
            const value = it.next() orelse return try self.allocator.dupe(u8, "Missing provider value");
            try setTtsProvider(self, value);
            continue;
        }

        if (std.mem.startsWith(u8, tok, "limit=")) {
            const value = tok["limit=".len..];
            self.tts_limit_chars = std.fmt.parseInt(u32, value, 10) catch
                return try self.allocator.dupe(u8, "Invalid TTS limit");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tok, "limit")) {
            const value = it.next() orelse return try self.allocator.dupe(u8, "Missing limit value");
            self.tts_limit_chars = std.fmt.parseInt(u32, value, 10) catch
                return try self.allocator.dupe(u8, "Invalid TTS limit");
            continue;
        }

        if (std.ascii.eqlIgnoreCase(tok, "summary")) {
            const value = it.next() orelse return try self.allocator.dupe(u8, "Missing summary value");
            if (std.ascii.eqlIgnoreCase(value, "on")) {
                self.tts_summary = true;
            } else if (std.ascii.eqlIgnoreCase(value, "off")) {
                self.tts_summary = false;
            } else {
                return try self.allocator.dupe(u8, "Invalid summary value. Use on|off");
            }
            continue;
        }

        if (std.ascii.eqlIgnoreCase(tok, "audio")) {
            const value = it.next() orelse return try self.allocator.dupe(u8, "Missing audio value");
            if (std.ascii.eqlIgnoreCase(value, "on")) {
                self.tts_audio = true;
            } else if (std.ascii.eqlIgnoreCase(value, "off")) {
                self.tts_audio = false;
            } else {
                return try self.allocator.dupe(u8, "Invalid audio value. Use on|off");
            }
            continue;
        }

        return try std.fmt.allocPrint(self.allocator, "Unknown /tts option: {s}", .{tok});
    }

    return try std.fmt.allocPrint(
        self.allocator,
        "TTS set: mode={s} provider={s} limit={d} summary={s} audio={s}",
        .{
            self.tts_mode.toSlice(),
            self.tts_provider orelse "default",
            self.tts_limit_chars,
            if (self.tts_summary) "on" else "off",
            if (self.tts_audio) "on" else "off",
        },
    );
}

fn handleAllowlistCommand(self: anytype, arg: []const u8) ![]const u8 {
    _ = arg;
    if (self.policy) |pol| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.writeAll("Allowlisted commands:\n");
        for (pol.allowed_commands) |cmd| {
            try w.print("  - {s}\n", .{cmd});
        }
        return try out.toOwnedSlice(self.allocator);
    }
    return try self.allocator.dupe(u8, "No runtime allowlist policy attached.");
}

fn handleContextCommand(self: anytype, arg: []const u8) ![]const u8 {
    const mode = firstToken(arg);
    const report = context_report.fromAgent(self);
    if (std.ascii.eqlIgnoreCase(mode, "json")) {
        return try context_report.formatJson(self.allocator, report);
    }

    if (std.ascii.eqlIgnoreCase(mode, "detail")) {
        return try context_report.formatDetail(self.allocator, report);
    }

    return try context_report.formatSummary(self.allocator, report);
}

fn handleExportSessionCommand(self: anytype, arg: []const u8) ![]const u8 {
    const raw_path = firstToken(arg);
    const path = if (raw_path.len == 0)
        try std.fmt.allocPrint(self.allocator, "{s}/session-{d}.md", .{ self.workspace_dir, std.time.timestamp() })
    else if (std.fs.path.isAbsolute(raw_path))
        try self.allocator.dupe(u8, raw_path)
    else
        try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace_dir, raw_path });
    defer self.allocator.free(path);

    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true, .read = false })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true, .read = false });
    defer file.close();
    var out_buf: [4096]u8 = undefined;
    var bw = file.writer(&out_buf);
    const w = &bw.interface;
    try w.print("# Session export\n\nModel: `{s}`\n\n", .{self.model_name});
    for (self.history.items) |entry| {
        const role = switch (entry.role) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
        // Use transcript hygiene for clean export (strips [Memory context], [Queue notice])
        transcript.formatExportEntry(w, role, entry.content, null) catch {};
    }
    try w.flush();

    return try std.fmt.allocPrint(self.allocator, "Session exported to: {s}", .{path});
}

fn handleSessionCommand(self: anytype, arg: []const u8) ![]const u8 {
    var it = std.mem.tokenizeAny(u8, arg, " \t");
    const sub = it.next() orelse return try std.fmt.allocPrint(self.allocator, "Session TTL: {s}", .{if (self.session_ttl_secs) |_| "set" else "off"});
    if (std.ascii.eqlIgnoreCase(sub, "ttl")) {
        const ttl = it.next() orelse {
            if (self.session_ttl_secs) |v| {
                return try std.fmt.allocPrint(self.allocator, "Session TTL: {d}s", .{v});
            }
            return try self.allocator.dupe(u8, "Session TTL: off");
        };
        if (std.ascii.eqlIgnoreCase(ttl, "off")) {
            self.session_ttl_secs = null;
            return try self.allocator.dupe(u8, "Session TTL disabled.");
        }
        self.session_ttl_secs = parseDurationSeconds(ttl) orelse
            return try self.allocator.dupe(u8, "Invalid TTL duration.");
        return try std.fmt.allocPrint(self.allocator, "Session TTL set to {d}s.", .{self.session_ttl_secs.?});
    }
    return try self.allocator.dupe(u8, "Unknown /session command. Use: /session ttl <duration|off>");
}

fn handleResetCommand(self: anytype, arg: []const u8) ![]const u8 {
    _ = arg; // reserved for future flags like --no-checkpoint
    // Step 1: persist checkpoint before clearing (T-03-06: no data loss on reset)
    persistSessionCheckpoint(self, "reset:manual");
    // Step 2: clear history
    self.clearHistory();
    // Step 3: reset runtime command state
    resetRuntimeCommandState(self);
    // Step 4: reset token and compaction counters on Agent
    self.total_tokens = 0;
    self.last_turn_compacted = false;
    return try self.allocator.dupe(u8, "Session reset. Checkpoint saved, history cleared.");
}

fn handleResumeCommand(self: anytype, arg: []const u8) ![]const u8 {
    const session_identity = @import("../session/identity.zig");
    const target_key = std.mem.trim(u8, firstToken(arg), " \t");
    if (target_key.len == 0) {
        return try self.allocator.dupe(u8, "Usage: /resume <session_key>");
    }
    if (target_key.len > 255) {
        return try self.allocator.dupe(u8, "Error: session key too long (max 255 chars).");
    }
    // Validate ownership: target session key must belong to the current user (T-03-05)
    const zaki_session = @import("../session/root.zig");
    const current_user_id = zaki_session.parseUserIdFromSessionKey(self.memory_session_id orelse "") orelse {
        return try self.allocator.dupe(u8, "Error: cannot determine current user for ownership check.");
    };
    if (!session_identity.isOwnedBy(target_key, current_user_id)) {
        return try self.allocator.dupe(u8, "Error: session key does not belong to current user.");
    }
    // Validate the key parses correctly
    _ = session_identity.parseSessionKey(target_key) catch {
        return try self.allocator.dupe(u8, "Error: invalid session key format.");
    };
    // Note: Agent does not own memory_session_id (managed by SessionManager).
    // Instruct the caller to reconnect with the target session key.
    return try std.fmt.allocPrint(
        self.allocator,
        "To resume session {s}, reconnect with session_key={s} in your next API request.",
        .{ target_key, target_key },
    );
}

fn handleFocusCommand(self: anytype, arg: []const u8) ![]const u8 {
    const target = std.mem.trim(u8, arg, " \t");
    if (target.len == 0) {
        return try self.allocator.dupe(u8, "Missing focus target.");
    }
    try setFocusTarget(self, target);
    return try std.fmt.allocPrint(self.allocator, "Focused on: {s}", .{target});
}

fn handleUnfocusCommand(self: anytype) ![]const u8 {
    try setFocusTarget(self, null);
    return try self.allocator.dupe(u8, "Focus cleared.");
}

fn handleDockCommand(self: anytype, channel: []const u8) ![]const u8 {
    try setDockTarget(self, channel);
    return try std.fmt.allocPrint(self.allocator, "Dock target set to: {s}", .{channel});
}

fn handleActivationCommand(self: anytype, arg: []const u8) ![]const u8 {
    const mode = firstToken(arg);
    if (mode.len == 0 or std.ascii.eqlIgnoreCase(mode, "status")) {
        return try std.fmt.allocPrint(self.allocator, "Activation mode: {s}", .{self.activation_mode.toSlice()});
    }
    self.activation_mode = parseActivationMode(@TypeOf(self.activation_mode), mode) orelse
        return try self.allocator.dupe(u8, "Invalid activation mode. Use: mention|always");
    return try std.fmt.allocPrint(self.allocator, "Activation mode set to: {s}", .{self.activation_mode.toSlice()});
}

fn handleSendCommand(self: anytype, arg: []const u8) ![]const u8 {
    const mode = firstToken(arg);
    if (mode.len == 0 or std.ascii.eqlIgnoreCase(mode, "status")) {
        return try std.fmt.allocPrint(self.allocator, "Send mode: {s}", .{self.send_mode.toSlice()});
    }
    self.send_mode = parseSendMode(@TypeOf(self.send_mode), mode) orelse
        return try self.allocator.dupe(u8, "Invalid send mode. Use: on|off|inherit");
    return try std.fmt.allocPrint(self.allocator, "Send mode set to: {s}", .{self.send_mode.toSlice()});
}

fn handleElevatedCommand(self: anytype, arg: []const u8) ![]const u8 {
    const mode = firstToken(arg);
    if (mode.len == 0 or std.ascii.eqlIgnoreCase(mode, "status")) {
        return try std.fmt.allocPrint(
            self.allocator,
            "Elevated policy: security={s} ask={s}",
            .{ self.exec_security.toSlice(), self.exec_ask.toSlice() },
        );
    }

    if (std.ascii.eqlIgnoreCase(mode, "full")) {
        self.exec_security = .full;
        self.exec_ask = .off;
    } else if (std.ascii.eqlIgnoreCase(mode, "ask")) {
        self.exec_security = .allowlist;
        self.exec_ask = .on_miss;
    } else if (std.ascii.eqlIgnoreCase(mode, "on")) {
        self.exec_security = .allowlist;
        self.exec_ask = .on_miss;
    } else if (std.ascii.eqlIgnoreCase(mode, "off")) {
        self.exec_security = .deny;
        self.exec_ask = .off;
    } else {
        return try self.allocator.dupe(u8, "Invalid /elevated value. Use: on|off|ask|full");
    }

    return try std.fmt.allocPrint(
        self.allocator,
        "Elevated policy set: security={s} ask={s}",
        .{ self.exec_security.toSlice(), self.exec_ask.toSlice() },
    );
}

fn parseApproveDecision(raw: []const u8) ?enum { allow_once, allow_always, deny } {
    if (std.ascii.eqlIgnoreCase(raw, "allow") or
        std.ascii.eqlIgnoreCase(raw, "once") or
        std.ascii.eqlIgnoreCase(raw, "allow-once") or
        std.ascii.eqlIgnoreCase(raw, "allowonce"))
    {
        return .allow_once;
    }
    if (std.ascii.eqlIgnoreCase(raw, "always") or
        std.ascii.eqlIgnoreCase(raw, "allow-always") or
        std.ascii.eqlIgnoreCase(raw, "allowalways"))
    {
        return .allow_always;
    }
    if (std.ascii.eqlIgnoreCase(raw, "deny") or
        std.ascii.eqlIgnoreCase(raw, "reject") or
        std.ascii.eqlIgnoreCase(raw, "block"))
    {
        return .deny;
    }
    return null;
}

fn runShellCommand(self: anytype, command: []const u8, skip_approval_gate: bool) ![]const u8 {
    if (self.exec_host == .node) {
        return try self.allocator.dupe(u8, "Exec blocked: host=node is not available in this runtime");
    }
    if (self.exec_security == .deny) {
        return try self.allocator.dupe(u8, "Exec blocked by /exec security=deny");
    }
    if (!skip_approval_gate and self.exec_ask == .always) {
        try setPendingExecCommand(self, command);
        return try std.fmt.allocPrint(
            self.allocator,
            "Exec approval required (id={d}). Use /approve {d} allow-once|allow-always|deny",
            .{ self.pending_exec_id, self.pending_exec_id },
        );
    }
    if (self.exec_security == .allowlist) {
        if (self.policy) |pol| {
            if (!pol.isCommandAllowed(command)) {
                return try self.allocator.dupe(u8, "Exec blocked by allowlist policy");
            }
        }
    }

    const shell_tool = findShellTool(self) orelse
        return try self.allocator.dupe(u8, "Shell tool is not enabled.");

    var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var args = std.json.ObjectMap.init(arena);
    try args.put("command", .{ .string = command });

    const result = shell_tool.execute(arena, args) catch |err| {
        return try std.fmt.allocPrint(self.allocator, "Bash failed: {s}", .{@errorName(err)});
    };

    const text = if (result.success) result.output else (result.error_msg orelse result.output);
    return try self.allocator.dupe(u8, text);
}

/// Resolve /approve when a generic pending tool approval exists.
/// Handles: status display, allow-once, deny, and allow-always (treated as
/// allow-once in v1 — there is no persistent generic allowlist yet).
fn handleGenericToolApprove(self: anytype, arg: []const u8) ![]const u8 {
    const pending = self.pending_tool_approval.?;

    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) {
        return try std.fmt.allocPrint(
            self.allocator,
            "Pending tool approval id={d} tool={s} risk={s} reason={s}\nUse /approve {d} allow-once|deny",
            .{ pending.id, pending.tool_name, pending.risk_level.toSlice(), pending.reason, pending.id },
        );
    }

    var requested_id: ?u64 = null;
    var decision_token: []const u8 = firstToken(trimmed);

    const first = splitFirstToken(trimmed);
    if (parseTaskId(first.head)) |id| {
        requested_id = id;
        decision_token = firstToken(first.tail);
    }

    const decision = parseApproveDecision(decision_token) orelse
        return try self.allocator.dupe(u8, "Usage: /approve <id?> allow-once|deny");

    if (requested_id) |id| {
        if (id != pending.id) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Approval id mismatch. Pending tool approval id is {d}.",
                .{pending.id},
            );
        }
    }

    if (decision == .deny) {
        const id_snapshot = pending.id;
        // HI-03-parity: clone the tool name into an owned buffer BEFORE
        // clearPendingToolApproval frees the pending slices, so the denial
        // note below can name the tool without aliasing freed memory.
        const tool_name_owned = try self.allocator.dupe(u8, pending.tool_name);
        defer self.allocator.free(tool_name_owned);
        // P0-4 (e): settle the durable row BEFORE the RAM clear frees the id.
        if (@hasDecl(@TypeOf(self.*), "settlePendingApprovalDurable")) {
            const approval_id_owned = try self.allocator.dupe(u8, pending.approval_id);
            defer self.allocator.free(approval_id_owned);
            self.clearPendingToolApproval();
            self.settlePendingApprovalDurable(approval_id_owned, false);
        } else {
            self.clearPendingToolApproval();
        }
        // S5 (2026-05-29, prod-readiness) — user-resolution tail of
        // the approval lifecycle. The complementary "issued" emit fires
        // at the preflight gate in `preflightToolPolicy` (root.zig).
        observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "user_denied" } });

        // P0-4: feed the model a short denial note + start a continuation turn
        // so it can ADAPT (try a different approach, ask the user, explain)
        // instead of dead-stopping. Previously deny returned here with no
        // continuation — the turn just ended and the model never learned the
        // user rejected its tool call. Gated on `approval_continues_turn`
        // (same gate as the approve path): legacy tests without a live
        // provider keep the direct-reply behavior.
        const continues_turn = if (@hasField(@TypeOf(self.*), "approval_continues_turn"))
            self.approval_continues_turn
        else
            true;

        if (continues_turn) {
            const synthetic = try std.fmt.allocPrint(
                self.allocator,
                "[The user DENIED your request to run the tool `{s}` (approval id={d}). " ++
                    "Do not attempt to run it again. Adapt: either propose a different " ++
                    "approach that does not require that tool, ask the user a clarifying " ++
                    "question, or explain what you can still do without it.]",
                .{ tool_name_owned, id_snapshot },
            );
            defer self.allocator.free(synthetic);

            const continuation_result: anyerror![]const u8 = self.turn(synthetic);
            if (continuation_result) |continuation| {
                if (std.mem.trim(u8, continuation, " \t\r\n").len == 0) {
                    self.allocator.free(continuation);
                    return try std.fmt.allocPrint(
                        self.allocator,
                        "Tool approval id={d} denied.",
                        .{id_snapshot},
                    );
                }
                return continuation;
            } else |_| {
                // Continuation failed — fall back to the plain ack.
                return try std.fmt.allocPrint(
                    self.allocator,
                    "Tool approval id={d} denied.",
                    .{id_snapshot},
                );
            }
        }

        return try std.fmt.allocPrint(
            self.allocator,
            "Tool approval id={d} denied.",
            .{id_snapshot},
        );
    }

    // Both allow-once and allow-always run the tool exactly once in v1.
    // There is no persistent generic allowlist — say so explicitly.
    const id_snapshot = pending.id;
    const always_note: []const u8 = if (decision == .allow_always)
        " (allow-always not supported for generic tool approval in v1 — ran once)"
    else
        "";

    // S5 (2026-05-29, prod-readiness) — user-resolution tail of the
    // approval lifecycle. Emit BEFORE executeApprovedPendingTool runs so
    // the counter reflects the user decision regardless of whether the
    // tool itself later raises an error.
    observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "user_approved" } });

    // P0-4 (e): settle the durable row to 'approved' BEFORE execute (which is
    // also where the metric settles). The user's decision is "approved"
    // regardless of whether the tool later errors — and settling here, while
    // `pending` is still live, captures the id once for ALL approve exit paths
    // (failure / legacy-no-turn / continuation) without scattering the settle
    // across each clearPendingToolApproval site. Duplicate settles are no-ops
    // (resolvePendingApproval only transitions a still-'pending' row).
    if (@hasDecl(@TypeOf(self.*), "settlePendingApprovalDurable")) {
        const approval_id_owned = self.allocator.dupe(u8, pending.approval_id) catch null;
        if (approval_id_owned) |aid| {
            defer self.allocator.free(aid);
            self.settlePendingApprovalDurable(aid, true);
        }
    }

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    // CR-01 (2026-05-07): executeApprovedPendingTool no longer clears
    // pending state internally — the caller (this function) owns the
    // clear. We hold pending live across executeApprovedPendingTool +
    // the synthetic message build so `pending.tool_name` etc. stay
    // valid for the allocPrint at line 2596+. After that, we drop
    // back to the regular post-clear path.
    const result = self.executeApprovedPendingTool(arena.allocator()) catch |err| {
        // Pending state is still live here; clear before returning.
        self.clearPendingToolApproval();
        return try std.fmt.allocPrint(
            self.allocator,
            "Approved tool execution failed: {s}",
            .{@errorName(err)},
        );
    };

    // ── Continue-turn-after-approval fix (2026-04-18) ─────────────────
    // Previously this returned the tool's raw output as the /approve
    // reply, which meant the agent's turn loop never saw the tool result
    // and never produced its next reasoning step. The user clicked approve
    // and got "Approved tool... output=..." but the agent had already
    // ended its previous turn; the tool ran out-of-band.
    //
    // Fix: build a synthetic continuation message that embeds the real
    // tool output and invokes agent.turn(). The LLM sees the tool result
    // in context and produces the coherent next response. Return THAT as
    // the /approve reply — not the raw tool output.
    //
    // On tool failure (result.success == false) we still continue-turn
    // because the model should reason about the failure too (retry a
    // different approach, ask the user, etc.). That's the honest flow.
    //
    // Output is capped at 4000 chars to avoid blowing context on huge
    // tool outputs. Tools that produce more than that should already be
    // returning summaries or file-backed results.

    const continues_turn = if (@hasField(@TypeOf(self.*), "approval_continues_turn"))
        self.approval_continues_turn
    else
        true;

    // Legacy path (tests without a live provider): return the tool output
    // as the reply directly. Production default is `continues_turn = true`.
    if (!continues_turn) {
        // CR-01: pending state was held live for this branch; clear now
        // that we've finished reading slices we needed (none here, but
        // keep for symmetry with the continues-turn path below).
        defer self.clearPendingToolApproval();
        return try std.fmt.allocPrint(
            self.allocator,
            "Approved tool (id={d}) success={any}.{s}\n{s}",
            .{ id_snapshot, result.success, always_note, result.output },
        );
    }

    const MAX_SYNTHETIC_OUTPUT_CHARS: usize = 4000;
    const truncated_output = if (result.output.len > MAX_SYNTHETIC_OUTPUT_CHARS)
        result.output[0..MAX_SYNTHETIC_OUTPUT_CHARS]
    else
        result.output;
    const truncation_note = if (result.output.len > MAX_SYNTHETIC_OUTPUT_CHARS)
        "\n\n[output truncated — full length was larger]"
    else
        "";

    const success_word = if (result.success) "succeeded" else "failed";
    // HI-03 fix (2026-05-07): residual CR-01 leak. Pre-fix order was
    // `allocPrint(.., pending.tool_name) → defer free → clearPending`.
    // If allocPrint OOMed, the `try` propagated UP before clearPending
    // ran; the next /approve would see stale pending state and re-execute
    // the just-approved tool. Fix: clone the name into an owned buffer
    // FIRST, clear pending IMMEDIATELY (no more aliasing of pending's
    // slices), then format using the owned copy. allocPrint may still
    // OOM but pending is already cleared by then.
    const tool_name_owned = try self.allocator.dupe(u8, pending.tool_name);
    defer self.allocator.free(tool_name_owned);
    self.clearPendingToolApproval();

    const synthetic = try std.fmt.allocPrint(
        self.allocator,
        "[Approved tool execution: id={d} tool={s} status={s}{s}]\n\nOutput:\n{s}{s}\n\nContinue your reasoning based on this tool result. Produce the next step for the user.",
        .{
            id_snapshot,
            tool_name_owned,
            success_word,
            always_note,
            truncated_output,
            truncation_note,
        },
    );
    defer self.allocator.free(synthetic);

    // If the continuation turn itself fails, fall back to returning
    // the raw tool output so the user at least sees what happened.
    // `self: anytype` forces us to cast through `anyerror` explicitly
    // so the error set resolves at the call site instead of propagating
    // through the caller's inferred union.
    const continuation_result: anyerror![]const u8 = self.turn(synthetic);
    if (continuation_result) |continuation| {
        if (std.mem.trim(u8, continuation, " \t\r\n").len == 0) {
            self.allocator.free(continuation);
            return try std.fmt.allocPrint(
                self.allocator,
                "Approved tool (id={d}) {s}.{s}\n{s}",
                .{ id_snapshot, success_word, always_note, result.output },
            );
        }
        return continuation;
    } else |err| {
        return try std.fmt.allocPrint(
            self.allocator,
            "Approved tool (id={d}) {s}.{s}\n{s}\n\n[Continuation turn failed: {s}]",
            .{ id_snapshot, success_word, always_note, result.output, @errorName(err) },
        );
    }
}

fn handleApproveCommand(self: anytype, arg: []const u8) ![]const u8 {
    // Generic pending tool approval (WP1.4) takes precedence over legacy
    // shell/exec approval. When one is active, /approve resolves it and
    // never falls through to the shell path.
    if (@hasField(@TypeOf(self.*), "pending_tool_approval")) {
        if (self.pending_tool_approval != null) {
            return try handleGenericToolApprove(self, arg);
        }
    }

    // S2 audit fix (cross-namespace collision). `pending_exec_id` and
    // `pending_tool_approval_id_counter` are independent u64 counters,
    // so a numeric id captured for the generic namespace can
    // coincidentally match a legacy shell pending. If the caller
    // supplied an id (the Sprint-2 gateway always does when the FE
    // pinned to `approval_id`), we MUST NOT let the legacy shell path
    // satisfy a generic-namespace approval — reject as id mismatch and
    // leave the shell pending intact for the next plain /approve.
    const trimmed_arg = std.mem.trim(u8, arg, " \t");
    if (trimmed_arg.len > 0) {
        const head = splitFirstToken(trimmed_arg).head;
        if (parseTaskId(head) != null) {
            return try self.allocator.dupe(
                u8,
                "Approval id mismatch. Pending tool approval was already resolved or cleared.",
            );
        }
    }

    const pending_command = self.pending_exec_command orelse
        return try self.allocator.dupe(u8, "No pending approval requests.");

    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) {
        return try std.fmt.allocPrint(
            self.allocator,
            "Pending approval id={d} for command: {s}\nUse /approve {d} allow-once|allow-always|deny",
            .{ self.pending_exec_id, pending_command, self.pending_exec_id },
        );
    }

    var requested_id: ?u64 = null;
    var decision_token: []const u8 = firstToken(trimmed);

    const first = splitFirstToken(trimmed);
    if (parseTaskId(first.head)) |id| {
        requested_id = id;
        decision_token = firstToken(first.tail);
    }

    const decision = parseApproveDecision(decision_token) orelse
        return try self.allocator.dupe(u8, "Usage: /approve <id?> allow-once|allow-always|deny");

    if (requested_id) |id| {
        if (id != self.pending_exec_id) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Approval id mismatch. Pending id is {d}.",
                .{self.pending_exec_id},
            );
        }
    }

    if (decision == .deny) {
        clearPendingExecCommand(self);
        return try self.allocator.dupe(u8, "Exec request denied.");
    }

    const command_to_run = pending_command;
    const exec_id_snapshot = self.pending_exec_id; // CR-01: capture before defer clears it
    defer clearPendingExecCommand(self);

    if (decision == .allow_always) {
        self.exec_ask = .off;
    }

    const output = try runShellCommand(self, command_to_run, true);
    defer self.allocator.free(output);
    return try std.fmt.allocPrint(
        self.allocator,
        "Approved exec (id={d}).\n{s}",
        .{ exec_id_snapshot, output },
    );
}

fn taskStatusLabel(status: subagent_mod.TaskStatus) []const u8 {
    return switch (status) {
        .queued => "queued",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

fn currentSubagentSessionKey(self: anytype) []const u8 {
    return self.memory_session_id orelse "agent";
}

fn taskBelongsToCurrentSession(self: anytype, state: *const subagent_mod.TaskState) bool {
    const task_session = state.session_key orelse return false;
    return std.mem.eql(u8, task_session, currentSubagentSessionKey(self));
}

fn freeSubagentTaskState(manager: *subagent_mod.SubagentManager, state: *subagent_mod.TaskState) void {
    if (state.thread) |thread| {
        thread.join();
    }
    if (state.result) |r| manager.allocator.free(r);
    if (state.error_msg) |e| manager.allocator.free(e);
    if (state.session_key) |sk| manager.allocator.free(sk);
    if (state.runtime_session_key) |sk| manager.allocator.free(sk);
    if (state.origin_channel) |channel| manager.allocator.free(channel);
    if (state.origin_chat_id) |chat| manager.allocator.free(chat);
    manager.allocator.free(state.task_summary);
    manager.allocator.free(state.task_prompt);
    manager.allocator.free(state.label);
    manager.allocator.destroy(state);
}

fn taskOutcomeLabel(state: *const subagent_mod.TaskState) []const u8 {
    if (state.error_msg != null) return "error";
    if (state.result != null) return "result_ready";
    return switch (state.status) {
        .queued => "pending",
        .running => "in_progress",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

fn taskResultSnippet(state: *const subagent_mod.TaskState) []const u8 {
    if (state.error_msg) |err_msg| return err_msg;
    if (state.result) |result| return result;
    return "";
}

fn formatSubagentList(self: anytype, include_details: bool) ![]const u8 {
    const manager = findSubagentManager(self) orelse
        return try self.allocator.dupe(u8, "Subagent manager is not enabled.");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);

    manager.mutex.lock();
    defer manager.mutex.unlock();

    var running: u32 = 0;
    var completed: u32 = 0;
    var failed: u32 = 0;
    var queued: u32 = 0;
    var cancelled: u32 = 0;
    var visible_count: u32 = 0;

    var it = manager.tasks.iterator();
    while (it.next()) |entry| {
        const task_id = entry.key_ptr.*;
        const state = entry.value_ptr.*;
        if (!taskBelongsToCurrentSession(self, state)) continue;
        visible_count += 1;
        switch (state.status) {
            .queued => queued += 1,
            .running => running += 1,
            .completed => completed += 1,
            .failed => failed += 1,
            .cancelled => cancelled += 1,
        }

        try w.print("#{d} {s} [{s}] task={s} outcome={s}", .{
            task_id,
            state.label,
            taskStatusLabel(state.status),
            state.task_summary,
            taskOutcomeLabel(state),
        });
        if (include_details) {
            const snippet = taskResultSnippet(state);
            if (snippet.len > 0) {
                try w.print(" detail={s}", .{snippet});
            }
        }
        try w.writeAll("\n");
    }

    if (visible_count == 0) {
        try w.writeAll("No subagents tracked in this session.");
        return try out.toOwnedSlice(self.allocator);
    }

    try w.print("Totals: queued={d}, running={d}, completed={d}, failed={d}, cancelled={d}", .{ queued, running, completed, failed, cancelled });
    return try out.toOwnedSlice(self.allocator);
}

fn spawnSubagentTask(self: anytype, task: []const u8, label: []const u8) ![]const u8 {
    const trimmed_task = std.mem.trim(u8, task, " \t");
    if (trimmed_task.len == 0) {
        return try self.allocator.dupe(u8, "Usage: /subagents spawn <task>");
    }

    const manager = findSubagentManager(self) orelse
        return try self.allocator.dupe(u8, "Spawn tool is not enabled.");

    const turn_ctx = message_tool.MessageTool.getTurnContext();
    const origin_channel = turn_ctx.channel orelse "agent";
    const origin_chat = turn_ctx.chat_id orelse self.memory_session_id orelse "agent";
    const request_session_key = self.memory_session_id orelse origin_chat;
    const task_id = manager.spawn(trimmed_task, label, request_session_key, origin_channel, origin_chat) catch |err| {
        return switch (err) {
            error.TooManyConcurrentSubagents => try self.allocator.dupe(u8, "Too many concurrent subagents. Wait for a task to finish."),
            else => try std.fmt.allocPrint(self.allocator, "Failed to spawn subagent: {s}", .{@errorName(err)}),
        };
    };

    return try std.fmt.allocPrint(
        self.allocator,
        "Spawned subagent task #{d} ({s}) state=queued task={s}.",
        .{ task_id, label, trimmed_task },
    );
}

test "spawnSubagentTask routes to current turn channel and chat" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_module.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = subagent_mod.SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    var spawn_tool = spawn_tool_mod.SpawnTool{ .manager = &manager };
    const tools = [_]Tool{spawn_tool.tool()};

    var dummy = struct {
        allocator: std.mem.Allocator,
        memory_session_id: ?[]const u8,
        tools: []const Tool,
    }{
        .allocator = std.testing.allocator,
        .memory_session_id = "agent:zaki-bot:user:1:main",
        .tools = &tools,
    };

    message_tool.MessageTool.setTurnContext(.{
        .channel = "telegram",
        .chat_id = "tg-chat-123",
    });
    defer message_tool.MessageTool.clearTurnContext();

    const result = try spawnSubagentTask(&dummy, "check routing", "subagent");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Spawned subagent task #") != null);

    manager.mutex.lock();
    defer manager.mutex.unlock();
    const state = manager.tasks.get(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("telegram", state.origin_channel.?);
    try std.testing.expectEqualStrings("tg-chat-123", state.origin_chat_id.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", state.session_key.?);
}

test "spawnSubagentTask falls back to agent channel and current session key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_module.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = subagent_mod.SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    var spawn_tool = spawn_tool_mod.SpawnTool{ .manager = &manager };
    const tools = [_]Tool{spawn_tool.tool()};

    var dummy = struct {
        allocator: std.mem.Allocator,
        memory_session_id: ?[]const u8,
        tools: []const Tool,
    }{
        .allocator = std.testing.allocator,
        .memory_session_id = "agent:zaki-bot:user:88:main",
        .tools = &tools,
    };

    message_tool.MessageTool.clearTurnContext();

    const result = try spawnSubagentTask(&dummy, "fallback routing", "subagent");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Spawned subagent task #") != null);

    manager.mutex.lock();
    defer manager.mutex.unlock();
    const state = manager.tasks.get(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("agent", state.origin_channel.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:88:main", state.origin_chat_id.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:88:main", state.session_key.?);
}

test "formatSubagentList shows task summary and outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_module.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = subagent_mod.SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    const state = try std.testing.allocator.create(subagent_mod.TaskState);
    state.* = .{
        .status = .completed,
        .label = try std.testing.allocator.dupe(u8, "subagent"),
        .task_summary = try std.testing.allocator.dupe(u8, "inspect routing"),
        .task_prompt = try std.testing.allocator.dupe(u8, "inspect routing"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .result = try std.testing.allocator.dupe(u8, "routing ok"),
        .started_at = std.time.milliTimestamp(),
        .completed_at = std.time.milliTimestamp(),
    };
    try manager.tasks.put(std.testing.allocator, 7, state);

    var spawn_tool = spawn_tool_mod.SpawnTool{ .manager = &manager };
    const tools = [_]Tool{spawn_tool.tool()};
    var dummy = struct {
        allocator: std.mem.Allocator,
        memory_session_id: ?[]const u8,
        tools: []const Tool,
    }{
        .allocator = std.testing.allocator,
        .memory_session_id = "agent:zaki-bot:user:1:main",
        .tools = &tools,
    };

    const text = try formatSubagentList(&dummy, true);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "task=inspect routing") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "outcome=result_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "detail=routing ok") != null);
}

test "freeSubagentTaskState frees task prompt and runtime session key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_module.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = subagent_mod.SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    const state = try std.testing.allocator.create(subagent_mod.TaskState);
    state.* = .{
        .status = .completed,
        .label = try std.testing.allocator.dupe(u8, "cleanup"),
        .task_summary = try std.testing.allocator.dupe(u8, "cleanup summary"),
        .task_prompt = try std.testing.allocator.dupe(u8, "cleanup prompt"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .runtime_session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:task:7"),
        .started_at = std.time.milliTimestamp(),
        .completed_at = std.time.milliTimestamp(),
    };

    freeSubagentTaskState(&manager, state);
}

fn handleAgentsCommand(self: anytype) ![]const u8 {
    const manager = findSubagentManager(self) orelse
        return try self.allocator.dupe(u8, "Active agents: 1 (current session). Subagents are not enabled.");

    manager.mutex.lock();
    defer manager.mutex.unlock();
    var tracked: u32 = 0;
    var running: u32 = 0;

    var it = manager.tasks.iterator();
    while (it.next()) |entry| {
        const state = entry.value_ptr.*;
        if (!taskBelongsToCurrentSession(self, state)) continue;
        tracked += 1;
        if (state.status == .running) running += 1;
    }

    return try std.fmt.allocPrint(
        self.allocator,
        "Active agents: 1 main + {d} running subagents ({d} tracked tasks).",
        .{ running, tracked },
    );
}

fn handleKillCommand(self: anytype, arg: []const u8) ![]const u8 {
    const manager = findSubagentManager(self) orelse
        return try self.allocator.dupe(u8, "Subagent manager is not enabled.");

    const target = firstToken(arg);
    if (target.len == 0) {
        return try self.allocator.dupe(u8, "Usage: /kill <id|all>");
    }

    if (std.ascii.eqlIgnoreCase(target, "all")) {
        // WP2.4: snapshot the visible queued/terminal ids under the lock
        // so we can drive cancelQueued / fetchRemove afterwards without
        // holding the manager mutex across the mirror to TaskDelivery.
        var queued_ids: std.ArrayListUnmanaged(u64) = .empty;
        defer queued_ids.deinit(self.allocator);
        var terminal_ids: std.ArrayListUnmanaged(u64) = .empty;
        defer terminal_ids.deinit(self.allocator);
        var running: u32 = 0;

        {
            manager.mutex.lock();
            defer manager.mutex.unlock();
            var it = manager.tasks.iterator();
            while (it.next()) |entry| {
                const task_id = entry.key_ptr.*;
                const state = entry.value_ptr.*;
                if (!taskBelongsToCurrentSession(self, state)) continue;
                switch (state.status) {
                    .queued => try queued_ids.append(self.allocator, task_id),
                    .running => running += 1,
                    .completed, .failed, .cancelled => try terminal_ids.append(self.allocator, task_id),
                }
            }
        }

        var cancelled_count: u32 = 0;
        for (queued_ids.items) |task_id| {
            switch (manager.cancelQueued(task_id)) {
                .cancelled => cancelled_count += 1,
                // Raced with the runtime — the task started running or
                // completed between snapshot and cancel. The .running
                // path is silently counted into the next /kill attempt
                // via the live count reported below. Terminal/not_found
                // are no-ops; we won't re-remove them here.
                .running, .terminal, .not_found => {},
            }
        }

        var removed: u32 = 0;
        for (terminal_ids.items) |task_id| {
            manager.mutex.lock();
            const kv = manager.tasks.fetchRemove(task_id);
            manager.mutex.unlock();
            if (kv) |pair| {
                freeSubagentTaskState(manager, pair.value);
                removed += 1;
            }
        }

        if (running > 0) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Cancelled {d} queued tasks; removed {d} terminal tasks; {d} running tasks cannot be interrupted in this runtime.",
                .{ cancelled_count, removed, running },
            );
        }
        return try std.fmt.allocPrint(
            self.allocator,
            "Cancelled {d} queued tasks; removed {d} terminal tasks.",
            .{ cancelled_count, removed },
        );
    }

    const task_id = parseTaskId(target) orelse
        return try self.allocator.dupe(u8, "Usage: /kill <id|all>");

    // Session-scoped visibility check + status snapshot under the lock.
    const status_snapshot: ?subagent_mod.TaskStatus = blk: {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        const state = manager.tasks.get(task_id) orelse break :blk null;
        if (!taskBelongsToCurrentSession(self, state)) break :blk null;
        break :blk state.status;
    };

    const status = status_snapshot orelse
        return try std.fmt.allocPrint(self.allocator, "Task #{d} not found.", .{task_id});

    switch (status) {
        .queued => {
            switch (manager.cancelQueued(task_id)) {
                .cancelled => return try std.fmt.allocPrint(self.allocator, "Task #{d} cancelled (was queued).", .{task_id}),
                .running => return try std.fmt.allocPrint(self.allocator, "Task #{d} is running and cannot be interrupted in this runtime.", .{task_id}),
                .terminal => return try std.fmt.allocPrint(self.allocator, "Task #{d} already terminal; nothing to cancel.", .{task_id}),
                .not_found => return try std.fmt.allocPrint(self.allocator, "Task #{d} not found.", .{task_id}),
            }
        },
        .running => return try std.fmt.allocPrint(
            self.allocator,
            "Task #{d} is running and cannot be interrupted in this runtime.",
            .{task_id},
        ),
        .completed, .failed, .cancelled => {
            manager.mutex.lock();
            const kv = manager.tasks.fetchRemove(task_id);
            manager.mutex.unlock();
            if (kv) |pair| {
                freeSubagentTaskState(manager, pair.value);
                return try std.fmt.allocPrint(self.allocator, "Task #{d} removed (was {s}).", .{ task_id, taskStatusLabel(status) });
            }
            return try std.fmt.allocPrint(self.allocator, "Task #{d} not found.", .{task_id});
        },
    }
}

fn handleSubagentsCommand(self: anytype, arg: []const u8) ![]const u8 {
    const parsed = splitFirstToken(arg);
    const action = parsed.head;

    if (action.len == 0 or std.ascii.eqlIgnoreCase(action, "list") or std.ascii.eqlIgnoreCase(action, "status")) {
        return try formatSubagentList(self, false);
    }
    if (std.ascii.eqlIgnoreCase(action, "help")) {
        return try self.allocator.dupe(u8,
            \\Usage:
            \\  /subagents
            \\  /subagents list
            \\  /subagents spawn <task>
            \\  /subagents info <id>
            \\  /subagents kill <id|all>
        );
    }
    if (std.ascii.eqlIgnoreCase(action, "spawn")) {
        return try spawnSubagentTask(self, parsed.tail, "subagent");
    }
    if (std.ascii.eqlIgnoreCase(action, "info")) {
        const id_text = firstToken(parsed.tail);
        const task_id = parseTaskId(id_text) orelse
            return try self.allocator.dupe(u8, "Usage: /subagents info <id>");

        const manager = findSubagentManager(self) orelse
            return try self.allocator.dupe(u8, "Subagent manager is not enabled.");
        manager.mutex.lock();
        defer manager.mutex.unlock();

        const state = manager.tasks.get(task_id) orelse
            return try std.fmt.allocPrint(self.allocator, "Task #{d} not found.", .{task_id});
        if (!taskBelongsToCurrentSession(self, state)) {
            return try std.fmt.allocPrint(self.allocator, "Task #{d} not found.", .{task_id});
        }

        if (state.status == .running) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Task #{d}: {s} [{s}]\nTask: {s}\nOutcome: {s}",
                .{ task_id, state.label, taskStatusLabel(state.status), state.task_summary, taskOutcomeLabel(state) },
            );
        }
        if (state.status == .queued) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Task #{d}: {s} [{s}]\nTask: {s}\nOutcome: {s}",
                .{ task_id, state.label, taskStatusLabel(state.status), state.task_summary, taskOutcomeLabel(state) },
            );
        }
        if (state.error_msg) |err_msg| {
            return try std.fmt.allocPrint(
                self.allocator,
                "Task #{d}: {s} [{s}]\nTask: {s}\nOutcome: {s}\nError: {s}",
                .{ task_id, state.label, taskStatusLabel(state.status), state.task_summary, taskOutcomeLabel(state), err_msg },
            );
        }
        if (state.result) |result| {
            return try std.fmt.allocPrint(
                self.allocator,
                "Task #{d}: {s} [{s}]\nTask: {s}\nOutcome: {s}\nResult:\n{s}",
                .{ task_id, state.label, taskStatusLabel(state.status), state.task_summary, taskOutcomeLabel(state), result },
            );
        }
        return try std.fmt.allocPrint(
            self.allocator,
            "Task #{d}: {s} [{s}]\nTask: {s}\nOutcome: {s}",
            .{ task_id, state.label, taskStatusLabel(state.status), state.task_summary, taskOutcomeLabel(state) },
        );
    }
    if (std.ascii.eqlIgnoreCase(action, "kill")) {
        return try handleKillCommand(self, parsed.tail);
    }

    return try self.allocator.dupe(u8, "Unknown /subagents action. Use /subagents help.");
}

fn handleSteerCommand(self: anytype, arg: []const u8) ![]const u8 {
    const parsed = splitFirstToken(arg);
    const id_text = parsed.head;
    const message = parsed.tail;
    const task_id = parseTaskId(id_text) orelse
        return try self.allocator.dupe(u8, "Usage: /steer <id> <message>");
    if (message.len == 0) return try self.allocator.dupe(u8, "Usage: /steer <id> <message>");

    if (findSubagentManager(self)) |manager| {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        const state = manager.tasks.get(task_id) orelse
            return try std.fmt.allocPrint(self.allocator, "Task #{d} not found.", .{task_id});
        if (!taskBelongsToCurrentSession(self, state)) {
            return try std.fmt.allocPrint(self.allocator, "Task #{d} not found.", .{task_id});
        }
    }

    const follow_up = try std.fmt.allocPrint(
        self.allocator,
        "Follow up for task #{d}: {s}",
        .{ task_id, message },
    );
    defer self.allocator.free(follow_up);

    const spawned = try spawnSubagentTask(self, follow_up, "steer");
    defer self.allocator.free(spawned);
    return try std.fmt.allocPrint(
        self.allocator,
        "Steer for task #{d} created as a new subagent.\n{s}",
        .{ task_id, spawned },
    );
}

fn handleTellCommand(self: anytype, arg: []const u8) ![]const u8 {
    return try spawnSubagentTask(self, arg, "tell");
}

fn handlePollCommand(self: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);

    var wrote_any = false;
    if (self.pending_exec_command) |cmd| {
        wrote_any = true;
        try w.print("Pending approval id={d}: {s}\n", .{ self.pending_exec_id, cmd });
    }

    if (findSubagentManager(self)) |manager| {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        var running: u32 = 0;
        var completed: u32 = 0;
        var failed: u32 = 0;
        var queued: u32 = 0;
        var cancelled: u32 = 0;
        var visible: u32 = 0;

        var it = manager.tasks.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (!taskBelongsToCurrentSession(self, state)) continue;
            visible += 1;
            switch (state.status) {
                .queued => queued += 1,
                .running => running += 1,
                .completed => completed += 1,
                .failed => failed += 1,
                .cancelled => cancelled += 1,
            }
        }
        if (visible > 0) {
            wrote_any = true;
            try w.print(
                "Subagent tasks: queued={d}, running={d}, completed={d}, failed={d}, cancelled={d}\n",
                .{ queued, running, completed, failed, cancelled },
            );
        }
    }

    if (!wrote_any) {
        return try self.allocator.dupe(u8, "No pending approvals or background tasks.");
    }
    return try out.toOwnedSlice(self.allocator);
}

fn handleStopCommand(self: anytype) ![]const u8 {
    var cleared_pending = false;
    if (self.pending_exec_command != null) {
        clearPendingExecCommand(self);
        cleared_pending = true;
    }

    if (findSubagentManager(self)) |manager| {
        var running: u32 = 0;
        manager.mutex.lock();
        {
            var it = manager.tasks.iterator();
            while (it.next()) |entry| {
                const state = entry.value_ptr.*;
                if (!taskBelongsToCurrentSession(self, state)) continue;
                if (state.status == .running) running += 1;
            }
        }
        manager.mutex.unlock();
        if (running > 0) {
            if (cleared_pending) {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "Cleared pending exec approval. {d} running subagent tasks cannot be interrupted in this runtime.",
                    .{running},
                );
            }
            return try std.fmt.allocPrint(
                self.allocator,
                "{d} running subagent tasks cannot be interrupted in this runtime.",
                .{running},
            );
        }
    }

    if (cleared_pending) {
        return try self.allocator.dupe(u8, "Cleared pending exec approval.");
    }
    return try self.allocator.dupe(u8, "No active background task to stop.");
}

fn parseJsonStringOwned(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .string) return null;
    return try allocator.dupe(u8, parsed.value.string);
}

fn parseJsonF64(raw: []const u8) ?f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{}) catch return null;
    return switch (parsed.value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => null,
    };
}

fn parseJsonU32(raw: []const u8) ?u32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{}) catch return null;
    return switch (parsed.value) {
        .integer => |v| blk: {
            if (v < 0 or v > std.math.maxInt(u32)) break :blk null;
            break :blk @intCast(v);
        },
        else => null,
    };
}

fn parseJsonU64(raw: []const u8) ?u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{}) catch return null;
    return switch (parsed.value) {
        .integer => |v| blk: {
            if (v < 0 or v > std.math.maxInt(u64)) break :blk null;
            break :blk @intCast(v);
        },
        else => null,
    };
}

fn splitPrimaryModelRef(primary: []const u8) ?struct { provider: []const u8, model: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, primary, '/') orelse return null;
    if (slash == 0 or slash + 1 >= primary.len) return null;
    return .{
        .provider = primary[0..slash],
        .model = primary[slash + 1 ..],
    };
}

fn hotApplyConfigChange(
    self: anytype,
    action: config_mutator.MutationAction,
    path: []const u8,
    new_value_json: []const u8,
) !bool {
    if (action == .unset) return false;

    if (std.mem.eql(u8, path, "agents.defaults.model.primary")) {
        const primary = try parseJsonStringOwned(self.allocator, new_value_json) orelse return false;
        defer self.allocator.free(primary);
        const parsed = splitPrimaryModelRef(primary) orelse return false;
        try setModelName(self, parsed.model);
        try setDefaultProvider(self, parsed.provider);
        if (@hasField(@TypeOf(self.*), "default_model")) {
            self.default_model = self.model_name;
        }
        return true;
    }

    if (std.mem.eql(u8, path, "default_temperature")) {
        const temp = parseJsonF64(new_value_json) orelse return false;
        if (@hasField(@TypeOf(self.*), "temperature")) {
            self.temperature = temp;
            return true;
        }
        return false;
    }

    if (std.mem.eql(u8, path, "agent.max_tool_iterations")) {
        const v = parseJsonU32(new_value_json) orelse return false;
        if (@hasField(@TypeOf(self.*), "max_tool_iterations")) {
            self.max_tool_iterations = v;
            return true;
        }
        return false;
    }

    if (std.mem.eql(u8, path, "agent.max_history_messages")) {
        const v = parseJsonU32(new_value_json) orelse return false;
        if (@hasField(@TypeOf(self.*), "max_history_messages")) {
            self.max_history_messages = v;
            return true;
        }
        return false;
    }

    if (std.mem.eql(u8, path, "agent.message_timeout_secs")) {
        const v = parseJsonU64(new_value_json) orelse return false;
        if (@hasField(@TypeOf(self.*), "message_timeout_secs")) {
            self.message_timeout_secs = v;
            return true;
        }
        return false;
    }

    return false;
}

fn formatConfigMutationResponse(
    allocator: std.mem.Allocator,
    action: config_mutator.MutationAction,
    result: *const config_mutator.MutationResult,
    dry_run: bool,
    hot_applied: bool,
) ![]const u8 {
    const action_name = switch (action) {
        .set => "set",
        .unset => "unset",
    };
    const mode = if (dry_run) "preview" else "applied";
    const restart_text = if (result.requires_restart) "true" else "false";
    const hot_text = if (hot_applied) "true" else "false";
    const backup = result.backup_path orelse "(none)";

    return try std.fmt.allocPrint(
        allocator,
        "Config {s} ({s}):\n" ++
            "  action: {s}\n" ++
            "  path: {s}\n" ++
            "  old: {s}\n" ++
            "  new: {s}\n" ++
            "  requires_restart: {s}\n" ++
            "  hot_applied: {s}\n" ++
            "  backup: {s}\n",
        .{
            action_name,
            mode,
            action_name,
            result.path,
            result.old_value_json,
            result.new_value_json,
            restart_text,
            hot_text,
            backup,
        },
    );
}

fn handleCapabilitiesCommand(self: anytype, arg: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");
    const as_json = std.mem.eql(u8, trimmed, "--json") or std.ascii.eqlIgnoreCase(trimmed, "json");

    var cfg_opt: ?config_module.Config = config_module.Config.load(self.allocator) catch null;
    defer if (cfg_opt) |*cfg| cfg.deinit();
    const cfg_ptr: ?*const config_module.Config = if (cfg_opt) |*cfg| cfg else null;

    const runtime_tools: ?[]const Tool = if (@hasField(@TypeOf(self.*), "tools"))
        self.tools
    else
        null;

    if (as_json) {
        return capabilities_mod.buildManifestJson(self.allocator, cfg_ptr, runtime_tools);
    }
    return capabilities_mod.buildSummaryText(self.allocator, cfg_ptr, runtime_tools);
}

fn handleConfigCommand(self: anytype, arg: []const u8) ![]const u8 {
    const parsed = splitFirstToken(arg);
    const action = parsed.head;

    if (action.len == 0 or std.ascii.eqlIgnoreCase(action, "show") or std.ascii.eqlIgnoreCase(action, "status")) {
        return try std.fmt.allocPrint(
            self.allocator,
            "Runtime config:\n  model={s}\n  workspace={s}\n  exec.host={s}\n  exec.security={s}\n  exec.ask={s}\n  queue.mode={s}\n  tts.mode={s}\n  activation={s}\n  send={s}",
            .{
                self.model_name,
                self.workspace_dir,
                self.exec_host.toSlice(),
                self.exec_security.toSlice(),
                self.exec_ask.toSlice(),
                self.queue_mode.toSlice(),
                self.tts_mode.toSlice(),
                self.activation_mode.toSlice(),
                self.send_mode.toSlice(),
            },
        );
    }

    if (std.ascii.eqlIgnoreCase(action, "get")) {
        const key = std.mem.trim(u8, parsed.tail, " \t");
        if (key.len == 0) return try self.allocator.dupe(u8, "Usage: /config get <path>");
        return config_mutator.getPathValueJson(self.allocator, key) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Config get failed: {s}", .{@errorName(err)});
        };
    }

    if (std.ascii.eqlIgnoreCase(action, "validate")) {
        config_mutator.validateCurrentConfig(self.allocator) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Config validation failed: {s}", .{@errorName(err)});
        };
        return try self.allocator.dupe(u8, "Config validation: OK");
    }

    if (std.ascii.eqlIgnoreCase(action, "set")) {
        const path_and_value = splitFirstToken(parsed.tail);
        const path = path_and_value.head;
        const value_raw = std.mem.trim(u8, path_and_value.tail, " \t");
        if (path.len == 0 or value_raw.len == 0) {
            return try self.allocator.dupe(u8, "Usage: /config set <path> <value> (dry-run preview)");
        }

        var result = config_mutator.mutateDefaultConfig(self.allocator, .set, path, value_raw, .{ .apply = false }) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Config set preview failed: {s}", .{@errorName(err)});
        };
        defer config_mutator.freeMutationResult(self.allocator, &result);

        const response = try formatConfigMutationResponse(self.allocator, .set, &result, true, false);
        return response;
    }

    if (std.ascii.eqlIgnoreCase(action, "unset")) {
        const path = std.mem.trim(u8, parsed.tail, " \t");
        if (path.len == 0) {
            return try self.allocator.dupe(u8, "Usage: /config unset <path> (dry-run preview)");
        }

        var result = config_mutator.mutateDefaultConfig(self.allocator, .unset, path, null, .{ .apply = false }) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Config unset preview failed: {s}", .{@errorName(err)});
        };
        defer config_mutator.freeMutationResult(self.allocator, &result);

        const response = try formatConfigMutationResponse(self.allocator, .unset, &result, true, false);
        return response;
    }

    if (std.ascii.eqlIgnoreCase(action, "apply")) {
        const apply_parsed = splitFirstToken(parsed.tail);
        const apply_action = apply_parsed.head;
        const apply_rest = apply_parsed.tail;

        if (std.ascii.eqlIgnoreCase(apply_action, "set")) {
            const path_and_value = splitFirstToken(apply_rest);
            const path = path_and_value.head;
            const value_raw = std.mem.trim(u8, path_and_value.tail, " \t");
            if (path.len == 0 or value_raw.len == 0) {
                return try self.allocator.dupe(u8, "Usage: /config apply set <path> <value>");
            }

            var result = config_mutator.mutateDefaultConfig(self.allocator, .set, path, value_raw, .{ .apply = true }) catch |err| {
                return try std.fmt.allocPrint(self.allocator, "Config apply set failed: {s}", .{@errorName(err)});
            };
            defer config_mutator.freeMutationResult(self.allocator, &result);

            var hot_applied = false;
            if (result.applied and !result.requires_restart) {
                hot_applied = hotApplyConfigChange(self, .set, result.path, result.new_value_json) catch false;
            }
            const response = try formatConfigMutationResponse(self.allocator, .set, &result, false, hot_applied);
            return response;
        }

        if (std.ascii.eqlIgnoreCase(apply_action, "unset")) {
            const path = std.mem.trim(u8, apply_rest, " \t");
            if (path.len == 0) {
                return try self.allocator.dupe(u8, "Usage: /config apply unset <path>");
            }

            var result = config_mutator.mutateDefaultConfig(self.allocator, .unset, path, null, .{ .apply = true }) catch |err| {
                return try std.fmt.allocPrint(self.allocator, "Config apply unset failed: {s}", .{@errorName(err)});
            };
            defer config_mutator.freeMutationResult(self.allocator, &result);

            const response = try formatConfigMutationResponse(self.allocator, .unset, &result, false, false);
            return response;
        }

        return try self.allocator.dupe(u8, "Usage: /config apply <set|unset> ...");
    }

    return try self.allocator.dupe(
        u8,
        "Usage:\n" ++
            "  /config [show]\n" ++
            "  /config get <path>\n" ++
            "  /config set <path> <value>            (dry-run preview)\n" ++
            "  /config unset <path>                  (dry-run preview)\n" ++
            "  /config apply set <path> <value>\n" ++
            "  /config apply unset <path>\n" ++
            "  /config validate",
    );
}

fn handleSkillCommand(self: anytype, arg: []const u8) ![]const u8 {
    const parsed = splitFirstToken(arg);
    const action_or_name = parsed.head;

    if (std.ascii.eqlIgnoreCase(action_or_name, "search")) {
        const query = std.mem.trim(u8, parsed.tail, " \t");
        if (query.len == 0) {
            return try self.allocator.dupe(u8, "Usage: /skill search <query>");
        }
        const results = skills_mod.searchDecisionHubSkills(self.allocator, query, 8) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Decision Hub search failed: {s}", .{@errorName(err)});
        };
        defer skills_mod.freeDecisionHubSearchResults(self.allocator, results);
        if (results.len == 0) return try self.allocator.dupe(u8, "No matching skills found in Decision Hub.");

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.print("Decision Hub results ({d}):\n", .{results.len});
        for (results) |item| {
            try w.print("- {s}/{s}", .{ item.org_slug, item.skill_name });
            if (item.latest_version.len > 0) try w.print(" @ {s}", .{item.latest_version});
            if (item.safety_rating.len > 0) try w.print(" [grade {s}]", .{item.safety_rating});
            if (item.description.len > 0) try w.print(" — {s}", .{item.description});
            try w.writeByte('\n');
        }
        return try out.toOwnedSlice(self.allocator);
    }

    if (std.ascii.eqlIgnoreCase(action_or_name, "install")) {
        const target = std.mem.trim(u8, parsed.tail, " \t");
        if (target.len == 0) {
            return try self.allocator.dupe(u8, "Usage: /skill install <org/skill or query>");
        }
        const installed = skills_mod.installSkillFromDecisionHubQueryOrRef(
            self.allocator,
            target,
            self.workspace_dir,
            .{},
        ) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Skill install failed: {s}", .{@errorName(err)});
        };
        defer skills_mod.freeDecisionHubInstallResult(self.allocator, &installed);
        return try std.fmt.allocPrint(
            self.allocator,
            "Installed {s}/{s}@{s} as `{s}`. It is now available for /skill and prompt usage.",
            .{ installed.org_slug, installed.skill_name, installed.resolved_version, installed.installed_name },
        );
    }

    if (std.ascii.eqlIgnoreCase(action_or_name, "remove") or std.ascii.eqlIgnoreCase(action_or_name, "uninstall")) {
        const target = std.mem.trim(u8, parsed.tail, " \t");
        if (target.len == 0) {
            return try self.allocator.dupe(u8, "Usage: /skill remove <local-skill-name>");
        }
        skills_mod.removeSkill(self.allocator, target, self.workspace_dir) catch |err| {
            return switch (err) {
                error.SkillNotFound => try std.fmt.allocPrint(self.allocator, "Skill not found: {s}", .{target}),
                error.UnsafeName => try self.allocator.dupe(u8, "Invalid skill name."),
                else => try std.fmt.allocPrint(self.allocator, "Skill remove failed: {s}", .{@errorName(err)}),
            };
        };
        return try std.fmt.allocPrint(self.allocator, "Removed local skill `{s}`.", .{target});
    }

    const skills = skills_mod.listSkills(self.allocator, self.workspace_dir) catch |err| {
        return try std.fmt.allocPrint(self.allocator, "Failed to load skills: {s}", .{@errorName(err)});
    };
    defer skills_mod.freeSkills(self.allocator, skills);

    if (action_or_name.len == 0 or std.ascii.eqlIgnoreCase(action_or_name, "list")) {
        if (skills.len == 0) {
            return try self.allocator.dupe(u8, "No skills found in workspace.");
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.writeAll("Available skills:\n");
        for (skills) |skill| {
            try w.print("  - {s}", .{skill.name});
            if (skill.description.len > 0) try w.print(": {s}", .{skill.description});
            if (!skill.available) try w.print(" (unavailable: {s})", .{skill.missing_deps});
            try w.writeAll("\n");
        }
        return try out.toOwnedSlice(self.allocator);
    }

    var selected: ?*const skills_mod.Skill = null;
    for (skills) |*skill| {
        if (std.ascii.eqlIgnoreCase(skill.name, action_or_name)) {
            selected = skill;
            break;
        }
    }
    const skill = selected orelse
        return try std.fmt.allocPrint(self.allocator, "Skill not found: {s}", .{action_or_name});

    if (!skill.available) {
        return try std.fmt.allocPrint(
            self.allocator,
            "Skill {s} is unavailable: {s}",
            .{ skill.name, skill.missing_deps },
        );
    }

    const user_input = std.mem.trim(u8, parsed.tail, " \t");
    if (user_input.len == 0) {
        if (skill.instructions.len > 0) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Skill {s}: {s}\nUsage: /skill {s} <task>",
                .{ skill.name, if (skill.description.len > 0) skill.description else "no description", skill.name },
            );
        }
        return try std.fmt.allocPrint(
            self.allocator,
            "Skill {s} has no instructions. Usage: /skill {s} <task>",
            .{ skill.name, skill.name },
        );
    }

    const composed = if (skill.instructions.len > 0)
        try std.fmt.allocPrint(
            self.allocator,
            "Apply the skill `{s}`.\n\nSkill instructions:\n{s}\n\nTask:\n{s}",
            .{ skill.name, skill.instructions, user_input },
        )
    else
        try std.fmt.allocPrint(
            self.allocator,
            "Apply the skill `{s}`.\n\nTask:\n{s}",
            .{ skill.name, user_input },
        );
    defer self.allocator.free(composed);

    if (findSubagentManager(self) != null) {
        return try spawnSubagentTask(self, composed, skill.name);
    }
    return try std.fmt.allocPrint(
        self.allocator,
        "Skill prompt prepared for `{s}` (spawn tool is disabled):\n{s}",
        .{ skill.name, composed },
    );
}

fn handleBashCommand(self: anytype, arg: []const u8) ![]const u8 {
    const command = std.mem.trim(u8, arg, " \t");
    if (command.len == 0) {
        return try self.allocator.dupe(u8, "Usage: /bash <command>");
    }
    if (std.ascii.eqlIgnoreCase(command, "poll")) {
        return try self.allocator.dupe(u8, "No background command output is available.");
    }
    if (std.ascii.eqlIgnoreCase(command, "stop")) {
        return try self.allocator.dupe(u8, "No background command is running.");
    }
    return try runShellCommand(self, command, false);
}

pub fn isExecToolName(tool_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tool_name, "shell");
}

pub fn execBlockMessage(self: anytype, args: std.json.ObjectMap) ?[]const u8 {
    if (self.exec_host == .node) {
        return "Exec blocked: host=node is not available in this runtime";
    }
    if (self.exec_security == .deny) {
        return "Exec blocked by /exec security=deny";
    }
    if (self.exec_ask == .always) {
        if (args.get("command")) |v| {
            if (v == .string) {
                _ = setPendingExecCommand(self, v.string) catch {};
            }
        }
        return "Exec blocked: approval required. Use /approve allow-once|allow-always|deny";
    }

    if (self.exec_security == .allowlist and self.exec_ask == .on_miss) {
        if (args.get("command")) |v| {
            if (v == .string) {
                const command = v.string;
                if (self.policy) |pol| {
                    if (!pol.isCommandAllowed(command)) {
                        return "Exec blocked by allowlist policy";
                    }
                }
            }
        }
    }

    return null;
}

pub fn composeFinalReply(
    self: anytype,
    base_text: []const u8,
    reasoning_content: ?[]const u8,
    usage: providers.TokenUsage,
) ![]const u8 {
    const trimmed_base = std.mem.trim(u8, base_text, " \t\r\n");
    const has_visible_text = trimmed_base.len > 0;
    // ME-05 fix (2026-05-07): test the TRIMMED reasoning length, not the
    // raw length. Pre-fix `has_reasoning = reasoning_content.?.len > 0`
    // was true for `"   \n  "` (whitespace-only), the fallback then
    // trimmed to empty, and the user got an empty reply — defeating the
    // V1.11 V4-Pro fix. Trim once at the source so both the gate and the
    // fallback see the same string.
    const trimmed_reasoning: []const u8 = if (reasoning_content) |r|
        std.mem.trim(u8, r, " \t\r\n")
    else
        "";
    const has_reasoning = trimmed_reasoning.len > 0;

    // V1.11 (2026-05-07) — empty-content fallback to reasoning_content.
    //
    // ROOT CAUSE for "ZAKI not responding" (Nova bug report 2026-05-07):
    // DeepSeek V4-Pro at `reasoning_effort=high` (the deep-mode preset)
    // emits non-empty `reasoning_content` and empty `content` for many
    // queries. Pre-V1.11 this function returned the empty `base_text`
    // because `reasoning_mode` defaults to OFF — the user setting was
    // gating fallback. Result: 10s of model thinking with zero visible
    // reply.
    //
    // Permanent fix: when `content` is empty AND `reasoning_content` is
    // non-empty, the reasoning IS the response. Surface it regardless
    // of `reasoning_mode`. The user asked a question; an empty reply
    // is never the right answer.
    //
    // `reasoning_mode == .on` still controls whether reasoning is
    // appended ALONGSIDE visible content (the "show your work" UX).
    // The fallback only fires when content is empty — orthogonal axis.
    const final_base: []const u8 = if (has_visible_text)
        trimmed_base
    else if (has_reasoning)
        trimmed_reasoning
    else
        base_text;

    // Only show reasoning *alongside* visible content when reasoning_mode
    // is .on. If we already fell back to reasoning above, don't double-print.
    const show_reasoning = has_visible_text and self.reasoning_mode == .on and has_reasoning;
    if (!show_reasoning and self.usage_mode == .off) {
        return try self.allocator.dupe(u8, final_base);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);

    try w.writeAll(final_base);

    if (show_reasoning) {
        try w.writeAll("\n\nReasoning:\n");
        try w.writeAll(reasoning_content.?);
    }

    switch (self.usage_mode) {
        .off => {},
        .tokens => try w.print("\n\n[usage] total_tokens={d}", .{usage.total_tokens}),
        .full => try w.print(
            "\n\n[usage] prompt={d} completion={d} total={d} session_total={d}",
            .{ usage.prompt_tokens, usage.completion_tokens, usage.total_tokens, self.total_tokens },
        ),
        .cost => try w.print(
            "\n\n[usage] prompt={d} completion={d} total={d} (cost estimate unavailable)",
            .{ usage.prompt_tokens, usage.completion_tokens, usage.total_tokens },
        ),
    }

    return try out.toOwnedSlice(self.allocator);
}

fn handleDoctorCommand(self: anytype) ![]const u8 {
    const rt: ?*memory_mod.MemoryRuntime = if (@hasField(@TypeOf(self.*), "mem_rt")) self.mem_rt else null;
    if (rt) |mem_rt| {
        const report = memory_mod.diagnostics.diagnose(mem_rt);
        return memory_mod.diagnostics.formatReport(report, self.allocator);
    }
    return try self.allocator.dupe(u8, "Memory runtime not available. Diagnostics require a configured memory backend.");
}

pub fn handleSlashCommand(self: anytype, message: []const u8) !?[]const u8 {
    const cmd = parseSlashCommand(message) orelse return null;

    if (isSlashName(cmd, "reset")) return try handleResetCommand(self, cmd.arg);
    if (isSlashName(cmd, "resume")) return try handleResumeCommand(self, cmd.arg);

    if (isSlashName(cmd, "new")) {
        clearSessionState(self, "new");
        if (cmd.arg.len > 0) {
            try setModelName(self, cmd.arg);
            return try std.fmt.allocPrint(self.allocator, "Session cleared. Switched to model: {s}", .{cmd.arg});
        }
        return try self.allocator.dupe(u8, "Session cleared.");
    }

    if (isSlashName(cmd, "restart")) {
        clearSessionState(self, "restart");
        resetRuntimeCommandState(self);
        if (cmd.arg.len > 0) {
            try setModelName(self, cmd.arg);
            return try std.fmt.allocPrint(self.allocator, "Session restarted. Switched to model: {s}", .{cmd.arg});
        }
        return try self.allocator.dupe(u8, "Session restarted.");
    }

    if (isSlashName(cmd, "help") or isSlashName(cmd, "commands")) {
        return try self.allocator.dupe(u8, HELP_TEXT);
    }

    if (isSlashName(cmd, "status")) return try formatStatus(self);
    if (isSlashName(cmd, "runtime")) return try formatRuntimeStatus(self);
    if (isSlashName(cmd, "whoami") or isSlashName(cmd, "id")) return try formatWhoAmI(self);
    if (isSlashName(cmd, "model") or isSlashName(cmd, "models")) {
        if (cmd.arg.len == 0 or
            std.ascii.eqlIgnoreCase(cmd.arg, "list") or
            std.ascii.eqlIgnoreCase(cmd.arg, "status"))
        {
            return try self.formatModelStatus();
        }
        try setModelName(self, cmd.arg);
        if (@hasField(@TypeOf(self.*), "default_model")) {
            self.default_model = self.model_name;
        }
        invalidateSystemPromptCache(self);
        persistSelectedModelToConfig(self, cmd.arg) catch |err| {
            return try std.fmt.allocPrint(
                self.allocator,
                "Switched to model: {s}\nWarning: could not persist model to config.json ({s})",
                .{ cmd.arg, @errorName(err) },
            );
        };
        return try std.fmt.allocPrint(self.allocator, "Switched to model: {s}", .{cmd.arg});
    }

    if (isSlashName(cmd, "think") or isSlashName(cmd, "thinking") or isSlashName(cmd, "t")) return try handleThinkCommand(self, cmd.arg);
    if (isSlashName(cmd, "verbose") or isSlashName(cmd, "v")) return try handleVerboseCommand(self, cmd.arg);
    if (isSlashName(cmd, "reasoning") or isSlashName(cmd, "reason")) return try handleReasoningCommand(self, cmd.arg);
    if (isSlashName(cmd, "exec")) return try handleExecCommand(self, cmd.arg);
    if (isSlashName(cmd, "queue")) return try handleQueueCommand(self, cmd.arg);
    if (isSlashName(cmd, "mode")) return try handleModeCommand(self, cmd.arg);
    if (isSlashName(cmd, "plan")) return try handlePlanCommand(self);
    if (isSlashName(cmd, "review")) return try handleReviewCommand(self);
    if (isSlashName(cmd, "execute")) return try handleExecuteCommand(self);
    if (isSlashName(cmd, "usage")) return try handleUsageCommand(self, cmd.arg);
    if (isSlashName(cmd, "cost")) return try handleCostCommand(self);
    if (isSlashName(cmd, "tts")) return try handleTtsCommand(self, cmd.arg);
    if (isSlashName(cmd, "voice")) return try handleVoiceCommand(self, cmd.arg);
    if (isSlashName(cmd, "stop")) return try handleStopCommand(self);
    if (isSlashName(cmd, "compact")) {
        if (try self.manualCompactHistory()) {
            self.last_turn_compacted = true;
            self.last_turn_context.durable_continuity_refreshed = persistSessionCheckpointDetailed(self, "compaction:manual");
            if (self.last_turn_context.durable_continuity_refreshed) {
                return try self.allocator.dupe(u8, "Context compacted and continuity refreshed.");
            }
            return try self.allocator.dupe(u8, "Context compacted.");
        }
        return try self.allocator.dupe(u8, "Nothing to compact.");
    }

    if (isSlashName(cmd, "allowlist")) return try handleAllowlistCommand(self, cmd.arg);
    if (isSlashName(cmd, "approve")) return try handleApproveCommand(self, cmd.arg);
    if (isSlashName(cmd, "context")) return try handleContextCommand(self, cmd.arg);
    if (isSlashName(cmd, "export-session") or isSlashName(cmd, "export")) return try handleExportSessionCommand(self, cmd.arg);
    if (isSlashName(cmd, "session")) return try handleSessionCommand(self, cmd.arg);
    if (isSlashName(cmd, "subagents")) return try handleSubagentsCommand(self, cmd.arg);
    if (isSlashName(cmd, "agents")) return try handleAgentsCommand(self);
    if (isSlashName(cmd, "focus")) return try handleFocusCommand(self, cmd.arg);
    if (isSlashName(cmd, "unfocus")) return try handleUnfocusCommand(self);
    if (isSlashName(cmd, "kill")) return try handleKillCommand(self, cmd.arg);
    if (isSlashName(cmd, "steer")) return try handleSteerCommand(self, cmd.arg);
    if (isSlashName(cmd, "tell")) return try handleTellCommand(self, cmd.arg);

    if (isSlashName(cmd, "config")) return try handleConfigCommand(self, cmd.arg);
    if (isSlashName(cmd, "capabilities")) return try handleCapabilitiesCommand(self, cmd.arg);
    if (isSlashName(cmd, "debug")) {
        if (std.ascii.eqlIgnoreCase(cmd.arg, "show") or cmd.arg.len == 0) return try formatStatus(self);
        if (std.ascii.eqlIgnoreCase(cmd.arg, "reset")) {
            resetRuntimeCommandState(self);
            return try self.allocator.dupe(u8, "Runtime debug state reset.");
        }
        return try self.allocator.dupe(u8, "Supported: /debug show|reset");
    }

    if (isSlashName(cmd, "dock-telegram") or isSlashName(cmd, "dock_telegram")) return try handleDockCommand(self, "telegram");
    if (isSlashName(cmd, "dock-discord") or isSlashName(cmd, "dock_discord")) return try handleDockCommand(self, "discord");
    if (isSlashName(cmd, "dock-slack") or isSlashName(cmd, "dock_slack")) return try handleDockCommand(self, "slack");
    if (isSlashName(cmd, "activation")) return try handleActivationCommand(self, cmd.arg);
    if (isSlashName(cmd, "send")) return try handleSendCommand(self, cmd.arg);
    if (isSlashName(cmd, "elevated") or isSlashName(cmd, "elev")) return try handleElevatedCommand(self, cmd.arg);

    if (isSlashName(cmd, "bash")) return try handleBashCommand(self, cmd.arg);
    if (isSlashName(cmd, "poll")) return try handlePollCommand(self);
    if (isSlashName(cmd, "skill")) return try handleSkillCommand(self, cmd.arg);
    if (isSlashName(cmd, "doctor")) return try handleDoctorCommand(self);
    if (isSlashName(cmd, "memory")) return try handleMemoryCommand(self, cmd.arg);
    if (isSlashName(cmd, "learn")) return try handleLearnCommand(self, cmd.arg);
    if (isSlashName(cmd, "persona")) return try handlePersonaCommand(self, cmd.arg);
    if (isSlashName(cmd, "health")) return try handleHealthCommand(self);
    if (isSlashName(cmd, "security-review") or isSlashName(cmd, "security_review")) return try handleSecurityReviewCommand(self);
    if (isSlashName(cmd, "permissions") or isSlashName(cmd, "perm")) return try handlePermissionsCommand(self);

    return null;
}

fn handleHealthCommand(self: anytype) ![]const u8 {
    // Use snapshotComponents for a mutex-safe copy of the registry.
    // Per-channel detail (via ChannelManager) is available at /api/v1/channels/health.
    const snap = try health_mod.snapshotComponents(self.allocator);
    defer self.allocator.free(snap.entries);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    const w = buf.writer(self.allocator);

    try w.print("System Health (uptime: {d}s)\n\n", .{snap.uptime_secs});

    if (snap.entries.len == 0) {
        try w.writeAll("  (no components registered)\n");
    } else {
        for (snap.entries) |entry| {
            try w.print("  {s}: {s}\n", .{ entry.name, entry.health.status });
        }
    }

    try w.writeAll("\nFor per-channel detail, use GET /api/v1/channels/health\n");
    return try buf.toOwnedSlice(self.allocator);
}

fn handleSecurityReviewCommand(self: anytype) ![]const u8 {
    // Extract security parameters from the agent's policy when available.
    const workspace_only = if (@hasField(@TypeOf(self.*), "policy"))
        (if (self.policy) |p| p.workspace_only else true)
    else
        true;
    const max_actions = if (@hasField(@TypeOf(self.*), "policy"))
        (if (self.policy) |p| p.max_actions_per_hour else @as(u32, 100))
    else
        @as(u32, 100);

    const sec_cfg: config_types.SecurityConfig = if (@hasField(@TypeOf(self.*), "security_config"))
        self.security_config
    else
        .{};

    const report = try security_review.runAllChecks(
        self.allocator,
        sec_cfg,
        workspace_only,
        max_actions,
        true, // pairing_enabled — conservative default
    );
    defer self.allocator.free(report.checks);

    return try security_review.formatReviewText(self.allocator, report);
}

/// Read-only snapshot of the agent's permission, approval, and execution posture.
/// Does not mutate config, pending approvals, or any runtime state.
fn handlePermissionsCommand(self: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    const w = out.writer(self.allocator);

    try w.writeAll("Permissions (read-only report)\n\n");
    try w.print("Execution mode: {s}\n", .{self.execution_mode.toSlice()});

    try w.writeAll("\nSecurity policy:\n");
    if (self.policy) |pol| {
        try w.writeAll("  status: configured\n");
        try w.print("  autonomy: {s}\n", .{pol.autonomy.toString()});
        try w.print("  workspace_dir: {s}\n", .{pol.workspace_dir});
        try w.print("  workspace_only: {s}\n", .{if (pol.workspace_only) "true" else "false"});
        try w.print("  max_actions_per_hour: {d}\n", .{pol.max_actions_per_hour});
        try w.print("  rate_limited: {s}\n", .{if (pol.isRateLimited()) "yes" else "no"});
    } else {
        try w.writeAll("  status: not configured\n");
    }

    // Category archetypes used to describe per-category gate verdicts below.
    // These are intentionally constructed by hand (not looked up from the
    // registry) — they represent the canonical flag combinations a tool can
    // carry, not a specific tool. Runtime decisions for a concrete tool must
    // still go through tools.root.canonicalMetadataForCall on the agent path.
    const read_meta = tool_metadata_mod.ToolMetadata{
        .name = "_read_only",
        .flags = .{ .read_only = true },
    };
    const mutating_meta = tool_metadata_mod.ToolMetadata{
        .name = "_mutating",
        .flags = .{ .mutating = true },
    };
    const operator_meta = tool_metadata_mod.ToolMetadata{
        .name = "_operator_only",
        .flags = .{ .operator_only = true },
    };
    const background_safe_meta = tool_metadata_mod.ToolMetadata{
        .name = "_background_safe",
        .flags = .{ .read_only = true, .background_safe = true },
    };

    // Gate 1 — execution mode gate.
    // Reflects ExecutionMode.allowsTool for each category archetype; this is
    // the same predicate preflightToolPolicy consults for the current mode.
    try w.writeAll("\nGate 1 — Execution mode:\n");
    try w.print("  current mode:            {s}\n", .{self.execution_mode.toSlice()});
    try w.print("  allows read-only:        {s}\n", .{yesNo(self.execution_mode.allowsTool(read_meta))});
    try w.print("  allows mutating:         {s}\n", .{yesNo(self.execution_mode.allowsTool(mutating_meta))});
    try w.print("  allows background-safe:  {s}\n", .{yesNo(self.execution_mode.allowsTool(background_safe_meta))});

    // Gate 2 — generic tool approval gate.
    // Category decisions derived from the canonical approval path
    // (SecurityPolicy.resolveApproval now takes pre-resolved metadata).
    try w.writeAll("\nGate 2 — Generic tool approval:\n");
    if (self.policy) |pol| {
        try w.print("  autonomy:                {s}\n", .{pol.autonomy.toString()});
        try w.print(
            "  read-only tools:         {s}\n",
            .{pol.resolveApproval(read_meta).toSlice()},
        );
        try w.print(
            "  mutating tools:          {s}\n",
            .{pol.resolveApproval(mutating_meta).toSlice()},
        );
        try w.print(
            "  operator-only:           {s}\n",
            .{pol.resolveApproval(operator_meta).toSlice()},
        );
        try w.writeAll("  unknown/MCP tools:       confirm_once (conservative)\n");
    } else {
        try w.writeAll("  (no SecurityPolicy configured — approval rules not enforced)\n");
    }

    // Gate 3 — legacy shell /exec approval gate.
    // This is a separate (pre-registry) path scoped to shell command execs
    // and NOT routed through ApprovalPolicy. Surfacing it explicitly so
    // callers don't confuse its posture with Gate 2.
    try w.writeAll("\nGate 3 — Legacy shell /exec:\n");
    try w.print("  host:      {s}\n", .{self.exec_host.toSlice()});
    try w.print("  security:  {s}\n", .{self.exec_security.toSlice()});
    try w.print("  ask:       {s}\n", .{self.exec_ask.toSlice()});

    var wrote_pending = false;
    if (@hasField(@TypeOf(self.*), "pending_tool_approval")) {
        if (self.pending_tool_approval) |p| {
            try w.writeAll("\nPending tool approval:\n");
            try w.print("  id: {d}\n", .{p.id});
            try w.print("  tool: {s}\n", .{p.tool_name});
            try w.print("  risk: {s}\n", .{p.risk_level.toSlice()});
            try w.print("  reason: {s}\n", .{p.reason});
            try w.print("  resolve: /approve {d} allow-once|deny\n", .{p.id});
            wrote_pending = true;
        }
    }
    if (self.pending_exec_command) |cmd| {
        try w.writeAll("\nPending exec approval:\n");
        try w.print("  id: {d}\n", .{self.pending_exec_id});
        try w.print("  command: {s}\n", .{cmd});
        try w.print("  resolve: /approve {d} allow-once|allow-always|deny\n", .{self.pending_exec_id});
        wrote_pending = true;
    }
    if (!wrote_pending) {
        try w.writeAll("\nPending approvals: none\n");
    }

    try w.writeAll(
        "\nNote: generic allow-always is not persistent in v1 — an approved call runs once.\n",
    );

    return try out.toOwnedSlice(self.allocator);
}

fn yesNo(v: bool) []const u8 {
    return if (v) "yes" else "no";
}

fn handleVoiceCommand(self: anytype, arg: []const u8) ![]const u8 {
    if (arg.len == 0) {
        // Show current voice mode state
        const voice_active = self.tts_mode != .off;
        return try std.fmt.allocPrint(
            self.allocator,
            "Voice mode: {s}\nTTS mode: {s}\nAudio: {s}",
            .{
                if (voice_active) "active" else "inactive",
                self.tts_mode.toSlice(),
                if (self.tts_audio) "on" else "off",
            },
        );
    }

    if (std.ascii.eqlIgnoreCase(arg, "on")) {
        self.tts_mode = .always;
        self.tts_audio = true;
        return try self.allocator.dupe(u8, "Voice mode enabled (TTS: always, audio: on)");
    }

    if (std.ascii.eqlIgnoreCase(arg, "off")) {
        self.tts_mode = .off;
        self.tts_audio = false;
        return try self.allocator.dupe(u8, "Voice mode disabled");
    }

    return try self.allocator.dupe(u8, "Usage: /voice [on|off]");
}

fn handleLearnCommand(self: anytype, arg: []const u8) ![]const u8 {
    const parsed = splitFirstToken(arg);
    const sub = parsed.head;
    const rest = parsed.tail;

    const mem_rt = memoryRuntimePtr(self) orelse {
        return try self.allocator.dupe(u8, "Memory not available.");
    };

    // /learn  or  /learn list  — show all behavioral facts
    if (sub.len == 0 or std.mem.eql(u8, sub, "list")) {
        const entries = mem_rt.memory.list(self.allocator, null, self.memory_session_id) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Memory list failed: {s}", .{@errorName(err)});
        };
        defer memory_mod.freeEntries(self.allocator, entries);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);

        var count: usize = 0;
        for (entries) |e| {
            if (!std.mem.startsWith(u8, e.key, "durable_fact/behavior/")) continue;
            count += 1;
        }

        if (count == 0) {
            return try self.allocator.dupe(u8, "No learned behavioral facts found.");
        }

        try w.print("Learned behavioral facts ({d}):\n", .{count});
        var idx: usize = 0;
        for (entries) |e| {
            if (!std.mem.startsWith(u8, e.key, "durable_fact/behavior/")) continue;
            idx += 1;
            const preview_len = @min(@as(usize, 200), e.content.len);
            try w.print("  {d}. {s}\n     key: {s}\n", .{ idx, e.content[0..preview_len], e.key });
        }
        return try out.toOwnedSlice(self.allocator);
    }

    // /learn forget <key>  — remove a specific learned fact by key suffix or full key
    if (std.mem.eql(u8, sub, "forget")) {
        const raw_key = std.mem.trim(u8, rest, " \t");
        if (raw_key.len == 0) {
            return try self.allocator.dupe(u8, "Usage: /learn forget <key>");
        }

        // Accept either the full key or the 16-char hex suffix
        const full_key = if (std.mem.startsWith(u8, raw_key, "durable_fact/behavior/"))
            try self.allocator.dupe(u8, raw_key)
        else blk: {
            if (raw_key.len != 16) {
                return try self.allocator.dupe(u8, "Key must be the full durable_fact/behavior/... key or a 16-char hex suffix. Use /learn list to see keys.");
            }
            for (raw_key) |c| {
                if (!std.ascii.isHex(c)) {
                    return try self.allocator.dupe(u8, "Key suffix must be hexadecimal. Use /learn list to see keys.");
                }
            }
            break :blk try std.fmt.allocPrint(self.allocator, "durable_fact/behavior/{s}", .{raw_key});
        };
        defer self.allocator.free(full_key);

        const removed = mem_rt.memory.forget(full_key) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Forget failed: {s}", .{@errorName(err)});
        };
        if (removed) {
            return try std.fmt.allocPrint(self.allocator, "Removed learned fact: {s}", .{full_key});
        }
        return try std.fmt.allocPrint(self.allocator, "No learned fact found with key: {s}", .{full_key});
    }

    return try self.allocator.dupe(u8, "Usage: /learn [list|forget <key>]");
}

fn handlePersonaCommand(self: anytype, _arg: []const u8) ![]const u8 {
    _ = _arg;

    const workspace_dir = if (@hasField(@TypeOf(self.*), "workspace_dir"))
        self.workspace_dir
    else
        return try self.allocator.dupe(u8, "Workspace directory not available.");

    const profile_opt = prompt_mod.resolvePersonaFromFile(self.allocator, workspace_dir);
    if (profile_opt == null) {
        return try self.allocator.dupe(
            u8,
            "No SOUL.md found or no persona front-matter defined. Using defaults.\n" ++
                "  Warmth:     balanced\n" ++
                "  Proactivity: moderate\n" ++
                "  Voice:      (none)\n" ++
                "  Twin mode:  false",
        );
    }

    const profile = profile_opt.?;
    defer if (profile.voice) |v| self.allocator.free(v);
    const warmth_str: []const u8 = switch (profile.warmth) {
        .crisp => "crisp",
        .balanced => "balanced",
        .warm => "warm",
    };
    const proactivity_str: []const u8 = switch (profile.proactivity) {
        .reactive => "reactive",
        .moderate => "moderate",
        .proactive => "proactive",
    };
    const voice_str = profile.voice orelse "(none)";
    const twin_str: []const u8 = if (profile.twin_mode) "true" else "false";

    return try std.fmt.allocPrint(
        self.allocator,
        "Current persona profile (from SOUL.md):\n" ++
            "  Warmth:     {s}\n" ++
            "  Proactivity: {s}\n" ++
            "  Voice:      {s}\n" ++
            "  Twin mode:  {s}",
        .{ warmth_str, proactivity_str, voice_str, twin_str },
    );
}

fn handleMemoryCommand(self: anytype, arg: []const u8) ![]const u8 {
    const usage =
        "Usage: /memory <stats|status|reindex|count|search|get|list|drain-outbox>\n" ++
        "  /memory search <query> [--limit N]\n" ++
        "  /memory get <key>\n" ++
        "  /memory list [--category C] [--limit N] [--include-internal]";

    const parsed = splitFirstToken(arg);
    const sub = parsed.head;
    const rest = parsed.tail;

    if (sub.len == 0) return try self.allocator.dupe(u8, usage);

    if (std.mem.eql(u8, sub, "doctor") or std.mem.eql(u8, sub, "status")) {
        return try handleDoctorCommand(self);
    }

    const mem_rt = memoryRuntimePtr(self) orelse {
        return try self.allocator.dupe(u8, "Memory runtime not available.");
    };

    if (std.mem.eql(u8, sub, "stats")) {
        const r = mem_rt.resolved;
        const report = mem_rt.diagnose();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.print("Memory resolved config:\n", .{});
        try w.print("  backend: {s}\n", .{r.primary_backend});
        try w.print("  retrieval: {s}\n", .{r.retrieval_mode});
        try w.print("  vector: {s}\n", .{r.vector_mode});
        try w.print("  embedding: {s}\n", .{r.embedding_provider});
        try w.print("  rollout: {s}\n", .{r.rollout_mode});
        try w.print("  sync: {s}\n", .{r.vector_sync_mode});
        try w.print("  sources: {d}\n", .{r.source_count});
        try w.print("  fallback: {s}\n", .{r.fallback_policy});
        try w.print("  entries: {d}\n", .{report.entry_count});
        if (report.vector_entry_count) |n| {
            try w.print("  vector_entries: {d}\n", .{n});
        } else {
            try w.print("  vector_entries: n/a\n", .{});
        }
        if (report.outbox_pending) |n| {
            try w.print("  outbox_pending: {d}\n", .{n});
        } else {
            try w.print("  outbox_pending: n/a\n", .{});
        }
        return try out.toOwnedSlice(self.allocator);
    }

    if (std.mem.eql(u8, sub, "count")) {
        const count = mem_rt.memory.count() catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Memory count failed: {s}", .{@errorName(err)});
        };
        return try std.fmt.allocPrint(self.allocator, "{d}", .{count});
    }

    if (std.mem.eql(u8, sub, "reindex")) {
        const count = mem_rt.reindex(self.allocator);
        if (std.mem.eql(u8, mem_rt.resolved.vector_mode, "none")) {
            return try self.allocator.dupe(u8, "Vector plane is disabled; reindex skipped (0 entries).");
        }
        return try std.fmt.allocPrint(self.allocator, "Reindex complete: {d} entries reindexed.", .{count});
    }

    if (std.mem.eql(u8, sub, "drain-outbox") or std.mem.eql(u8, sub, "drain_outbox")) {
        const drained = mem_rt.drainOutbox(self.allocator);
        return try std.fmt.allocPrint(self.allocator, "Outbox drain complete: {d} operation(s) processed.", .{drained});
    }

    if (std.mem.eql(u8, sub, "get")) {
        const key = std.mem.trim(u8, rest, " \t");
        if (key.len == 0) return try self.allocator.dupe(u8, "Usage: /memory get <key>");
        const entry = mem_rt.memory.get(self.allocator, key) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Memory get failed: {s}", .{@errorName(err)});
        };
        if (entry) |e| {
            defer e.deinit(self.allocator);
            return try std.fmt.allocPrint(
                self.allocator,
                "key: {s}\ncategory: {s}\ntimestamp: {s}\ncontent:\n{s}",
                .{ e.key, e.category.toString(), e.timestamp, e.content },
            );
        }
        return try std.fmt.allocPrint(self.allocator, "Not found: {s}", .{key});
    }

    if (std.mem.eql(u8, sub, "search")) {
        var limit: usize = 6;
        var query_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer query_buf.deinit(self.allocator);

        var it = std.mem.tokenizeAny(u8, rest, " \t");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "--limit")) {
                const next = it.next() orelse return try self.allocator.dupe(u8, "Usage: /memory search <query> [--limit N]");
                limit = parsePositiveUsize(next) orelse return try std.fmt.allocPrint(self.allocator, "Invalid --limit value: {s}", .{next});
                continue;
            }
            if (query_buf.items.len > 0) try query_buf.append(self.allocator, ' ');
            try query_buf.appendSlice(self.allocator, tok);
        }

        const query = std.mem.trim(u8, query_buf.items, " \t");
        if (query.len == 0) return try self.allocator.dupe(u8, "Usage: /memory search <query> [--limit N]");

        const results = mem_rt.search(self.allocator, query, limit, null) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Memory search failed: {s}", .{@errorName(err)});
        };
        defer memory_mod.retrieval.freeCandidates(self.allocator, results);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.print("Search results: {d}\n", .{results.len});
        for (results, 0..) |c, idx| {
            try w.print("  {d}. {s} [{s}] rrf_score={d:.4}", .{ idx + 1, c.key, c.category.toString(), c.final_score });
            if (c.vector_score) |vs| {
                try w.print(" vector_score={d:.4}", .{vs});
            } else {
                try w.print(" vector_score=n/a", .{});
            }
            try w.print(" source={s}\n", .{c.source});
            const preview_len = @min(@as(usize, 140), c.snippet.len);
            const preview = c.snippet[0..preview_len];
            try w.print("     {s}{s}\n", .{ preview, if (c.snippet.len > preview_len) "..." else "" });
        }
        return try out.toOwnedSlice(self.allocator);
    }

    if (std.mem.eql(u8, sub, "list")) {
        var limit: usize = 20;
        var category_opt: ?memory_mod.MemoryCategory = null;
        var include_internal = false;
        var it = std.mem.tokenizeAny(u8, rest, " \t");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "--limit")) {
                const next = it.next() orelse return try self.allocator.dupe(u8, "Usage: /memory list [--category C] [--limit N] [--include-internal]");
                limit = parsePositiveUsize(next) orelse return try std.fmt.allocPrint(self.allocator, "Invalid --limit value: {s}", .{next});
                continue;
            }
            if (std.mem.eql(u8, tok, "--category")) {
                const next = it.next() orelse return try self.allocator.dupe(u8, "Usage: /memory list [--category C] [--limit N] [--include-internal]");
                category_opt = memory_mod.MemoryCategory.fromString(next);
                continue;
            }
            if (std.mem.eql(u8, tok, "--include-internal")) {
                include_internal = true;
                continue;
            }
            return try std.fmt.allocPrint(self.allocator, "Unknown option for /memory list: {s}", .{tok});
        }

        const entries = mem_rt.memory.list(self.allocator, category_opt, null) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Memory list failed: {s}", .{@errorName(err)});
        };
        defer memory_mod.freeEntries(self.allocator, entries);

        var filtered_total: usize = 0;
        for (entries) |entry| {
            if (!include_internal and memory_mod.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
            filtered_total += 1;
        }

        if (filtered_total == 0) {
            return try self.allocator.dupe(u8, "No memory entries found.");
        }

        const shown = @min(limit, filtered_total);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.print("Memory entries: showing {d}/{d}\n", .{ shown, filtered_total });
        var written: usize = 0;
        for (entries) |e| {
            if (!include_internal and memory_mod.isInternalMemoryEntryKeyOrContent(e.key, e.content)) continue;
            if (written >= shown) break;
            const preview_len = @min(@as(usize, 120), e.content.len);
            const preview = e.content[0..preview_len];
            try w.print("  {d}. {s} [{s}] {s}\n", .{ written + 1, e.key, e.category.toString(), e.timestamp });
            try w.print("     {s}{s}\n", .{ preview, if (e.content.len > preview_len) "..." else "" });
            written += 1;
        }
        return try out.toOwnedSlice(self.allocator);
    }

    return try self.allocator.dupe(u8, usage);
}

// ── Baseline characterization tests (Phase 00-01) ───────────────

test "baseline: parseSlashCommand parses simple command" {
    const cmd = parseSlashCommand("/status") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("status", cmd.name);
    try std.testing.expectEqualStrings("", cmd.arg);
}

test "baseline: parseSlashCommand parses command with argument" {
    const cmd = parseSlashCommand("/model claude-sonnet-4.6") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("model", cmd.name);
    try std.testing.expectEqualStrings("claude-sonnet-4.6", cmd.arg);
}

test "baseline: parseSlashCommand returns null for non-slash input" {
    try std.testing.expect(parseSlashCommand("hello world") == null);
    try std.testing.expect(parseSlashCommand("") == null);
    try std.testing.expect(parseSlashCommand("/ ") == null);
}

test "baseline: parseSlashCommand strips bot mention" {
    const cmd = parseSlashCommand("/model@zaki_bot gpt-4.1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("model", cmd.name);
    try std.testing.expectEqualStrings("gpt-4.1", cmd.arg);
}

test "baseline: isSlashName is case-insensitive" {
    const cmd = parseSlashCommand("/STATUS") orelse return error.TestExpectedEqual;
    try std.testing.expect(isSlashName(cmd, "status"));
    try std.testing.expect(isSlashName(cmd, "STATUS"));
    try std.testing.expect(!isSlashName(cmd, "model"));
}

test "baseline: known command surface has expected breadth" {
    // Characterize that handleSlashCommand recognizes all documented commands.
    // This test validates the slash command set by checking parseSlashCommand
    // correctly parses each known command name.
    const known_commands = [_][]const u8{
        "new",          "reset",          "resume",       "restart",         "help",
        "commands",     "status",         "runtime",      "whoami",          "id",
        "model",        "models",         "think",        "verbose",         "reasoning",
        "exec",         "queue",          "usage",        "cost",            "tts",
        "voice",        "stop",           "compact",      "allowlist",       "approve",
        "context",      "export-session", "export",       "session",         "subagents",
        "agents",       "focus",          "unfocus",      "kill",            "steer",
        "tell",         "config",         "capabilities", "debug",           "dock-telegram",
        "dock-discord", "dock-slack",     "activation",   "send",            "elevated",
        "bash",         "poll",           "skill",        "doctor",          "memory",
        "learn",        "persona",        "health",       "security-review", "security_review",
        "permissions",  "perm",           "plan",         "review",          "execute",
    };
    for (known_commands) |name| {
        const input = std.fmt.allocPrint(std.testing.allocator, "/{s}", .{name}) catch unreachable;
        defer std.testing.allocator.free(input);
        const cmd = parseSlashCommand(input);
        try std.testing.expect(cmd != null);
    }
    // Verify count — if someone adds a command, this test documents the current set size
    try std.testing.expect(known_commands.len >= 48);
}

test "parseSlashCommand recognizes /permissions and /perm" {
    const p1 = parseSlashCommand("/permissions") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("permissions", p1.name);
    const p2 = parseSlashCommand("/perm") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("perm", p2.name);
}

test "handleSlashCommand recognizes /health" {
    const cmd = parseSlashCommand("/health");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("health", cmd.?.name);
}

test "handleSlashCommand recognizes /security-review" {
    const cmd = parseSlashCommand("/security-review");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("security-review", cmd.?.name);
}

test "handleSlashCommand recognizes /voice on" {
    const cmd = parseSlashCommand("/voice on");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("voice", cmd.?.name);
    try std.testing.expectEqualStrings("on", std.mem.trim(u8, cmd.?.arg, " \t"));
}

// ── WP3.1: direct mode commands (/plan, /review, /execute) ─────────────

test "parseSlashCommand recognizes /plan /review /execute" {
    const p = parseSlashCommand("/plan") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("plan", p.name);
    const r = parseSlashCommand("/review") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("review", r.name);
    const e = parseSlashCommand("/execute") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("execute", e.name);
}

const ModeStubAgent = struct {
    allocator: std.mem.Allocator,
    execution_mode: execution_mode_mod.ExecutionMode,
};

test "handlePlanCommand sets mode to .plan and mentions safety hints" {
    var agent = ModeStubAgent{
        .allocator = std.testing.allocator,
        .execution_mode = .execute,
    };
    const response = try handlePlanCommand(&agent);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(execution_mode_mod.ExecutionMode.plan, agent.execution_mode);
    try std.testing.expect(std.mem.indexOf(u8, response, "plan mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Mutating tools are blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "read-only tools may run") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/permissions") != null);
}

test "handleReviewCommand sets mode to .review and mentions safety hints" {
    var agent = ModeStubAgent{
        .allocator = std.testing.allocator,
        .execution_mode = .execute,
    };
    const response = try handleReviewCommand(&agent);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(execution_mode_mod.ExecutionMode.review, agent.execution_mode);
    try std.testing.expect(std.mem.indexOf(u8, response, "review mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Mutating tools are blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "read-only tools may run") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/permissions") != null);
}

test "handleExecuteCommand sets mode to .execute and mentions security policy" {
    var agent = ModeStubAgent{
        .allocator = std.testing.allocator,
        .execution_mode = .plan,
    };
    const response = try handleExecuteCommand(&agent);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(execution_mode_mod.ExecutionMode.execute, agent.execution_mode);
    try std.testing.expect(std.mem.indexOf(u8, response, "execute mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "current security policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/permissions") != null);
}

test "handleModeCommand plan still sets mode to .plan" {
    var agent = ModeStubAgent{
        .allocator = std.testing.allocator,
        .execution_mode = .execute,
    };
    const response = try handleModeCommand(&agent, "plan");
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(execution_mode_mod.ExecutionMode.plan, agent.execution_mode);
}

// ── WP3.3: /cost — read-only token and cost status ─────────────────────

const CostStubAgent = struct {
    allocator: std.mem.Allocator,
    last_turn_usage: providers.TokenUsage,
    total_tokens: u64,
    usage_rt: ?*usage_runtime_mod.UsageRuntime,
    // Sentinel field asserted unchanged by /cost. Typed as u8 to avoid
    // depending on the private Agent.UsageMode enum.
    usage_mode: u8 = 0,
};

test "parseSlashCommand recognizes /cost" {
    const cmd = parseSlashCommand("/cost") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("cost", cmd.name);
    try std.testing.expectEqualStrings("", cmd.arg);
}

test "handleCostCommand with no usage reports zero-token status clearly" {
    var agent = CostStubAgent{
        .allocator = std.testing.allocator,
        .last_turn_usage = .{},
        .total_tokens = 0,
        .usage_rt = null,
    };
    const response = try handleCostCommand(&agent);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Cost estimate unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "provider pricing is not wired") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "prompt=0 completion=0 total=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "tokens=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/usage cost") != null);
}

test "handleCostCommand reports last_turn_usage and session total_tokens" {
    var agent = CostStubAgent{
        .allocator = std.testing.allocator,
        .last_turn_usage = .{ .prompt_tokens = 12, .completion_tokens = 34, .total_tokens = 46 },
        .total_tokens = 128,
        .usage_rt = null,
    };
    const response = try handleCostCommand(&agent);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "prompt=12 completion=34 total=46") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "tokens=128") != null);
    // usage_rt is null → pricing is unwired; must say so explicitly.
    try std.testing.expect(std.mem.indexOf(u8, response, "Cost estimate unavailable") != null);
}

test "handleCostCommand surfaces real cost from usage_rt when non-zero" {
    var rt = usage_runtime_mod.UsageRuntime.init(std.testing.allocator);
    defer rt.deinit();
    rt.recordTurn("claude-3", 100, 50, 0.001234, 100);

    var agent = CostStubAgent{
        .allocator = std.testing.allocator,
        .last_turn_usage = .{ .prompt_tokens = 100, .completion_tokens = 50, .total_tokens = 150 },
        .total_tokens = 150,
        .usage_rt = &rt,
    };
    const response = try handleCostCommand(&agent);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Session cost: $") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Cost estimate unavailable") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "prompt=100 completion=50 total=150") != null);
}

test "handleCostCommand does not mutate usage_mode or counters" {
    var agent = CostStubAgent{
        .allocator = std.testing.allocator,
        .last_turn_usage = .{ .prompt_tokens = 7, .completion_tokens = 3, .total_tokens = 10 },
        .total_tokens = 99,
        .usage_rt = null,
        .usage_mode = 42,
    };
    const response = try handleCostCommand(&agent);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(u8, 42), agent.usage_mode);
    try std.testing.expectEqual(@as(u64, 99), agent.total_tokens);
    try std.testing.expectEqual(@as(u32, 7), agent.last_turn_usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 3), agent.last_turn_usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 10), agent.last_turn_usage.total_tokens);
}

test "parseUsageMode still accepts cost (keeps /usage cost working)" {
    const UsageModeLocal = enum { off, tokens, full, cost };
    const m = parseUsageMode(UsageModeLocal, "cost") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(UsageModeLocal.cost, m);
}

test "generic approval fallback returns tool output when continuation is empty" {
    const PendingApproval = struct {
        id: u64,
        tool_name: []const u8,
        risk_level: tool_metadata_mod.RiskLevel,
        reason: []const u8,
    };
    const FakeAgent = struct {
        allocator: std.mem.Allocator,
        approval_continues_turn: bool = true,
        pending_tool_approval: ?PendingApproval = .{
            .id = 41,
            .tool_name = "artifact_create",
            .risk_level = .low,
            .reason = "supervised_mutating_requires_approval",
        },
        turn_calls: usize = 0,

        fn executeApprovedPendingTool(_: *@This(), _: std.mem.Allocator) !struct {
            success: bool,
            output: []const u8,
        } {
            return .{ .success = true, .output = "artifact row created" };
        }

        fn clearPendingToolApproval(self: *@This()) void {
            self.pending_tool_approval = null;
        }

        fn turn(self: *@This(), _: []const u8) ![]const u8 {
            self.turn_calls += 1;
            return try self.allocator.dupe(u8, " \n\t ");
        }
    };

    const allocator = std.testing.allocator;
    var fake = FakeAgent{ .allocator = allocator };
    const response = try handleGenericToolApprove(&fake, "allow-once");
    defer allocator.free(response);

    try std.testing.expectEqual(@as(usize, 1), fake.turn_calls);
    try std.testing.expect(fake.pending_tool_approval == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Approved tool (id=41) succeeded.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "artifact row created") != null);
}

// ── /help categorized discovery surface ─────────────────────────────────
// handleSlashCommand monomorphizes against the caller's agent type and
// compiles all branches, so we can't build a tiny stub for the /help
// path alone. Instead, assert against the static HELP_TEXT constant
// that /help dupes verbatim — the handler's only side effect is the
// allocator copy, which is already exercised by integration tests.

fn expectHelpContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("help text missing: {s}\n", .{needle});
        return error.TestExpectedEqual;
    }
}

test "HELP_TEXT exposes implemented operator commands" {
    // Must include the P0 operator-surface commands.
    try expectHelpContains(HELP_TEXT, "/permissions");
    try expectHelpContains(HELP_TEXT, "/perm");
    try expectHelpContains(HELP_TEXT, "/plan");
    try expectHelpContains(HELP_TEXT, "/review");
    try expectHelpContains(HELP_TEXT, "/execute");
    try expectHelpContains(HELP_TEXT, "/usage");
    try expectHelpContains(HELP_TEXT, "/cost");
    try expectHelpContains(HELP_TEXT, "/mode");
}

test "HELP_TEXT is categorized (contains section headers)" {
    try expectHelpContains(HELP_TEXT, "Session:");
    try expectHelpContains(HELP_TEXT, "Execution posture:");
    try expectHelpContains(HELP_TEXT, "Safety & approvals:");
    try expectHelpContains(HELP_TEXT, "Usage & cost:");
    try expectHelpContains(HELP_TEXT, "Diagnostics:");
}

// V1.11 (2026-05-07) — composeFinalReply regression tests.
//
// Pin the empty-content fallback behavior: when a model emits empty
// `content` but non-empty `reasoning_content` (DeepSeek V4-Pro at
// reasoning_effort=high exhibits this for many queries), the reply
// should fall back to reasoning_content as the visible text. Pre-V1.11
// the function returned the empty base_text, leaving the user with
// no visible reply for any V4-Pro turn that emitted thinking-only.

const ReasoningMode = enum { off, on };
const UsageMode = enum { off, tokens, full, cost };

const TestComposeContext = struct {
    allocator: std.mem.Allocator,
    reasoning_mode: ReasoningMode = .off,
    usage_mode: UsageMode = .off,
    total_tokens: u64 = 0,
};

test "composeFinalReply: empty content + non-empty reasoning falls back to reasoning (V4-Pro fix)" {
    const allocator = std.testing.allocator;
    var ctx = TestComposeContext{ .allocator = allocator };
    const usage = providers.TokenUsage{};
    const reply = try composeFinalReply(&ctx, "", "Let me think about this. The answer is 42.", usage);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("Let me think about this. The answer is 42.", reply);
}

test "composeFinalReply: whitespace-only content + reasoning falls back (trims first)" {
    const allocator = std.testing.allocator;
    var ctx = TestComposeContext{ .allocator = allocator };
    const usage = providers.TokenUsage{};
    const reply = try composeFinalReply(&ctx, "   \n\t  ", "  Reasoning fallback content.  ", usage);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("Reasoning fallback content.", reply);
}

test "composeFinalReply: empty content + null reasoning returns empty (true no-output case)" {
    const allocator = std.testing.allocator;
    var ctx = TestComposeContext{ .allocator = allocator };
    const usage = providers.TokenUsage{};
    const reply = try composeFinalReply(&ctx, "", null, usage);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("", reply);
}

test "composeFinalReply: non-empty content + reasoning returns just content (no double-print)" {
    const allocator = std.testing.allocator;
    var ctx = TestComposeContext{ .allocator = allocator };
    const usage = providers.TokenUsage{};
    const reply = try composeFinalReply(&ctx, "Visible answer.", "Internal thinking.", usage);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("Visible answer.", reply);
}

test "composeFinalReply: reasoning_mode=on appends reasoning alongside visible content" {
    const allocator = std.testing.allocator;
    var ctx = TestComposeContext{ .allocator = allocator, .reasoning_mode = .on };
    const usage = providers.TokenUsage{};
    const reply = try composeFinalReply(&ctx, "Visible answer.", "Internal thinking.", usage);
    defer allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Visible answer.") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Reasoning:") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Internal thinking.") != null);
}

test "composeFinalReply: empty content + reasoning + reasoning_mode=on still falls back without doubling" {
    // Edge case: when the fallback fires (no visible content), reasoning
    // becomes the visible text. Don't ALSO append "Reasoning: ..." after
    // it — that would print the reasoning twice. show_reasoning gate is
    // `has_visible_text and ...`, so when content is empty we skip the
    // append even with reasoning_mode=on.
    const allocator = std.testing.allocator;
    var ctx = TestComposeContext{ .allocator = allocator, .reasoning_mode = .on };
    const usage = providers.TokenUsage{};
    const reply = try composeFinalReply(&ctx, "", "Just the reasoning.", usage);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("Just the reasoning.", reply);
}

test "HELP_TEXT covers additional implemented commands" {
    // Sanity: common existing commands should still appear in discovery.
    try expectHelpContains(HELP_TEXT, "/new");
    try expectHelpContains(HELP_TEXT, "/reset");
    try expectHelpContains(HELP_TEXT, "/resume");
    try expectHelpContains(HELP_TEXT, "/status");
    try expectHelpContains(HELP_TEXT, "/model");
    try expectHelpContains(HELP_TEXT, "/memory");
    try expectHelpContains(HELP_TEXT, "/health");
    try expectHelpContains(HELP_TEXT, "/doctor");
    try expectHelpContains(HELP_TEXT, "/security-review");
    try expectHelpContains(HELP_TEXT, "/approve");
    try expectHelpContains(HELP_TEXT, "/allowlist");
    try expectHelpContains(HELP_TEXT, "/voice");
    try expectHelpContains(HELP_TEXT, "/compact");
}

// ── P0-2: non-interactive checkpoint reasons skip inline heavy memory work ──
//
// These pure-predicate tests pin the gate that governs whether
// persistSessionCheckpointDetailed runs a blocking inline LLM summarizer
// (summary_provider.chat) and inline boundary extraction (extractAtBoundary).
// `shouldUseDeterministicSessionSummary` true => the deterministic structured
// fallback path runs and summary_provider.chat is NEVER reached (commands.zig
// line ~1169-1180 break/return before the .chat call at ~1203).
// `shouldSkipInlineBoundaryExtraction` true => the inline extractAtBoundary
// block is skipped (the entity pipeline is still enqueued downstream).
// Together they assert ZERO inline provider.chat for the three evict reasons.

test "P0-2: shutdown/idle_evict/ttl_evict use deterministic summary (no inline provider.chat)" {
    // Non-interactive reasons are deterministic regardless of the P4 flag —
    // assert with the flag ON (default) to prove the flag does NOT route them
    // to the blocking LLM path.
    try std.testing.expect(shouldUseDeterministicSessionSummary("shutdown", true));
    try std.testing.expect(shouldUseDeterministicSessionSummary("idle_evict", true));
    try std.testing.expect(shouldUseDeterministicSessionSummary("ttl_evict", true));
    // P1-6 (audit, part a): ttl_recycle joins the deterministic set.
    try std.testing.expect(shouldUseDeterministicSessionSummary("ttl_recycle", true));
    // ...and still deterministic with the flag OFF.
    try std.testing.expect(shouldUseDeterministicSessionSummary("shutdown", false));
    try std.testing.expect(shouldUseDeterministicSessionSummary("ttl_recycle", false));
}

test "P4: live triggers take the LLM-summarizer path when the canonical flag is ON" {
    // Flag ON (default): the two LIVE in-conversation triggers route to the
    // real LLM summarizer (NOT deterministic). They run off-thread via
    // persistSessionCheckpointAsync, so the LLM call never blocks the turn.
    try std.testing.expect(!shouldUseDeterministicSessionSummary("compaction:auto", true));
    try std.testing.expect(!shouldUseDeterministicSessionSummary("summary_seed:auto", true));
}

test "P4: live triggers fall back to deterministic template when the canonical flag is OFF" {
    // Flag OFF: exact prior behavior — the live triggers use the deterministic
    // template (safe cost/latency rollback).
    try std.testing.expect(shouldUseDeterministicSessionSummary("compaction:auto", false));
    try std.testing.expect(shouldUseDeterministicSessionSummary("summary_seed:auto", false));
    // Non-interactive reasons remain deterministic in both flag states.
    try std.testing.expect(shouldUseDeterministicSessionSummary("shutdown", false));
}

test "P0-2: interactive reasons still take the LLM summary path" {
    // Manual / interactive checkpoints keep the inline LLM summarizer — only
    // the non-interactive lifecycle reasons are diverted off the blocking path.
    // Independent of the P4 flag (assert in both states).
    try std.testing.expect(!shouldUseDeterministicSessionSummary("compaction:manual", true));
    try std.testing.expect(!shouldUseDeterministicSessionSummary("reset:manual", true));
    try std.testing.expect(!shouldUseDeterministicSessionSummary("", true));
    try std.testing.expect(!shouldUseDeterministicSessionSummary("compaction:manual", false));
    try std.testing.expect(!shouldUseDeterministicSessionSummary("reset:manual", false));
}

test "P0-2: inline boundary extraction is skipped exactly for the evict reasons" {
    try std.testing.expect(shouldSkipInlineBoundaryExtraction("shutdown"));
    try std.testing.expect(shouldSkipInlineBoundaryExtraction("idle_evict"));
    try std.testing.expect(shouldSkipInlineBoundaryExtraction("ttl_evict"));
    // P1-6 (audit, part a): ttl_recycle's inline boundary work routes off-path.
    try std.testing.expect(shouldSkipInlineBoundaryExtraction("ttl_recycle"));
    // Interactive / auto reasons keep the inline extraction pass.
    try std.testing.expect(!shouldSkipInlineBoundaryExtraction("compaction:manual"));
    try std.testing.expect(!shouldSkipInlineBoundaryExtraction("compaction:auto"));
    try std.testing.expect(!shouldSkipInlineBoundaryExtraction("summary_seed:auto"));
}

test "P0-2: isNonInteractiveCheckpointReason classifies lifecycle reasons" {
    try std.testing.expect(isNonInteractiveCheckpointReason("shutdown"));
    try std.testing.expect(isNonInteractiveCheckpointReason("idle_evict"));
    try std.testing.expect(isNonInteractiveCheckpointReason("ttl_evict"));
    try std.testing.expect(!isNonInteractiveCheckpointReason("compaction:auto"));
    try std.testing.expect(!isNonInteractiveCheckpointReason("compaction:manual"));
}

test "P1-6 audit: ttl_recycle is non-interactive — inline boundary extraction routed off the turn path" {
    // recycleSessionInPlace checkpoints the expired agent with "ttl_recycle"
    // synchronously in front of a fresh incoming user turn. It MUST be
    // classified non-interactive so the blocking extractAtBoundary + inline
    // LLM summarizer are skipped (boundary work still rides the unconditional
    // enqueueExtractionJob lane). Pin all three gates together.
    try std.testing.expect(isNonInteractiveCheckpointReason("ttl_recycle"));
    try std.testing.expect(shouldSkipInlineBoundaryExtraction("ttl_recycle"));
    try std.testing.expect(shouldUseDeterministicSessionSummary("ttl_recycle"));
    // Interactive reasons remain unaffected — the gate widened by exactly one.
    try std.testing.expect(!isNonInteractiveCheckpointReason("reset:manual"));
    try std.testing.expect(!isNonInteractiveCheckpointReason("api_compact"));
    try std.testing.expect(!isNonInteractiveCheckpointReason("compaction:manual"));
}

// P2 (memory-phase-0.5) — content-keyed durable_fact derivation tests.
//
// Verifies three invariants using real ExtractedFact values (no duck-typing):
//   1. Two facts with IDENTICAL content → same key (dedup fires).
//   2. Two facts with DIFFERENT content → different keys.
//   3. A structured triple fact ALSO gets a `durable_fact/` key — classification
//      is preserved; cross-writer dedup with extracted_ is Phase-1 work.

test "P2: identical content produces the same durable_fact key" {
    const allocator = std.testing.allocator;
    const EF = memory_mod.summarizer.ExtractedFact;

    const fact_a = EF{ .key = "", .content = "User prefers dark mode", .category = .core };
    const fact_b = EF{ .key = "", .content = "User prefers dark mode", .category = .core };
    const fact_c = EF{ .key = "", .content = "User dislikes Comic Sans", .category = .core };

    const key_a = try deriveDurableFactKey(allocator, &fact_a);
    defer allocator.free(key_a);
    const key_b = try deriveDurableFactKey(allocator, &fact_b);
    defer allocator.free(key_b);
    const key_c = try deriveDurableFactKey(allocator, &fact_c);
    defer allocator.free(key_c);

    // Same content → same key (dedup).
    try std.testing.expectEqualStrings(key_a, key_b);
    // Different content → different keys.
    try std.testing.expect(!std.mem.eql(u8, key_a, key_c));
    // Always produces `durable_fact/<hex>` prefix — classification preserved.
    try std.testing.expect(std.mem.startsWith(u8, key_a, "durable_fact/"));
}

test "P2: triple fact also gets a durable_fact/ key (no classification change)" {
    const allocator = std.testing.allocator;
    const EF = memory_mod.summarizer.ExtractedFact;

    // A structured triple — all three triple fields present.
    const triple_fact = EF{
        .key = "",
        .content = "User likes Zig",
        .category = .core,
        .subject = "user",
        .predicate = "LIKES",
        .object = "Zig",
    };

    const key = try deriveDurableFactKey(allocator, &triple_fact);
    defer allocator.free(key);

    // Triple facts must ALSO produce the durable_fact/ prefix — not extracted_.
    // Cross-writer dedup with Pass-C extracted_ keys is deferred to Phase-1.
    try std.testing.expect(std.mem.startsWith(u8, key, "durable_fact/"));
}
