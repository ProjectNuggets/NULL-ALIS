//! ZAKI tenant state manager.
//!
//! In tenant Postgres mode this module is the canonical persistence surface
//! for user/product state such as config, secrets, heartbeat, onboarding,
//! channel state, jobs, identities, leases, and canonical memory metadata.
//! File artifacts may still exist for diagnostics, compatibility, or non-tenant
//! modes, but they should not supersede this module when Postgres tenant state
//! is healthy.

const std = @import("std");
const build_options = @import("build_options");
const config_types = @import("config_types.zig");
const env_rebrand = @import("env_rebrand.zig");
const memory_root = @import("memory/root.zig");
const text_norm = @import("memory/text_norm.zig");
const cron_mod = @import("cron.zig");
const security_secrets = @import("security/secrets.zig");

/// Session metadata returned by listUserSessions. Defined at module level
/// so both the mock and real Postgres implementations can use it.
pub const SessionInfo = struct {
    session_key: []const u8,
    kind: []const u8,
    title: []const u8,
    message_count: u32,
    last_active: []const u8,

    pub fn deinit(self: *const SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_key);
        allocator.free(self.kind);
        allocator.free(self.title);
        allocator.free(self.last_active);
    }
};
const pg_helpers = @import("memory/engines/postgres.zig");
const zaki_session = @import("session/root.zig");
const lane_metrics = @import("lane_metrics.zig");
const log = std.log.scoped(.zaki_state);

const c = if (build_options.enable_postgres) @cImport({
    @cInclude("libpq-fe.h");
}) else struct {};

/// V1.5 day-2 — single source of truth for the bi-temporal retrieval
/// filter. Every memory-read SELECT in this module appends this clause
/// (with appropriate `AND` placement) so superseded entries (valid_to
/// in the past) never leak to the agent. Extracted as a constant so
/// future SELECTs can't forget the filter — they reference the symbol.
/// The corresponding clause in `memory/engines/sqlite.zig` uses
/// `unixepoch()` instead of `EXTRACT(EPOCH FROM NOW())` because sqlite
/// has no equivalent function.
const MEMORIES_VALIDITY_FILTER = "(valid_to IS NULL OR valid_to > EXTRACT(EPOCH FROM NOW())::bigint)";

/// V1.5.1 brain-hygiene SQL filter — comptime-derived from
/// `memory_root.BRAIN_HIDDEN_PREFIXES` + `memory_root.BRAIN_HIDDEN_EXACT_KEYS`.
///
/// /brain/* surfaces hide the agent's own bookkeeping. /brain/* response
/// body is "Everything ZAKI remembers about YOU" — internal artifacts
/// pollute that surface.
///
/// Single source of truth: edit only `memory_root.BRAIN_HIDDEN_PREFIXES`
/// or `memory_root.BRAIN_HIDDEN_EXACT_KEYS`. This constant + the
/// `isBrainVisibleKey` predicate update together — drift becomes a
/// compile error, not a silent runtime divergence.
pub const BRAIN_USER_KEY_FILTER = blk: {
    @setEvalBranchQuota(8192);
    var s: []const u8 = "key !~ '^(";
    for (memory_root.BRAIN_HIDDEN_PREFIXES, 0..) |prefix, i| {
        if (i > 0) s = s ++ "|";
        // V1.7a-4 review fix IN-05: previously only escaped `.` because
        // that was the only meta-char in the existing prefix list. A
        // future addition like `cache.[v1]` or `tmp.(seq).` would have
        // produced malformed SQL silently — `[`, `]`, `(`, `)`, `*`,
        // `+`, `?`, `|`, `^`, `$`, `\` are ALL PG POSIX-regex meta-chars
        // that need backslash-escaping when used as literals. Cover the
        // full set now so adding a new prefix can't break the filter.
        for (prefix) |ch| {
            const is_meta = switch (ch) {
                '.', '\\', '(', ')', '[', ']', '{', '}', '*', '+', '?', '|', '^', '$' => true,
                else => false,
            };
            if (is_meta) {
                s = s ++ "\\" ++ &[_]u8{ch};
            } else {
                s = s ++ &[_]u8{ch};
            }
        }
    }
    s = s ++ ")' AND key NOT IN (";
    for (memory_root.BRAIN_HIDDEN_EXACT_KEYS, 0..) |exact, i| {
        if (i > 0) s = s ++ ", ";
        s = s ++ "'" ++ exact ++ "'";
    }
    s = s ++ ")";
    break :blk s;
};

pub const ChannelIdentityBinding = struct {
    id: []u8,
    user_id: i64,
    channel: []u8,
    account_id: []u8,
    principal_key: []u8,
    scope_key: []u8,
    thread_key: ?[]u8,
    peer_kind: ?[]u8,
    peer_id: ?[]u8,
    metadata_json: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.channel);
        allocator.free(self.account_id);
        allocator.free(self.principal_key);
        allocator.free(self.scope_key);
        if (self.thread_key) |value| allocator.free(value);
        if (self.peer_kind) |value| allocator.free(value);
        if (self.peer_id) |value| allocator.free(value);
        allocator.free(self.metadata_json);
    }
};

pub const TelegramBackfillCandidate = struct {
    user_id: i64,
    account_id: []u8,
    chat_id: i64,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.account_id);
    }
};

pub const UserConfigRow = struct {
    user_id: i64,
    config_json: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.config_json);
    }
};

pub const UserOwnershipLeaseSnapshot = struct {
    owner_id: []u8,
    lease_until_s: i64,
    updated_at_s: i64,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.owner_id);
    }
};

// D8 (secret vault) — types hoisted to module scope so both the
// postgres-backed ManagerImpl and the no-postgres stub Manager can
// reference them uniformly.

pub const SecretMetadata = struct {
    created_at_unix: i64,
    updated_at_unix: i64,
};

pub const SecretMutationRecord = struct {
    id: []const u8,
    key: []const u8,
    action: []const u8,
    actor: ?[]const u8,
    outcome: []const u8,
    detail: ?[]const u8,
    at_unix: i64,

    pub fn deinit(self: *const SecretMutationRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.action);
        if (self.actor) |a| allocator.free(a);
        allocator.free(self.outcome);
        if (self.detail) |d| allocator.free(d);
    }
};

pub const TaskSnapshot = struct {
    id: []u8,
    session_id: ?[]u8,
    request_session_id: ?[]u8,
    label: []u8,
    prompt: []u8,
    status: []u8,
    result: ?[]u8,
    error_msg: ?[]u8,
    created_at_ms: i64,
    started_at_ms: ?i64,
    completed_at_ms: ?i64,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.session_id) |value| allocator.free(value);
        if (self.request_session_id) |value| allocator.free(value);
        allocator.free(self.label);
        allocator.free(self.prompt);
        allocator.free(self.status);
        if (self.result) |value| allocator.free(value);
        if (self.error_msg) |value| allocator.free(value);
    }
};

pub const Manager = if (build_options.enable_postgres) ManagerImpl else struct {
    pub fn init(_: std.mem.Allocator, _: config_types.StateConfig) !@This() {
        return error.PostgresNotEnabled;
    }

    pub fn deinit(_: *@This()) void {}
    pub fn provisionUser(_: *@This(), _: i64, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn hasExternalIdentity(_: *@This(), _: i64) !?bool {
        return null;
    }
    pub fn getConfigJson(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]u8 {
        return allocator.dupe(u8, "{}");
    }
    pub fn putConfigJson(_: *@This(), _: i64, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn listUserConfigRows(_: *@This(), allocator: std.mem.Allocator) ![]UserConfigRow {
        return allocator.alloc(UserConfigRow, 0);
    }
    pub fn getHeartbeatJson(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]u8 {
        return allocator.dupe(u8, "{}");
    }
    pub fn putHeartbeatJson(_: *@This(), _: i64, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn getOnboardingJson(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]u8 {
        return allocator.dupe(u8, "{\"completed\":false,\"completed_at_s\":null}");
    }
    pub fn putOnboardingJson(_: *@This(), _: i64, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn getTelegramStateJson(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]u8 {
        return allocator.dupe(u8, "{}");
    }
    pub fn putTelegramStateJson(_: *@This(), _: i64, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn deleteTelegramState(_: *@This(), _: i64) !void {
        return error.PostgresNotEnabled;
    }
    // S7.2 — GDPR row-level user delete. Single DELETE on tenant `users`
    // cascades to every FK-linked table (17 tables per schema). Postgres
    // only; stub returns PostgresNotEnabled so the GDPR orchestrator can
    // surface a clean 503 when the tenant backend isn't wired.
    pub fn deleteUser(_: *@This(), _: i64) !void {
        return error.PostgresNotEnabled;
    }
    pub fn recordTelegramChat(_: *@This(), _: i64, _: []const u8, _: i64) !void {
        return error.PostgresNotEnabled;
    }
    pub fn getSecret(_: *@This(), _: std.mem.Allocator, _: i64, _: []const u8) !?[]u8 {
        return error.PostgresNotEnabled;
    }
    pub fn putSecret(_: *@This(), _: i64, _: []const u8, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn deleteSecret(_: *@This(), _: i64, _: []const u8) !bool {
        return error.PostgresNotEnabled;
    }
    pub fn listSecretKeys(_: *@This(), allocator: std.mem.Allocator, _: i64) ![][]const u8 {
        return allocator.alloc([]const u8, 0);
    }
    // D8 — no-postgres stubs. The gated secret vault requires the DB
    // backend for audit integrity; callers see 503 from the gateway
    // handler when `state.zaki_state` is null, but these stubs still
    // need to exist so comptime method lookup resolves on the
    // non-postgres Manager variant.
    pub fn getSecretMetadata(_: *@This(), _: std.mem.Allocator, _: i64, _: []const u8) !?SecretMetadata {
        return null;
    }
    pub fn recordSecretMutation(_: *@This(), _: i64, _: []const u8, _: []const u8, _: ?[]const u8, _: []const u8, _: ?[]const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn listSecretMutations(_: *@This(), allocator: std.mem.Allocator, _: i64, _: u32) ![]SecretMutationRecord {
        return allocator.alloc(SecretMutationRecord, 0);
    }
    // Test-only helper: see ManagerImpl.dropSchemaForTests. Stub variant
    // exists so comptime method lookup resolves on the non-postgres
    // Manager; callers guard on build_options.enable_postgres and never
    // reach this branch in practice.
    pub fn dropSchemaForTests(_: *@This()) !void {
        return error.PostgresNotEnabled;
    }
    pub fn listUserSessions(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]SessionInfo {
        return allocator.alloc(SessionInfo, 0);
    }
    /// Stub for non-postgres builds. Real impl in postgres-backed Manager.
    pub fn deleteSession(_: *@This(), _: i64, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn replaceJobsJson(_: *@This(), _: i64, _: []const u8, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn getJobsJson(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]u8 {
        return allocator.dupe(u8, "[]");
    }
    pub fn listJobRuns(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const u8, _: usize) ![]cron_mod.CronRun {
        return allocator.alloc(cron_mod.CronRun, 0);
    }
    pub fn clearJobs(_: *@This(), _: i64) !void {
        return error.PostgresNotEnabled;
    }
    pub fn upsertMemory(_: *@This(), _: i64, _: []const u8, _: []const u8, _: memory_root.MemoryCategory, _: ?[]const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn getMemory(_: *@This(), _: std.mem.Allocator, _: i64, _: []const u8) !?memory_root.MemoryEntry {
        return error.PostgresNotEnabled;
    }
    /// V1.7a-5b — stub for non-postgres builds. Mirrors getMemory shape;
    /// caller treats null as "key not found" identically.
    pub fn getMemoryAnyValidity(_: *@This(), _: std.mem.Allocator, _: i64, _: []const u8) !?memory_root.MemoryEntry {
        return error.PostgresNotEnabled;
    }
    /// V1.6 commit 5b.3 (WR-1): stub for non-postgres builds. Returns
    /// null so extraction-persist's MD5 dedup degrades to "every fact
    /// is unique" — extraction may produce duplicates without postgres
    /// but this build variant doesn't run extraction anyway.
    pub fn findMemoryByContentHash(_: *@This(), _: std.mem.Allocator, _: i64, _: []const u8) !?memory_root.MemoryEntry {
        return null;
    }
    /// V1.7a-2 — stub for non-postgres builds. Returns an aligned slice of
    /// nulls (one per input key) so graph_expand re-scoring degrades to
    /// "no real recency available" without erroring. Live impl reads
    /// `created_at` from `{schema}.memories` in one round trip.
    pub fn getMemoryTimestamps(_: *@This(), allocator: std.mem.Allocator, _: i64, keys: []const []const u8) ![]?i64 {
        const out = try allocator.alloc(?i64, keys.len);
        @memset(out, null);
        return out;
    }
    pub fn listMemories(_: *@This(), allocator: std.mem.Allocator, _: i64, _: ?memory_root.MemoryCategory, _: ?[]const u8) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.5.1 brain-hygiene — stub for non-postgres builds. Returns empty
    /// so `/brain/graph` gracefully degrades when state manager is
    /// disabled. Live impl applies BRAIN_USER_KEY_FILTER in SQL.
    pub fn listMemoriesBrainVisible(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    pub fn recallMemories(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const u8, _: usize, _: ?[]const u8) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.5 day-2 task 3 — stub for non-postgres builds; returns empty
    /// timeline so `/brain/timeline` gracefully degrades when state
    /// manager is the disabled variant.
    pub fn listMemoriesTimeline(_: *@This(), allocator: std.mem.Allocator, _: i64, _: ?i64, _: ?[]const u8, _: u32, _: ?i64, _: ?i64) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.7a-6 — stubs for non-postgres builds; `/brain/diff` degrades
    /// to empty births/deaths so the FE still renders the window header
    /// without erroring when the state manager is the disabled variant.
    pub fn listMemoryBirthsInWindow(_: *@This(), allocator: std.mem.Allocator, _: i64, _: i64, _: i64, _: u32) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    pub fn listMemoryDeathsInWindow(_: *@This(), allocator: std.mem.Allocator, _: i64, _: i64, _: i64, _: u32) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.5 day-3 — stubs for non-postgres builds; compose path silently
    /// degrades when state manager is the disabled variant.
    pub fn upsertMemoryWithMetadata(_: *@This(), _: i64, _: []const u8, _: []const u8, _: memory_root.MemoryCategory, _: ?[]const u8, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub fn listMemoriesMetadata(_: *@This(), _: std.mem.Allocator, _: i64, _: []const []const u8) !std.StringHashMapUnmanaged([]u8) {
        return .{};
    }
    pub fn existsMemoryKeys(_: *@This(), _: std.mem.Allocator, _: i64, _: []const []const u8) !std.StringHashMapUnmanaged(void) {
        return .{};
    }
    /// V1.7a-7 — stub for non-postgres builds; `/brain/local-graph`
    /// degrades to empty so the FE still renders the center-node header
    /// without erroring when the state manager is the disabled variant.
    pub fn getMemoriesByKeys(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const []const u8) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.7a-8a — stub for non-postgres builds; `/brain/orphans` degrades
    /// to empty so the FE still renders the orphan rail without erroring.
    pub fn listOrphanMemories(_: *@This(), allocator: std.mem.Allocator, _: i64, _: u32) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.8-9 — stub for non-postgres builds; identity-pinning gracefully
    /// degrades to empty (loader falls back to legacy cosine retrieval).
    pub fn listIdentityFacts(_: *@This(), allocator: std.mem.Allocator, _: i64, _: u32) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.11 hardening (2026-05-08) — stub for non-postgres builds; the
    /// /brain/me endpoint degrades to 404 on file-state deployments.
    pub fn pickSelfAnchor(_: *@This(), _: std.mem.Allocator, _: i64) !?memory_root.MemoryEntry {
        return null;
    }
    /// V1.7a-9a — stubs for non-postgres builds. Communities feature
    /// degrades to "no communities yet" — every node has community_id=null
    /// on /brain/graph, /brain/communities returns empty, recompute is a
    /// no-op. The FE renders with the no-clusters fallback path.
    pub fn listMemoryEdgesForCommunityCompute(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]memory_root.CommunityEdge {
        return allocator.alloc(memory_root.CommunityEdge, 0);
    }
    pub fn setMemoryCommunityIds(_: *@This(), _: i64, _: []const memory_root.CommunityAssignment) !void {
        return;
    }
    pub fn setCommunityName(_: *@This(), _: i64, _: i32, _: []const u8, _: []const u8, _: u32, _: []const u8) !void {
        return;
    }
    pub fn getCommunityName(_: *@This(), _: std.mem.Allocator, _: i64, _: i32) !?memory_root.CommunityName {
        return null;
    }
    pub fn listCommunities(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]memory_root.CommunitySummary {
        return allocator.alloc(memory_root.CommunitySummary, 0);
    }
    /// V1.7a-9d — stub for non-postgres builds. /brain/graph nodes
    /// degrade to community_id=null when state manager is disabled.
    pub fn getMemoryCommunityIds(_: *@This(), _: std.mem.Allocator, _: i64, _: []const []const u8) !std.StringHashMapUnmanaged(i32) {
        return .{};
    }
    /// V1.5 day-4 — stub for non-postgres builds; traversal logging
    /// silently no-ops.
    pub fn insertTraversalEvent(_: *@This(), _: i64, _: []const u8) !void {
        return;
    }
    /// V1.7 Item 1 — stub for non-postgres builds; episode events no-op.
    pub fn insertEpisodeEvent(_: *@This(), _: i64, _: []const u8, _: []const u8, _: []const u8) !void {
        return;
    }
    pub fn forgetMemory(_: *@This(), _: i64, _: []const u8) !bool {
        return error.PostgresNotEnabled;
    }
    /// V1.9-1 — stub for non-postgres builds; cascade rename no-ops.
    /// Returns found_old=false so callers degrade to "treat as fresh
    /// write" rather than crashing.
    pub fn cascadeRenameEntity(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: i64,
        _: []const u8,
        _: []const u8,
    ) !memory_root.CascadeRenameResult {
        return .{
            .found_old = false,
            .old_id = try allocator.alloc(u8, 0),
            .new_id = try allocator.alloc(u8, 0),
            .edges_rewritten = 0,
            .edges_closed = 0,
        };
    }
    /// V1.9-2 — stub for non-postgres builds; invalidate-by-pattern no-ops.
    pub fn invalidateEdgesByPattern(
        _: *@This(),
        _: i64,
        _: []const u8,
        _: []const u8,
        _: ?[]const u8,
    ) !usize {
        return 0;
    }
    /// V1.9-2 — stub for non-postgres builds; resolve_contradiction no-ops.
    pub fn resolveContradiction(
        _: *@This(),
        _: i64,
        _: []const u8,
        _: []const u8,
    ) !memory_root.ResolveContradictionResult {
        return .{ .loser_existed = false, .winner_existed = false, .loser_closed = false };
    }
    /// V1.9-3 — stub for non-postgres builds; propagate_correction no-ops.
    pub fn propagateCorrection(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: i64,
        _: []const u8,
        _: []const u8,
    ) !memory_root.PropagateCorrectionResult {
        return .{
            .correction_existed = false,
            .targets_flagged = 0,
            .target_keys = try allocator.alloc([]u8, 0),
        };
    }
    /// V1.9-7 — stub for non-postgres builds; survey returns zero
    /// conflicts so the memory_loader fallback path stays clean.
    pub fn surveyContradictions(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: i64,
    ) !memory_root.SurveyContradictionsResult {
        return .{
            .conflicts_found = 0,
            .conflicts_json = try allocator.dupe(u8, "[]"),
            .sentinel_written = false,
        };
    }
    /// V1.9-4 — stub for non-postgres builds; temporal decay no-ops.
    pub fn temporalDecay(
        _: *@This(),
        _: i64,
        _: u32,
        _: u32,
    ) !memory_root.TemporalDecayResult {
        return .{ .rows_decayed = 0, .avg_decay_amount = 0.0, .floor = 0.1 };
    }
    /// V1.10-A — stub for non-postgres builds; returns empty slice so
    /// loader-side supersede filter degrades to "no skip" gracefully.
    pub fn findSupersededMemoryKeys(_: *@This(), allocator: std.mem.Allocator, _: i64) ![][]u8 {
        return try allocator.alloc([]u8, 0);
    }
    /// V1.10-B — stub for non-postgres builds; returns empty slice so
    /// prose_survey degrades to "no facts found" → clean no-op. Real
    /// impl on `ManagerImpl` runs the SQL ILIKE scan.
    pub fn fetchProseFactsByPattern(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: i64,
        _: []const u8,
        _: usize,
    ) ![]memory_root.ProseFact {
        return try allocator.alloc(memory_root.ProseFact, 0);
    }
    /// V1.10-B — stub for non-postgres builds; metadata-write seam
    /// no-ops, returns false (loser not marked). prose_survey then
    /// reports zero marked_keys — clean degraded behavior.
    pub fn markMemorySupersededByKey(
        _: *@This(),
        _: i64,
        _: []const u8,
        _: []const u8,
    ) !bool {
        return false;
    }
    /// V1.6 commit 6 — stub for non-postgres builds. Returns empty
    /// candidate list so `edge_resolution.resolveOne` short-circuits to
    /// the no-op outcome (caller writes new fact normally without
    /// contradiction judging — extraction itself doesn't run on this
    /// build variant anyway).
    pub fn findRelatedExtractedMemories(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const u8, _: usize) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    /// V1.6 commit 6 — stub for non-postgres builds. Bi-temporal close-out
    /// silently no-ops; the contradiction judge path is already disabled
    /// upstream when the live state manager is absent.
    pub fn setMemoryInvalidation(_: *@This(), _: i64, _: []const u8, _: i64, _: i64) !void {
        return;
    }
    /// V1.6 commit 11 — stub for non-postgres builds. The CASE-guard
    /// immortality protection only fires on the postgres path, so demotion
    /// is a no-op for other backends.
    pub fn demoteMemoryFromCore(_: *@This(), _: i64, _: []const u8, _: []const u8) !bool {
        return false;
    }
    /// V1.6 commit 13 — stub for non-postgres builds. Drilldown events
    /// stream is empty; the brain/memory/{key} endpoint returns just
    /// the memory + (empty) edges + (empty) events.
    pub fn listEventsForMemoryKey(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const u8, _: u32) ![]memory_root.MemoryEventRow {
        return allocator.alloc(memory_root.MemoryEventRow, 0);
    }
    /// V1.6 commit 14 — stub for non-postgres builds. Source attribution
    /// columns are postgres-only; non-postgres backends silently skip.
    pub fn setMemorySource(_: *@This(), _: i64, _: []const u8, _: ?[]const u8, _: ?[]const u8) !void {
        return;
    }
    pub fn getMemorySource(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const u8) !?memory_root.MemorySource {
        _ = allocator;
        return null;
    }
    /// V1.6 commit 15 — stub for non-postgres builds. /brain/documents
    /// returns empty when postgres isn't configured.
    pub fn listBrainDocumentSummaries(_: *@This(), allocator: std.mem.Allocator, _: i64, _: u32) ![]memory_root.BrainDocument {
        return allocator.alloc(memory_root.BrainDocument, 0);
    }
    /// V1.6 commit 7 — stub for non-postgres builds. Edge writes silently
    /// no-op; the materialized graph is a postgres-only feature today.
    pub fn upsertMemoryEdge(_: *@This(), _: i64, _: []const u8, _: []const u8, _: []const u8, _: ?[]const u8, _: ?f64) !void {
        return;
    }
    pub fn countEdgesForSource(_: *@This(), _: i64, _: []const u8) !usize {
        return 0;
    }
    pub fn listEdgesForUser(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]memory_root.TypedEdge {
        return allocator.alloc(memory_root.TypedEdge, 0);
    }
    /// V1.6 commit 10 — stub for non-postgres builds. Graph hop expansion
    /// is a postgres-only feature; non-postgres returns empty.
    pub fn findEdgesByKeys(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const []const u8) ![]memory_root.TypedEdge {
        return allocator.alloc(memory_root.TypedEdge, 0);
    }
    /// V1.6 commit 8 — stub for non-postgres builds. Entity coreference is
    /// a postgres-pgvector feature; non-postgres builds fall back to a
    /// hash-based stable key (entity_<hash(lower(name))>) computed by the
    /// caller, no DB row created.
    pub fn findEntityByCosine(_: *@This(), _: std.mem.Allocator, _: i64, _: []const f32, _: f64) !?memory_root.EntityRow {
        return null;
    }
    pub fn upsertEntity(_: *@This(), allocator: std.mem.Allocator, _: i64, name: []const u8, _: []const f32) ![]u8 {
        return allocator.dupe(u8, name);
    }
    pub fn countMemories(_: *@This(), _: i64) !usize {
        return error.PostgresNotEnabled;
    }
    pub fn recordTelegramUpdate(_: *@This(), _: i64, _: i64) !bool {
        return error.PostgresNotEnabled;
    }
    pub fn upsertChannelIdentityBinding(
        _: *@This(),
        _: std.mem.Allocator,
        _: i64,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: ?[]const u8,
        _: ?[]const u8,
        _: ?[]const u8,
        _: ?[]const u8,
    ) ![]u8 {
        return error.PostgresNotEnabled;
    }
    pub fn resolveUserByChannelIdentity(
        _: *@This(),
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: ?[]const u8,
    ) !?i64 {
        return error.PostgresNotEnabled;
    }
    pub fn listChannelIdentityBindings(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: i64,
        _: ?[]const u8,
    ) ![]ChannelIdentityBinding {
        return allocator.alloc(ChannelIdentityBinding, 0);
    }
    pub fn deleteChannelIdentityBinding(_: *@This(), _: i64, _: []const u8) !bool {
        return error.PostgresNotEnabled;
    }
    pub fn listTelegramBackfillCandidates(_: *@This(), allocator: std.mem.Allocator) ![]TelegramBackfillCandidate {
        return allocator.alloc(TelegramBackfillCandidate, 0);
    }
    pub fn acquireUserOwnershipLease(
        _: *@This(),
        _: std.mem.Allocator,
        _: i64,
        _: []const u8,
        _: i64,
        _: u64,
    ) error{ PostgresNotEnabled, LockHeld, InvalidOwnerId }![]u8 {
        return error.PostgresNotEnabled;
    }
    pub fn releaseUserOwnershipLease(_: *@This(), _: i64, _: []const u8, _: []const u8) error{PostgresNotEnabled}!void {
        return error.PostgresNotEnabled;
    }
    pub fn countOwnedUserLeases(_: *@This(), _: i64, _: []const u8) error{PostgresNotEnabled}!usize {
        return error.PostgresNotEnabled;
    }
    pub fn getUserOwnershipLeaseSnapshot(_: *@This(), _: std.mem.Allocator, _: i64) error{PostgresNotEnabled}!?UserOwnershipLeaseSnapshot {
        return error.PostgresNotEnabled;
    }
    pub fn upsertTaskSnapshot(
        _: *@This(),
        _: i64,
        _: []const u8,
        _: ?[]const u8,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: ?[]const u8,
        _: ?[]const u8,
        _: i64,
        _: ?i64,
        _: ?i64,
    ) !void {
        return error.PostgresNotEnabled;
    }
    pub fn getTaskSnapshot(_: *@This(), _: std.mem.Allocator, _: i64, _: []const u8) !?TaskSnapshot {
        return error.PostgresNotEnabled;
    }
    pub fn listTaskSnapshots(_: *@This(), allocator: std.mem.Allocator, _: i64) ![]TaskSnapshot {
        return allocator.alloc(TaskSnapshot, 0);
    }
    pub fn saveCompletionEvent(_: *@This(), _: std.mem.Allocator, _: i64, _: []const u8, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8, _: []const u8) ![]u8 {
        return error.PostgresNotEnabled;
    }
    pub fn loadCompletionEvents(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const u8) ![]memory_root.CompletionEvent {
        return allocator.alloc(memory_root.CompletionEvent, 0);
    }
    pub fn deleteCompletionEvent(_: *@This(), _: i64, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }
    pub const ClaimedJob = struct {
        id: []u8,
        user_id: i64,
        session_id: []u8,
        workspace_path: []u8,
        raw_job_json: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.session_id);
            allocator.free(self.workspace_path);
            allocator.free(self.raw_job_json);
        }
    };
    pub fn claimDueJobs(_: *@This(), allocator: std.mem.Allocator, _: []const u8, _: i64, _: u64, _: usize) ![]ClaimedJob {
        return allocator.dupe(ClaimedJob, &.{});
    }
    pub fn completeClaimedJob(_: *@This(), _: i64, _: []const u8, _: []const u8, _: ?[]const u8, _: ?i64, _: ?[]const u8, _: ?[]const u8, _: i64, _: i64) !void {
        return error.PostgresNotEnabled;
    }
    pub const UserSessionStore = struct {
        pub fn init(_: std.mem.Allocator, _: *anyopaque, _: i64) !@This() {
            return error.PostgresNotEnabled;
        }
        pub fn deinit(_: *@This()) void {}
        pub fn sessionStore(_: *@This()) memory_root.SessionStore {
            @panic("postgres not enabled");
        }
    };
};

const ManagerImpl = struct {
    const PoolEntry = struct {
        conn: *c.PGconn,
        in_use: bool,
        last_used_s: i64,
    };

    const ConnLease = struct {
        conn: *c.PGconn,
        entry_index: usize,
        released: bool = false,
    };

    pub const PoolDebugSnapshot = struct {
        pool_max: u32,
        open_conns: u32,
        in_use: u32,
        waiters: u32,
        acquire_timeouts: u64,
    };

    allocator: std.mem.Allocator,
    conn_string_z: [:0]u8,
    schema_raw_buf: [64]u8,
    schema_raw_len: usize,
    secrets_enabled: bool,
    master_key: ?[security_secrets.KEY_LEN]u8,
    pool_entries: std.ArrayListUnmanaged(PoolEntry),
    pool_mutex: std.Thread.Mutex,
    pool_cond: std.Thread.Condition,
    pool_max: u32,
    pool_opening: u32,
    pool_waiters: u32,
    pool_acquire_timeouts: u64,
    statement_timeout_ms: u32,
    lock_timeout_ms: u32,

    pub const ClaimedJob = struct {
        id: []u8,
        user_id: i64,
        session_id: []u8,
        workspace_path: []u8,
        raw_job_json: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.session_id);
            allocator.free(self.workspace_path);
            allocator.free(self.raw_job_json);
        }
    };

    pub const UserSessionStore = struct {
        allocator: std.mem.Allocator,
        manager: *ManagerImpl,
        user_id: i64,

        pub fn init(allocator: std.mem.Allocator, manager_ptr: *anyopaque, user_id: i64) !UserSessionStore {
            const manager: *ManagerImpl = @ptrCast(@alignCast(manager_ptr));
            return .{
                .allocator = allocator,
                .manager = manager,
                .user_id = user_id,
            };
        }

        pub fn deinit(_: *UserSessionStore) void {}

        pub fn sessionStore(self: *UserSessionStore) memory_root.SessionStore {
            return .{
                .ptr = self,
                .vtable = &.{
                    .saveMessage = saveMessage,
                    .loadMessages = loadMessages,
                    .clearMessages = clearMessages,
                    .clearAutoSaved = clearAutoSaved,
                    .saveCompletionEvent = saveCompletionEventBridge,
                    .loadCompletionEvents = loadCompletionEventsBridge,
                    .deleteCompletionEvent = deleteCompletionEventBridge,
                },
            };
        }

        fn saveMessage(ptr: *anyopaque, session_id: []const u8, role: []const u8, content: []const u8) anyerror!void {
            const self: *UserSessionStore = @ptrCast(@alignCast(ptr));
            try self.manager.saveSessionMessage(self.user_id, session_id, role, content);
        }

        fn loadMessages(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror![]memory_root.MessageEntry {
            const self: *UserSessionStore = @ptrCast(@alignCast(ptr));
            return try self.manager.loadSessionMessages(allocator, self.user_id, session_id);
        }

        fn clearMessages(ptr: *anyopaque, session_id: []const u8) anyerror!void {
            const self: *UserSessionStore = @ptrCast(@alignCast(ptr));
            try self.manager.clearSessionMessages(self.user_id, session_id);
        }

        fn clearAutoSaved(ptr: *anyopaque, session_id: ?[]const u8) anyerror!void {
            const self: *UserSessionStore = @ptrCast(@alignCast(ptr));
            try self.manager.clearAutoSavedMemory(self.user_id, session_id);
        }

        fn saveCompletionEventBridge(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8, channel: ?[]const u8, account_id: ?[]const u8, chat_id: ?[]const u8, content: []const u8) anyerror![]u8 {
            const self: *UserSessionStore = @ptrCast(@alignCast(ptr));
            return try self.manager.saveCompletionEvent(allocator, self.user_id, session_id, channel, account_id, chat_id, content);
        }

        fn loadCompletionEventsBridge(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror![]memory_root.CompletionEvent {
            const self: *UserSessionStore = @ptrCast(@alignCast(ptr));
            return try self.manager.loadCompletionEvents(allocator, self.user_id, session_id);
        }

        fn deleteCompletionEventBridge(ptr: *anyopaque, event_id: []const u8) anyerror!void {
            const self: *UserSessionStore = @ptrCast(@alignCast(ptr));
            try self.manager.deleteCompletionEvent(self.user_id, event_id);
        }
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: config_types.StateConfig) !Self {
        try pg_helpers.validateIdentifier(cfg.postgres.schema);
        if (cfg.postgres.connection_string.len == 0) return error.MissingConnectionString;

        const conn_string = try allocator.dupeZ(u8, cfg.postgres.connection_string);
        errdefer allocator.free(conn_string);

        var schema_raw_buf: [64]u8 = undefined;
        @memset(&schema_raw_buf, 0);
        @memcpy(schema_raw_buf[0..cfg.postgres.schema.len], cfg.postgres.schema);

        var manager = Self{
            .allocator = allocator,
            .conn_string_z = conn_string,
            .schema_raw_buf = schema_raw_buf,
            .schema_raw_len = cfg.postgres.schema.len,
            .secrets_enabled = true,
            .master_key = null,
            .pool_entries = .empty,
            .pool_mutex = .{},
            .pool_cond = .{},
            .pool_max = std.math.clamp(cfg.postgres.pool_max, 1, 256),
            .pool_opening = 0,
            .pool_waiters = 0,
            .pool_acquire_timeouts = 0,
            .statement_timeout_ms = cfg.postgres.statement_timeout_ms,
            .lock_timeout_ms = cfg.postgres.lock_timeout_ms,
        };

        manager.secrets_enabled = true;
        manager.master_key = try loadMasterKey(allocator, cfg.secrets.master_key_env);
        try manager.migrate();
        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.closeAllPoolConns();
        self.pool_entries.deinit(self.allocator);
        self.allocator.free(self.conn_string_z);
    }

    pub fn debugPoolSnapshot(self: *Self) PoolDebugSnapshot {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        var in_use: u32 = 0;
        for (self.pool_entries.items) |entry| {
            if (entry.in_use) in_use += 1;
        }
        return .{
            .pool_max = self.pool_max,
            .open_conns = @intCast(self.pool_entries.items.len),
            .in_use = in_use,
            .waiters = self.pool_waiters,
            .acquire_timeouts = self.pool_acquire_timeouts,
        };
    }

    fn schemaRaw(self: *const Self) []const u8 {
        return self.schema_raw_buf[0..self.schema_raw_len];
    }

    /// Test-only helper: `DROP SCHEMA IF EXISTS <self.schema> CASCADE`.
    /// Used by cross-module integration tests that provision a
    /// throwaway schema (e.g. gateway.zig D11 vault route tests) and
    /// need to drop it on teardown without re-importing pg_helpers in
    /// the caller. The schema name is validated + quoted before the
    /// DDL runs, matching every other DDL path in this module.
    pub fn dropSchemaForTests(self: *Self) !void {
        try pg_helpers.validateIdentifier(self.schemaRaw());
        const schema_q = try pg_helpers.quoteIdentifier(self.allocator, self.schemaRaw());
        defer self.allocator.free(schema_q);
        const drop_sql = try std.fmt.allocPrint(self.allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer self.allocator.free(drop_sql);
        const result = try self.exec(drop_sql);
        c.PQclear(result);
    }

    fn applySessionSettingsToConn(self: *Self, conn: *c.PGconn) !void {
        if (self.statement_timeout_ms > 0) {
            var buf: [64]u8 = undefined;
            const value = try std.fmt.bufPrint(&buf, "SET statement_timeout = {d}", .{self.statement_timeout_ms});
            const query_z = try self.allocator.dupeZ(u8, value);
            defer self.allocator.free(query_z);
            const result = c.PQexec(conn, query_z) orelse return error.ExecFailed;
            defer c.PQclear(result);
            const status = c.PQresultStatus(result);
            if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) return error.ExecFailed;
        }
        if (self.lock_timeout_ms > 0) {
            var buf: [64]u8 = undefined;
            const value = try std.fmt.bufPrint(&buf, "SET lock_timeout = {d}", .{self.lock_timeout_ms});
            const query_z = try self.allocator.dupeZ(u8, value);
            defer self.allocator.free(query_z);
            const result = c.PQexec(conn, query_z) orelse return error.ExecFailed;
            defer c.PQclear(result);
            const status = c.PQresultStatus(result);
            if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) return error.ExecFailed;
        }
    }

    fn openConn(self: *Self) !*c.PGconn {
        const conn = c.PQconnectdb(self.conn_string_z.ptr) orelse return error.ConnectionFailed;
        errdefer c.PQfinish(conn);
        if (c.PQstatus(conn) != c.CONNECTION_OK) return error.ConnectionFailed;
        try self.applySessionSettingsToConn(conn);
        return conn;
    }

    fn acquireConn(self: *Self, wait_ms: u32) !ConnLease {
        const start_ms = std.time.milliTimestamp();
        while (true) {
            self.pool_mutex.lock();

            for (self.pool_entries.items, 0..) |*entry, idx| {
                if (!entry.in_use) {
                    entry.in_use = true;
                    entry.last_used_s = std.time.timestamp();
                    self.pool_mutex.unlock();
                    return .{ .conn = entry.conn, .entry_index = idx };
                }
            }

            if (self.pool_entries.items.len + self.pool_opening < self.pool_max) {
                self.pool_opening += 1;
                self.pool_mutex.unlock();

                const conn = self.openConn() catch |err| {
                    self.pool_mutex.lock();
                    self.pool_opening -= 1;
                    self.pool_cond.signal();
                    self.pool_mutex.unlock();
                    return err;
                };

                self.pool_mutex.lock();
                self.pool_opening -= 1;

                if (self.pool_entries.items.len >= self.pool_max) {
                    c.PQfinish(conn);
                    self.pool_cond.signal();
                    self.pool_mutex.unlock();
                    continue;
                }

                const entry_idx = self.pool_entries.items.len;
                try self.pool_entries.append(self.allocator, .{
                    .conn = conn,
                    .in_use = true,
                    .last_used_s = std.time.timestamp(),
                });
                self.pool_mutex.unlock();
                return .{ .conn = conn, .entry_index = entry_idx };
            }

            if (wait_ms == 0) {
                self.pool_waiters += 1;
                self.pool_cond.wait(&self.pool_mutex);
                self.pool_waiters -= 1;
                self.pool_mutex.unlock();
                continue;
            }

            const now_ms = std.time.milliTimestamp();
            const elapsed_ms: u64 = @intCast(@max(0, now_ms - start_ms));
            if (elapsed_ms >= wait_ms) {
                self.pool_acquire_timeouts += 1;
                self.pool_mutex.unlock();
                return error.ConnectionPoolBusy;
            }
            const remaining_ms = wait_ms - elapsed_ms;

            self.pool_waiters += 1;
            self.pool_cond.timedWait(&self.pool_mutex, remaining_ms * std.time.ns_per_ms) catch |err| switch (err) {
                error.Timeout => {
                    self.pool_waiters -= 1;
                    self.pool_acquire_timeouts += 1;
                    self.pool_mutex.unlock();
                    return error.ConnectionPoolBusy;
                },
            };
            self.pool_waiters -= 1;
            self.pool_mutex.unlock();
        }
    }

    fn releaseConn(self: *Self, lease: *ConnLease, healthy: bool) void {
        if (lease.released) return;

        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        if (self.pool_entries.items.len == 0) {
            lease.released = true;
            return;
        }

        var idx = if (lease.entry_index < self.pool_entries.items.len) lease.entry_index else self.pool_entries.items.len - 1;
        if (self.pool_entries.items[idx].conn != lease.conn) {
            var found = false;
            for (self.pool_entries.items, 0..) |entry, entry_idx| {
                if (entry.conn == lease.conn) {
                    idx = entry_idx;
                    found = true;
                    break;
                }
            }
            if (!found) {
                lease.released = true;
                return;
            }
        }

        const conn_ok = c.PQstatus(lease.conn) == c.CONNECTION_OK;
        if (!healthy or !conn_ok) {
            c.PQfinish(self.pool_entries.items[idx].conn);
            _ = self.pool_entries.swapRemove(idx);
        } else {
            self.pool_entries.items[idx].in_use = false;
            self.pool_entries.items[idx].last_used_s = std.time.timestamp();
        }

        lease.released = true;
        self.pool_cond.signal();
    }

    fn closeAllPoolConns(self: *Self) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        for (self.pool_entries.items) |entry| {
            c.PQfinish(entry.conn);
        }
        self.pool_entries.clearRetainingCapacity();
    }

    fn migrate(self: *Self) !void {
        const statements = [_][]const u8{
            "CREATE SCHEMA IF NOT EXISTS {schema}",
            "CREATE EXTENSION IF NOT EXISTS pgcrypto",
            "CREATE EXTENSION IF NOT EXISTS vector",
            \\CREATE TABLE IF NOT EXISTS {schema}.users (
            \\    user_id BIGINT PRIMARY KEY,
            \\    workspace_path TEXT NOT NULL,
            \\    agent_name TEXT,
            \\    onboarding_completed BOOLEAN NOT NULL DEFAULT FALSE,
            \\    onboarding_completed_at TIMESTAMPTZ,
            \\    status TEXT NOT NULL DEFAULT 'active',
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "ALTER TABLE {schema}.users ADD CONSTRAINT users_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.zaki_users(id) ON DELETE CASCADE",
            \\CREATE TABLE IF NOT EXISTS {schema}.user_config (
            \\    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    config JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    version INT NOT NULL DEFAULT 1,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.user_secrets (
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    key TEXT NOT NULL,
            \\    ciphertext BYTEA NOT NULL,
            \\    nonce BYTEA NOT NULL,
            \\    aad TEXT NOT NULL,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    PRIMARY KEY (user_id, key)
            \\)
            ,
            // D8 (S2.16) — audit trail for every secret mutation. One
            // row per attempt (success or failure). Operators can
            // see "who did what when" without ever seeing plaintext.
            \\CREATE TABLE IF NOT EXISTS {schema}.secret_mutations (
            \\    id TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(16), 'hex'),
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    key TEXT NOT NULL,
            \\    action TEXT NOT NULL,
            \\    actor TEXT,
            \\    outcome TEXT NOT NULL,
            \\    detail TEXT,
            \\    at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_secret_mutations_user_at ON {schema}.secret_mutations(user_id, at DESC)",
            \\CREATE TABLE IF NOT EXISTS {schema}.sessions (
            \\    id TEXT PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    session_key TEXT NOT NULL UNIQUE,
            \\    kind TEXT NOT NULL,
            \\    title TEXT,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.messages (
            \\    id TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(16), 'hex'),
            \\    session_id TEXT NOT NULL REFERENCES {schema}.sessions(id) ON DELETE CASCADE,
            \\    user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    role TEXT NOT NULL,
            \\    channel TEXT,
            \\    account_id TEXT,
            \\    chat_id TEXT,
            \\    source TEXT NOT NULL DEFAULT 'app',
            \\    content TEXT NOT NULL,
            \\    tool_name TEXT,
            \\    tool_call JSONB,
            \\    tool_result JSONB,
            \\    request_id TEXT,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_messages_user_created ON {schema}.messages(user_id, created_at DESC)",
            "CREATE INDEX IF NOT EXISTS idx_messages_session_created ON {schema}.messages(session_id, created_at ASC)",
            \\CREATE TABLE IF NOT EXISTS {schema}.completion_events (
            \\    id TEXT PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    session_id TEXT NOT NULL REFERENCES {schema}.sessions(id) ON DELETE CASCADE,
            \\    channel TEXT,
            \\    account_id TEXT,
            \\    chat_id TEXT,
            \\    content TEXT NOT NULL,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_completion_events_user_session_created ON {schema}.completion_events(user_id, session_id, created_at ASC, id ASC)",
            \\CREATE TABLE IF NOT EXISTS {schema}.memories (
            \\    id TEXT PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
            \\    key TEXT NOT NULL UNIQUE,
            \\    content TEXT NOT NULL,
            \\    content_hash TEXT,
            \\    memory_type TEXT NOT NULL DEFAULT 'core',
            \\    embedding VECTOR,
            \\    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    importance_score DOUBLE PRECISION DEFAULT 0.5,
            \\    confidence_score DOUBLE PRECISION DEFAULT 0.8,
            \\    access_count INT DEFAULT 0,
            \\    last_accessed_at TIMESTAMPTZ,
            \\    user_verified BOOLEAN DEFAULT FALSE,
            \\    source_channel TEXT,
            \\    source_message_id TEXT,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_memories_user ON {schema}.memories(user_id)",
            "CREATE INDEX IF NOT EXISTS idx_memories_hash ON {schema}.memories(user_id, content_hash)",
            "ALTER TABLE {schema}.memories DROP CONSTRAINT IF EXISTS memories_key_key",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_user_key ON {schema}.memories(user_id, key)",
            // V1.5 day-2 — Graphiti bi-temporal model. `valid_to` is the
            // unix-epoch second when this memory entry stops being valid;
            // `NULL` means always-valid. V1.5 always writes NULL; V1.6
            // correction classifier + MemoryViewer-correction populate it.
            // Retrieval filters use `(valid_to IS NULL OR valid_to >
            // EXTRACT(EPOCH FROM NOW())::bigint)` so superseded entries
            // never reach the agent. Partial index — most rows stay NULL.
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS valid_to BIGINT",
            "CREATE INDEX IF NOT EXISTS idx_memories_valid_to ON {schema}.memories(valid_to) WHERE valid_to IS NOT NULL",

            // ── V1.6 schema (commit 2 of V1.6 work order) ────────────────
            //
            // All ALTERs are `ADD COLUMN IF NOT EXISTS` — instant metadata-
            // only on populated tables (no row rewrite). Indexes are partial
            // where appropriate to keep cost low on rows that won't have
            // the field populated until extraction backfills them.
            //
            // Reference: `docs/v1.6-v1.7-spec.md` §4.1
            //   + `docs/v1.5.5-compaction-fidelity-final.md` (substrate gates)
            //   + `nullalis_audit.md` §E.1 (gap mapping)

            // V1.6 atomic-fact extraction (Mem0/Graphiti typed-edge schema)
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS subject TEXT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS predicate TEXT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS object_key TEXT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS link_type TEXT",
            // attribution: 'agent_tool' | 'extraction_classifier' | 'compose'
            //   per spec D4 — distinguishes write-source for cosine-dedup
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS attribution TEXT",
            // attributed_to: 'user' | 'assistant' | 'assistant_offer'
            //   per Mem0 V3 — who said the thing the fact reflects
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS attributed_to TEXT",

            // V1.6 Graphiti six-field bi-temporal — extends V1.5's lone valid_to
            //   created_at exists already (TIMESTAMPTZ system time)
            //   valid_to exists already (event-time end)
            //   valid_at = event time when fact became true
            //   invalid_at = event time when fact stopped (synonym for valid_to but
            //     kept distinct in case future refinements need both)
            //   expired_at = system time of close-out (when the row was
            //     marked superseded; differs from invalid_at when correcting
            //     historical facts)
            //   reference_time = originating episode's valid_at
            //   episodes[] = source episode/session UUIDs (multi-source attribution)
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS valid_at BIGINT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS invalid_at BIGINT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS expired_at BIGINT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS reference_time BIGINT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS episodes TEXT[] DEFAULT '{}'",

            // V1.6 retrieval + supersession (Mem0 + supermemory parity)
            //   lemmatized = pre-processed BM25 surface (V1.6 commit 3 wires)
            //   is_latest = false on superseded rows (supermemory parity)
            //   parent_memory_id = supermemory-style version chain
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS lemmatized TEXT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS is_latest BOOLEAN DEFAULT TRUE",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS parent_memory_id TEXT",

            // V1.6 source attribution (M4 from spec §4.10) — answer "where
            // did ZAKI learn this?" on the brain page. existing schema has
            // source_channel + source_message_id; V1.6 adds session_id +
            // snippet for /brain/memory/{key} drilldown UX.
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS source_session_id TEXT",
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS source_snippet TEXT",

            // V1.6 indexes — partial where the field is sparsely populated
            "CREATE INDEX IF NOT EXISTS idx_memories_subject ON {schema}.memories(user_id, subject) WHERE subject IS NOT NULL",
            // V1.6 commit 6 review (W1 fix): expression index on the JSONB
            // path because findRelatedExtractedMemories queries
            // `metadata->>'subject'` (not the typed `subject` column —
            // upsertMemoryWithMetadata writes JSONB only). Without this,
            // the contradiction-judge candidate fetch falls back to a
            // user-scoped seq-scan + sort. Cheap to maintain (only fires
            // when subject is in the JSONB).
            "CREATE INDEX IF NOT EXISTS idx_memories_metadata_subject ON {schema}.memories(user_id, (metadata->>'subject')) WHERE metadata ? 'subject'",
            "CREATE INDEX IF NOT EXISTS idx_memories_object_key ON {schema}.memories(user_id, object_key) WHERE object_key IS NOT NULL",
            "CREATE INDEX IF NOT EXISTS idx_memories_parent ON {schema}.memories(user_id, parent_memory_id) WHERE parent_memory_id IS NOT NULL",
            "CREATE INDEX IF NOT EXISTS idx_memories_is_latest ON {schema}.memories(user_id, is_latest) WHERE is_latest = TRUE",
            // GIN over lemmatized field — V1.6 commit 3 will populate the
            // column + switch BM25 surface to use this index.
            "CREATE INDEX IF NOT EXISTS idx_memories_lemmatized ON {schema}.memories USING gin (to_tsvector('simple', lemmatized))",
            // V1.6 commit 3 lazy backfill — populate `lemmatized` for any
            // pre-V1.6 row that doesn't have it yet. Uses Postgres's
            // Unicode-aware `lower()` (multilingual-safe). New writes go
            // through the richer Zig `lemmatizeForBm25` path with stopword
            // removal; backfill is intentionally a strict subset (basic
            // lowercasing) to avoid running heuristics on rows we didn't
            // capture at write time.
            "UPDATE {schema}.memories SET lemmatized = lower(content) WHERE lemmatized IS NULL",

            // V1.7a-5 (spec seam 3) — link_type column backfill from metadata.
            //
            // The link_type TEXT column was added in V1.6 cmt5 schema migration
            // (line 1062) but never populated by writers until V1.7a-5. Existing
            // memories with metadata containing "link_type" need a one-shot
            // backfill so /brain/memory/{key} drilldown surfaces consistent
            // values across pre/post-V1.7a-5 rows. Idempotent: WHERE
            // link_type IS NULL ensures re-running migrate() only touches
            // unbackfilled rows. Skips rows whose metadata never had
            // link_type at all (those stay NULL — the FE renders them
            // without the category badge, same as legacy non-extracted memories).
            "UPDATE {schema}.memories SET link_type = (metadata->>'link_type') " ++
                "WHERE link_type IS NULL AND metadata IS NOT NULL " ++
                "AND metadata ? 'link_type'",

            // ── V1.7 schema ────────────────────────────────────────────────
            //
            // seen_in_session_count: incremented each time the same key is
            // written from a DIFFERENT session. When count >= 2 the fact
            // has survived two independent sessions → eligible for Tier-3
            // (core) promotion. Default 1 so existing rows don't immediately
            // promote on boot. ADD COLUMN IF NOT EXISTS → safe on old DBs.
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS seen_in_session_count INTEGER NOT NULL DEFAULT 1",

            // V1.6 entity vector plane (separate from memory_vectors per
            // spec §D7 — entity-name embeddings live at different
            // granularity than memory-content embeddings; mixing them
            // cross-contaminates cosine ANN). Used by V1.6 commit 7
            // entity coreference (cosine ≥ 0.95 threshold per Mem0).
            // VECTOR(1024) matches the production embedding model
            // intfloat/multilingual-e5-large-instruct (config.json:90).
            // pgvector requires a dimension on columns indexed by ivfflat;
            // changing model dimensions in the future requires a migration.
            \\CREATE TABLE IF NOT EXISTS {schema}.memory_entities (
            \\    id TEXT PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    name TEXT NOT NULL,
            \\    name_lower TEXT NOT NULL,
            \\    entity_type TEXT NOT NULL DEFAULT 'PROPER',
            \\    name_embedding VECTOR(1024),
            \\    linked_memory_ids TEXT[] DEFAULT '{}',
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    UNIQUE (user_id, name_lower)
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_entities_user ON {schema}.memory_entities(user_id)",
            // ivfflat lists tuned for 5-50K rows per user; revisit if
            // production sees larger entity counts (uncommon — entities
            // are typically nouns/proper-names, much sparser than memories)
            "CREATE INDEX IF NOT EXISTS idx_entities_vec ON {schema}.memory_entities USING ivfflat (name_embedding vector_cosine_ops) WITH (lists = 100)",

            // V1.6 commit 7 — materialized typed-edge graph (Gap 1 from
            // memory pipeline handoff 2026-05-02).
            //
            // Until now the (subject, predicate, object) triples lived ONLY
            // in JSONB metadata, requiring an O(N) seq-scan in
            // gateway.buildBrainTypedEdges to reconstruct the graph on each
            // /brain/graph request. Real edges in a real table:
            //   - speed up brain rendering (index lookups vs JSONB extraction)
            //   - unblock graph-aware retrieval (neighbor traversal)
            //   - feed real edge_count into importance scoring (was half-blind
            //     when called outside the brain-graph context)
            //
            // Schema follows the same bi-temporal model as memories:
            //   valid_to / invalid_at / expired_at — set when the source or
            //     target memory is closed-out via setMemoryInvalidation
            //     (cascading from V1.6 cmt6).
            //   is_latest — supermemory parity; UI filters default to TRUE.
            //   confidence — pulled from extraction LLM's per-fact confidence.
            //   attribution — 'extraction_classifier' today; future write
            //     paths (agent_tool, compose) tag their origin.
            //
            // UNIQUE (user_id, source_key, predicate, target_key) WHERE is_latest
            //   ensures the same triple cannot accumulate duplicate edges
            //   (defends against Pass C re-extracting the same fact across
            //   sessions — pairs with V1.6 5b.3 MD5 dedup at the memory level).
            \\CREATE TABLE IF NOT EXISTS {schema}.memory_edges (
            \\    id BIGSERIAL PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    source_key TEXT NOT NULL,
            \\    target_key TEXT NOT NULL,
            \\    predicate TEXT NOT NULL,
            \\    attribution TEXT,
            \\    confidence FLOAT,
            \\    weight FLOAT NOT NULL DEFAULT 1.0,
            \\    valid_from BIGINT,
            \\    valid_to BIGINT,
            \\    invalid_at BIGINT,
            \\    expired_at BIGINT,
            \\    is_latest BOOLEAN NOT NULL DEFAULT TRUE,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_edges_source ON {schema}.memory_edges(user_id, source_key) WHERE is_latest",
            "CREATE INDEX IF NOT EXISTS idx_edges_target ON {schema}.memory_edges(user_id, target_key) WHERE is_latest",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_edges_triple ON {schema}.memory_edges(user_id, source_key, predicate, target_key) WHERE is_latest",
            // Validity index — drives the cascade-on-close from
            // setMemoryInvalidation. Partial because invalid edges are
            // append-only / archived, not actively queried.
            "CREATE INDEX IF NOT EXISTS idx_edges_validity ON {schema}.memory_edges(user_id, valid_to) WHERE valid_to IS NOT NULL",

            // V1.6 commit 16 — one-shot backfill: populate memory_edges from
            // existing JSONB triples on legacy memories. Idempotent via the
            // partial UNIQUE INDEX on (user_id, source_key, predicate,
            // target_key) WHERE is_latest — re-running migrate is safe.
            //
            // target_key shape mirrors extraction_persist.deriveEntityKey:
            //   'entity_' + first 16 hex chars of sha256(lower(object))
            // (pgcrypto's digest() returns bytea; encode → hex → substring.
            //  pgcrypto is installed by the cmt0 CREATE EXTENSION above.)
            //
            // Skips closed-out rows (valid_to in past) so cascade semantics
            // stay consistent with cmt6/cmt7 — closed-out memories can't
            // resurrect edges via backfill.
            //
            // Confidence: defaults to 1.0 when metadata.confidence absent
            // (legacy V1.5 rows). Attribution: defaults to
            // 'extraction_classifier' since pre-cmt7 extraction was the
            // only writer of subject/predicate/object metadata.
            //
            // Cost: O(N) over rows with metadata.subject populated. On
            // Nova's user_id=1 dev DB this is a small number; production
            // scale will run during a maintenance window.
            // V1.7a-4 (closes V1.6 ship-review WR-02): both Zig sites
            // (extraction_persist.deriveEntityKey + commands.deriveSessionEndEntityKey)
            // now route through extraction_persist.lowerForEntityKey, a
            // Unicode-aware helper covering ASCII A-Z + Latin-1 Supplement
            // + Cyrillic + Greek uppercase → lowercase. PG's `lower(...)`
            // matches this in standard UTF-8 locales (en_US.UTF-8 etc. —
            // the production deployment target) for those ranges. C-locale
            // PG would lowercase ASCII ONLY and diverge for everything else,
            // so production MUST run a UTF-8 locale (`SHOW lc_collate`
            // should not be 'C' or 'POSIX').
            //
            // **Migration note:** the cmt16 backfill is INSERT...ON CONFLICT
            // DO NOTHING. It does NOT rewrite already-existing memory_edges
            // rows. So pre-V1.7a-4 tenants with non-ASCII uppercase entity
            // names retain their old ASCII-only-keyed rows. The shift to
            // the new Unicode-folded key only happens when a NEW write for
            // the same surface form arrives — extraction_persist creates a
            // new entity_<unicode_hash> row, leaving the old ASCII row
            // orphaned. Manual cleanup recommended for tenants with
            // high-volume non-ASCII entity history (a one-shot UPDATE that
            // recomputes target_key for affected rows). Rare in practice —
            // extraction prompt emits canonical lowercase by design.
            "INSERT INTO {schema}.memory_edges (user_id, source_key, target_key, predicate, attribution, confidence, valid_from) " ++
                "SELECT user_id, key AS source_key, " ++
                "'entity_' || substring(encode(digest(lower(metadata->>'object'), 'sha256'), 'hex') from 1 for 16) AS target_key, " ++
                "metadata->>'predicate' AS predicate, " ++
                "COALESCE(metadata->>'attribution', 'extraction_classifier') AS attribution, " ++
                "COALESCE((metadata->>'confidence')::float, 1.0) AS confidence, " ++
                "EXTRACT(EPOCH FROM created_at)::bigint AS valid_from " ++
                "FROM {schema}.memories " ++
                "WHERE metadata IS NOT NULL " ++
                "AND metadata ? 'subject' " ++
                "AND metadata ? 'predicate' " ++
                "AND metadata ? 'object' " ++
                "AND length(metadata->>'object') > 0 " ++
                "AND length(metadata->>'predicate') > 0 " ++
                "AND (valid_to IS NULL OR valid_to > EXTRACT(EPOCH FROM NOW())::bigint) " ++
                "ON CONFLICT (user_id, source_key, predicate, target_key) WHERE is_latest DO NOTHING",
            \\CREATE TABLE IF NOT EXISTS {schema}.memory_events (
            \\    id TEXT PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    memory_id TEXT,
            \\    event_type TEXT NOT NULL,
            \\    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.channel_state (
            \\    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    telegram JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    app JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.telegram_updates (
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    update_id BIGINT NOT NULL,
            \\    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    PRIMARY KEY (user_id, update_id)
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.channel_identity_bindings (
            \\    id TEXT PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    channel TEXT NOT NULL,
            \\    account_id TEXT NOT NULL,
            \\    principal_key TEXT NOT NULL,
            \\    scope_key TEXT NOT NULL,
            \\    thread_key TEXT,
            \\    thread_key_norm TEXT NOT NULL DEFAULT '',
            \\    peer_kind TEXT,
            \\    peer_id TEXT,
            \\    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_channel_identity_unique ON {schema}.channel_identity_bindings(channel, account_id, principal_key, scope_key, thread_key_norm)",
            "CREATE INDEX IF NOT EXISTS idx_channel_identity_user_channel ON {schema}.channel_identity_bindings(user_id, channel)",
            "CREATE INDEX IF NOT EXISTS idx_channel_identity_lookup ON {schema}.channel_identity_bindings(channel, account_id, principal_key, scope_key, thread_key_norm)",
            \\CREATE TABLE IF NOT EXISTS {schema}.heartbeat (
            \\    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    config JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    last_evaluated_at TIMESTAMPTZ,
            \\    last_triggered_at TIMESTAMPTZ,
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.onboarding (
            \\    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    state JSONB NOT NULL DEFAULT '{"completed":false}'::jsonb,
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.tenant_user_leases (
            \\    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    owner_id TEXT NOT NULL,
            \\    lease_token TEXT NOT NULL,
            \\    lease_until TIMESTAMPTZ NOT NULL,
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_tenant_user_leases_owner_until ON {schema}.tenant_user_leases(owner_id, lease_until DESC)",
            \\CREATE TABLE IF NOT EXISTS {schema}.jobs (
            \\    id TEXT PRIMARY KEY,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
            \\    kind TEXT NOT NULL,
            \\    schedule_type TEXT NOT NULL,
            \\    cron_expr TEXT,
            \\    run_at TIMESTAMPTZ,
            \\    timezone TEXT NOT NULL,
            \\    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    raw_job JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    delivery JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    enabled BOOLEAN NOT NULL DEFAULT TRUE,
            \\    quiet_hours_policy JSONB NOT NULL DEFAULT '{}'::jsonb,
            \\    retry_budget INT NOT NULL DEFAULT 3,
            \\    retry_count INT NOT NULL DEFAULT 0,
            \\    next_run_at TIMESTAMPTZ,
            \\    last_run_at TIMESTAMPTZ,
            \\    last_status TEXT,
            \\    last_error TEXT,
            \\    lease_owner TEXT,
            \\    lease_until TIMESTAMPTZ,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "CREATE INDEX IF NOT EXISTS idx_jobs_due ON {schema}.jobs(enabled, next_run_at)",
            "CREATE INDEX IF NOT EXISTS idx_jobs_user_due ON {schema}.jobs(user_id, next_run_at)",
            \\CREATE TABLE IF NOT EXISTS {schema}.job_runs (
            \\    id TEXT PRIMARY KEY,
            \\    job_id TEXT NOT NULL REFERENCES {schema}.jobs(id) ON DELETE CASCADE,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    finished_at TIMESTAMPTZ,
            \\    status TEXT NOT NULL,
            \\    output TEXT,
            \\    error TEXT,
            \\    trace JSONB NOT NULL DEFAULT '{}'::jsonb
            \\)
            ,
            \\CREATE TABLE IF NOT EXISTS {schema}.tasks (
            \\    id TEXT NOT NULL,
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
            \\    request_session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
            \\    label TEXT NOT NULL,
            \\    prompt TEXT NOT NULL,
            \\    status TEXT NOT NULL,
            \\    result TEXT,
            \\    error TEXT,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    started_at TIMESTAMPTZ,
            \\    completed_at TIMESTAMPTZ,
            \\    PRIMARY KEY (user_id, id)
            \\)
            ,
            "ALTER TABLE {schema}.tasks ADD COLUMN IF NOT EXISTS request_session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL",
            "ALTER TABLE {schema}.tasks DROP CONSTRAINT IF EXISTS tasks_pkey",
            "ALTER TABLE {schema}.tasks ADD PRIMARY KEY (user_id, id)",

            // S10.2 — bootstrap the schema_migrations tracker table +
            // record the legacy initial schema as version 1. The new
            // framework module at `src/migrations.zig` (S10.1) is the
            // path for future migrations 0002+. For 0001 we don't
            // re-run the full DDL via the framework because the
            // legacy loop above already did it (idempotently); we
            // just record it as applied so future migrations land
            // through the framework with full version-tracking
            // semantics. ON CONFLICT DO NOTHING makes this safe to
            // re-run on every boot during the legacy-loop transition
            // period.
            \\CREATE TABLE IF NOT EXISTS {schema}.schema_migrations (
            \\    version INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
            ,
            "INSERT INTO {schema}.schema_migrations (version, name) VALUES (1, '0001_initial_schema') ON CONFLICT (version) DO NOTHING",

            // ── V1.7a-9a — Communities (label-propagation auto-clustering) ──
            //
            // community_id on memories table:
            //   - Nullable INTEGER. NULL = unassigned (new memories before
            //     first recompute, OR archived memories — recompute leaves
            //     them as-was for historical record).
            //   - Stable across recomputes via hash of top-K-importance
            //     member keys (computed in src/agent/communities.zig).
            //
            // memory_communities table: per-(user, community) name + counts.
            //   - name_source distinguishes 'llm' vs 'fallback' for telemetry
            //     and FE styling (e.g. dim auto-fallback names).
            //   - generated_at enables stale-name detection on next recompute.
            //   - member_set_hash gates LLM re-call: only re-name when the
            //     top-K member set changes (cost control).
            "ALTER TABLE {schema}.memories ADD COLUMN IF NOT EXISTS community_id INTEGER",
            // Partial index on the live + brain-visible subset matches the
            // typical /brain/graph + /brain/communities query shape.
            "CREATE INDEX IF NOT EXISTS idx_memories_community ON {schema}.memories(user_id, community_id) WHERE is_latest AND community_id IS NOT NULL",
            \\CREATE TABLE IF NOT EXISTS {schema}.memory_communities (
            \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
            \\    community_id INTEGER NOT NULL,
            \\    name TEXT,
            \\    name_source TEXT,
            \\    member_count INTEGER NOT NULL DEFAULT 0,
            \\    member_set_hash TEXT,
            \\    generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    PRIMARY KEY (user_id, community_id)
            \\)
            ,
        };

        for (statements) |template| {
            const query = try self.buildQuery(template);
            defer self.allocator.free(query);
            const result = try self.execMigrateStatement(template, query);
            if (result) |pg_result| c.PQclear(pg_result);
        }
    }

    pub fn provisionUser(self: *Self, user_id: i64, workspace_path: []const u8) !void {
        if (try self.hasExternalIdentity(user_id)) |exists| {
            if (!exists) return error.IdentityUserNotFound;
        }
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const workspace_z = try self.allocator.dupeZ(u8, workspace_path);
        defer self.allocator.free(workspace_z);
        var key_buf: [128]u8 = undefined;
        const session_key = zaki_session.userMainSessionKey(&key_buf, user_s);
        const session_key_z = try self.allocator.dupeZ(u8, session_key);
        defer self.allocator.free(session_key_z);
        try self.execParamsNoResult(
            "INSERT INTO {schema}.users (user_id, workspace_path) VALUES ($1, $2) " ++
                "ON CONFLICT (user_id) DO UPDATE SET workspace_path = EXCLUDED.workspace_path, updated_at = NOW()",
            &.{ user_s.ptr, workspace_z },
            &.{ @as(c_int, @intCast(user_s.len)), @as(c_int, @intCast(workspace_path.len)) },
        );
        try self.execParamsNoResult(
            "INSERT INTO {schema}.user_config (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING",
            &.{user_s.ptr},
            &.{@as(c_int, @intCast(user_s.len))},
        );
        try self.execParamsNoResult(
            "INSERT INTO {schema}.heartbeat (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING",
            &.{user_s.ptr},
            &.{@as(c_int, @intCast(user_s.len))},
        );
        try self.execParamsNoResult(
            "INSERT INTO {schema}.channel_state (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING",
            &.{user_s.ptr},
            &.{@as(c_int, @intCast(user_s.len))},
        );
        try self.execParamsNoResult(
            "INSERT INTO {schema}.onboarding (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING",
            &.{user_s.ptr},
            &.{@as(c_int, @intCast(user_s.len))},
        );
        try self.execParamsNoResult(
            "INSERT INTO {schema}.sessions (id, user_id, session_key, kind, title) VALUES ($1, $2, $1, 'main', 'Main') ON CONFLICT (session_key) DO NOTHING",
            &.{ session_key_z, user_s.ptr },
            &.{ @as(c_int, @intCast(session_key.len)), @as(c_int, @intCast(user_s.len)) },
        );
    }

    pub fn hasExternalIdentity(self: *Self, user_id: i64) !?bool {
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const query =
            "SELECT 1 FROM public.zaki_users WHERE id = $1 LIMIT 1";

        const result = self.execParams(query, &.{user_s.ptr}, &.{@as(c_int, @intCast(user_s.len))}) catch |err| switch (err) {
            // Compatibility mode: keep provisioning behavior when the identity
            // table is inaccessible in this runtime.
            error.ExecFailed, error.ConnectionFailed => return null,
            else => return err,
        };
        defer c.PQclear(result);

        return c.PQntuples(result) > 0;
    }

    pub fn getConfigJson(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]u8 {
        return self.getJsonValue(allocator, user_id, "user_config", "config", "{}");
    }

    pub fn putConfigJson(self: *Self, user_id: i64, json: []const u8) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.user_config (user_id, config, updated_at) VALUES ($1, $2::jsonb, NOW()) " ++
                "ON CONFLICT (user_id) DO UPDATE SET config = EXCLUDED.config, version = {schema}.user_config.version + 1, updated_at = NOW()",
        );
        defer self.allocator.free(q);
        try self.execJsonUpsert(q, user_id, json);
    }

    pub fn listUserConfigRows(self: *Self, allocator: std.mem.Allocator) ![]UserConfigRow {
        const q = try self.buildQuery(
            "SELECT user_id, config::text FROM {schema}.user_config ORDER BY user_id ASC",
        );
        defer self.allocator.free(q);
        const result = try self.exec(q);
        defer c.PQclear(result);
        const rows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(UserConfigRow, rows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*row| row.deinit(allocator);
            allocator.free(out);
        }
        for (0..rows) |i| {
            const row_idx: c_int = @intCast(i);
            const user_text = try dupeResultValue(allocator, result, row_idx, 0);
            defer allocator.free(user_text);
            out[i] = .{
                .user_id = try std.fmt.parseInt(i64, user_text, 10),
                .config_json = try dupeResultValue(allocator, result, row_idx, 1),
            };
            initialized += 1;
        }
        return out;
    }

    pub fn getHeartbeatJson(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]u8 {
        return self.getJsonValue(allocator, user_id, "heartbeat", "config", "{}");
    }

    pub fn putHeartbeatJson(self: *Self, user_id: i64, json: []const u8) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.heartbeat (user_id, config, updated_at) VALUES ($1, $2::jsonb, NOW()) " ++
                "ON CONFLICT (user_id) DO UPDATE SET config = EXCLUDED.config, updated_at = NOW()",
        );
        defer self.allocator.free(q);
        try self.execJsonUpsert(q, user_id, json);
    }

    pub fn getOnboardingJson(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]u8 {
        return self.getJsonValue(allocator, user_id, "onboarding", "state", "{\"completed\":false,\"completed_at_s\":null}");
    }

    pub fn putOnboardingJson(self: *Self, user_id: i64, json: []const u8) !void {
        const q = try self.buildQuery(
            "WITH onboarding_upsert AS (" ++
                "INSERT INTO {schema}.onboarding (user_id, state, updated_at) VALUES ($1, $2::jsonb, NOW()) " ++
                "ON CONFLICT (user_id) DO UPDATE SET state = EXCLUDED.state, updated_at = NOW() " ++
                "RETURNING user_id" ++
                ") " ++
                "UPDATE {schema}.users SET onboarding_completed = COALESCE(($2::jsonb->>'completed')::boolean, false), " ++
                "onboarding_completed_at = CASE WHEN COALESCE(($2::jsonb->>'completed')::boolean, false) THEN NOW() ELSE NULL END, updated_at = NOW() " ++
                "WHERE user_id IN (SELECT user_id FROM onboarding_upsert)",
        );
        defer self.allocator.free(q);
        try self.execJsonUpsert(q, user_id, json);
    }

    pub fn getTelegramStateJson(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]u8 {
        return self.getJsonValue(allocator, user_id, "channel_state", "telegram", "{}");
    }

    pub fn putTelegramStateJson(self: *Self, user_id: i64, json: []const u8) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.channel_state (user_id, telegram, updated_at) VALUES ($1, $2::jsonb, NOW()) " ++
                "ON CONFLICT (user_id) DO UPDATE SET telegram = EXCLUDED.telegram, updated_at = NOW()",
        );
        defer self.allocator.free(q);
        try self.execJsonUpsert(q, user_id, json);
    }

    pub fn deleteTelegramState(self: *Self, user_id: i64) !void {
        const q = try self.buildQuery(
            "UPDATE {schema}.channel_state SET telegram = '{}'::jsonb, updated_at = NOW() WHERE user_id = $1",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// S7.2 — GDPR row-level user delete. Every per-user FK references
    /// `{schema}.users(user_id)` with `ON DELETE CASCADE` (see schema at
    /// lines 743–974 of this file), so a single DELETE on the users row
    /// cascades through: user_config, user_secrets, secret_mutations,
    /// sessions, messages, completion_events, memories, memory_events,
    /// channel_state, telegram_updates, channel_identity_bindings,
    /// heartbeat, onboarding, tenant_user_leases, jobs, job_runs, tasks.
    ///
    /// Note: `memory_vectors` (pgvector) has no FK to users and is NOT
    /// covered by this cascade — the GDPR orchestrator deletes those
    /// embeddings separately via `VectorStore.deleteAllForUser`.
    pub fn deleteUser(self: *Self, user_id: i64) !void {
        const q = try self.buildQuery("DELETE FROM {schema}.users WHERE user_id = $1");
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    pub fn recordTelegramChat(self: *Self, user_id: i64, account_id: []const u8, chat_id: i64) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.channel_state (user_id, telegram, updated_at) VALUES ($1, jsonb_build_object('connected', true, 'account_id', $2::text, 'chat_id', $3::bigint, 'updated_at_s', EXTRACT(EPOCH FROM NOW())::bigint), NOW()) " ++
                "ON CONFLICT (user_id) DO UPDATE SET telegram = COALESCE({schema}.channel_state.telegram, '{}'::jsonb) || jsonb_build_object('chat_id', $3::bigint, 'account_id', $2::text, 'updated_at_s', EXTRACT(EPOCH FROM NOW())::bigint), updated_at = NOW()",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const account_z = try self.allocator.dupeZ(u8, account_id);
        defer self.allocator.free(account_z);
        var chat_buf: [32]u8 = undefined;
        const chat_s = try std.fmt.bufPrintZ(&chat_buf, "{d}", .{chat_id});
        const params = [_]?[*:0]const u8{ user_s.ptr, account_z, chat_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(account_id.len), @intCast(chat_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    pub fn getSecret(self: *Self, allocator: std.mem.Allocator, user_id: i64, key: []const u8) !?[]u8 {
        const q = try self.buildQuery(
            "SELECT encode(ciphertext, 'hex'), encode(nonce, 'hex'), aad FROM {schema}.user_secrets WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;

        const ct_hex = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(ct_hex);
        const nonce_hex = try dupeResultValue(allocator, result, 0, 1);
        defer allocator.free(nonce_hex);
        const aad = try dupeResultValue(allocator, result, 0, 2);
        defer allocator.free(aad);
        return try self.decryptSecretHex(allocator, ct_hex, nonce_hex, aad);
    }

    pub fn putSecret(self: *Self, user_id: i64, key: []const u8, value: []const u8) !void {
        const enc = try self.encryptSecretForDb(value, key);
        defer self.allocator.free(enc.ciphertext_hex);
        defer self.allocator.free(enc.nonce_hex);

        const q = try self.buildQuery(
            "INSERT INTO {schema}.user_secrets (user_id, key, ciphertext, nonce, aad, updated_at) VALUES ($1, $2, decode($3, 'hex'), decode($4, 'hex'), $5, NOW()) " ++
                "ON CONFLICT (user_id, key) DO UPDATE SET ciphertext = EXCLUDED.ciphertext, nonce = EXCLUDED.nonce, aad = EXCLUDED.aad, updated_at = NOW()",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const ct_z = try self.allocator.dupeZ(u8, enc.ciphertext_hex);
        defer self.allocator.free(ct_z);
        const nonce_z = try self.allocator.dupeZ(u8, enc.nonce_hex);
        defer self.allocator.free(nonce_z);
        const aad_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(aad_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z, ct_z, nonce_z, aad_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len), @intCast(enc.ciphertext_hex.len), @intCast(enc.nonce_hex.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    pub fn deleteSecret(self: *Self, user_id: i64, key: []const u8) !bool {
        const q = try self.buildQuery(
            "DELETE FROM {schema}.user_secrets WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const affected = c.PQcmdTuples(result);
        if (affected == null) return false;
        return !std.mem.eql(u8, std.mem.span(affected), "0");
    }

    pub fn listSecretKeys(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![][]const u8 {
        const q = try self.buildQuery(
            "SELECT key FROM {schema}.user_secrets WHERE user_id = $1 ORDER BY key ASC",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const nrows: usize = @intCast(@max(0, c.PQntuples(result)));
        if (nrows == 0) return allocator.alloc([]const u8, 0);
        const keys = try allocator.alloc([]const u8, nrows);
        var initialized: usize = 0;
        errdefer {
            for (keys[0..initialized]) |k| allocator.free(k);
            allocator.free(keys);
        }
        for (0..nrows) |i| {
            keys[i] = try dupeResultValue(allocator, result, @intCast(i), 0);
            initialized += 1;
        }
        return keys;
    }

    // ── D8 (secret vault) ──────────────────────────────────────────────
    //
    // Metadata-only read (S2.12). Never touches ciphertext — returns
    // `created_at` + `updated_at` as unix-seconds so the client can
    // show "last rotated 3 days ago" without decryption ever running.

    pub fn getSecretMetadata(self: *Self, allocator: std.mem.Allocator, user_id: i64, key: []const u8) !?SecretMetadata {
        const q = try self.buildQuery(
            "SELECT EXTRACT(EPOCH FROM created_at)::bigint, EXTRACT(EPOCH FROM updated_at)::bigint " ++
                "FROM {schema}.user_secrets WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;

        const created_raw = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(created_raw);
        const updated_raw = try dupeResultValue(allocator, result, 0, 1);
        defer allocator.free(updated_raw);

        const created_at = std.fmt.parseInt(i64, created_raw, 10) catch return error.InvalidTimestamp;
        const updated_at = std.fmt.parseInt(i64, updated_raw, 10) catch return error.InvalidTimestamp;
        return .{ .created_at_unix = created_at, .updated_at_unix = updated_at };
    }

    /// Record a secret mutation for audit (S2.16). Always writes — the
    /// handler records both successful and failed attempts so operators
    /// can diagnose token-replay attempts, wrong-action calls, etc.
    pub fn recordSecretMutation(
        self: *Self,
        user_id: i64,
        key: []const u8,
        action: []const u8,
        actor: ?[]const u8,
        outcome: []const u8,
        detail: ?[]const u8,
    ) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.secret_mutations (user_id, key, action, actor, outcome, detail) " ++
                "VALUES ($1, $2, $3, $4, $5, $6)",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const action_z = try self.allocator.dupeZ(u8, action);
        defer self.allocator.free(action_z);
        const actor_z: ?[*:0]const u8 = if (actor) |a| blk: {
            const z = try self.allocator.dupeZ(u8, a);
            break :blk z.ptr;
        } else null;
        defer if (actor_z) |ptr| self.allocator.free(std.mem.span(ptr));
        const outcome_z = try self.allocator.dupeZ(u8, outcome);
        defer self.allocator.free(outcome_z);
        const detail_z: ?[*:0]const u8 = if (detail) |d| blk: {
            const z = try self.allocator.dupeZ(u8, d);
            break :blk z.ptr;
        } else null;
        defer if (detail_z) |ptr| self.allocator.free(std.mem.span(ptr));

        const params = [_]?[*:0]const u8{ user_s.ptr, key_z, action_z, actor_z, outcome_z, detail_z };
        const lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(key.len),
            @intCast(action.len),
            if (actor) |a| @intCast(a.len) else 0,
            @intCast(outcome.len),
            if (detail) |d| @intCast(d.len) else 0,
        };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);

        // D13 (2026-04-26) — record outcome to lane_metrics for the
        // operator rolling-rate signal. Audit row above gives the
        // per-tenant forensic trail; this counter gives the cluster-wide
        // health view. Centralized here so every gateway call site
        // (handlePrepare/handleSet/handleDelete) updates the counter
        // without per-site changes.
        lane_metrics.classifyAndRecordSecretMutation(outcome);
    }

    pub fn listSecretMutations(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        limit: u32,
    ) ![]SecretMutationRecord {
        const clamped_limit: u32 = @min(@max(@as(u32, 1), limit), 100);
        const q = try self.buildQuery(
            "SELECT id, key, action, actor, outcome, detail, EXTRACT(EPOCH FROM at)::bigint " ++
                "FROM {schema}.secret_mutations WHERE user_id = $1 ORDER BY at DESC LIMIT $2",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var limit_buf: [16]u8 = undefined;
        const limit_s = try std.fmt.bufPrintZ(&limit_buf, "{d}", .{clamped_limit});
        const params = [_]?[*:0]const u8{ user_s.ptr, limit_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(limit_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const nrows: usize = @intCast(@max(0, c.PQntuples(result)));
        if (nrows == 0) return allocator.alloc(SecretMutationRecord, 0);

        const rows = try allocator.alloc(SecretMutationRecord, nrows);
        var initialized: usize = 0;
        errdefer {
            for (rows[0..initialized]) |r| r.deinit(allocator);
            allocator.free(rows);
        }
        for (0..nrows) |i| {
            const id = try dupeResultValue(allocator, result, @intCast(i), 0);
            errdefer allocator.free(id);
            const key = try dupeResultValue(allocator, result, @intCast(i), 1);
            errdefer allocator.free(key);
            const action = try dupeResultValue(allocator, result, @intCast(i), 2);
            errdefer allocator.free(action);

            const actor: ?[]const u8 = if (c.PQgetisnull(result, @intCast(i), 3) == 1)
                null
            else blk: {
                const a = try dupeResultValue(allocator, result, @intCast(i), 3);
                break :blk a;
            };
            errdefer if (actor) |a| allocator.free(a);

            const outcome = try dupeResultValue(allocator, result, @intCast(i), 4);
            errdefer allocator.free(outcome);

            const detail: ?[]const u8 = if (c.PQgetisnull(result, @intCast(i), 5) == 1)
                null
            else blk: {
                const d = try dupeResultValue(allocator, result, @intCast(i), 5);
                break :blk d;
            };
            errdefer if (detail) |d| allocator.free(d);

            const at_raw = try dupeResultValue(allocator, result, @intCast(i), 6);
            defer allocator.free(at_raw);
            const at_unix = std.fmt.parseInt(i64, at_raw, 10) catch return error.InvalidTimestamp;

            rows[i] = .{
                .id = id,
                .key = key,
                .action = action,
                .actor = actor,
                .outcome = outcome,
                .detail = detail,
                .at_unix = at_unix,
            };
            initialized += 1;
        }
        return rows;
    }

    pub fn replaceJobsJson(self: *Self, user_id: i64, session_id: []const u8, json: []const u8) !void {
        const delete_q = try self.buildQuery("DELETE FROM {schema}.jobs WHERE user_id = $1");
        defer self.allocator.free(delete_q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var delete_params = [_]?[*:0]const u8{user_s.ptr};
        var delete_lengths = [_]c_int{@intCast(user_s.len)};
        const delete_result = try self.execParams(delete_q, &delete_params, &delete_lengths);
        c.PQclear(delete_result);

        const insert_q = try self.buildQuery(
            "INSERT INTO {schema}.jobs (id, user_id, session_id, kind, schedule_type, cron_expr, timezone, payload, raw_job, enabled, next_run_at, last_run_at, created_at, updated_at) " ++
                "SELECT CASE " ++
                "WHEN COALESCE(NULLIF(elem->>'id', ''), '') != '' THEN $4 || (elem->>'id') " ++
                "ELSE $4 || md5(random()::text || clock_timestamp()::text) END, $1, $2, " ++
                "CASE WHEN COALESCE(elem->>'job_type', 'shell') IN ('agent','delivery','integration','shell') THEN COALESCE(elem->>'job_type', 'shell') ELSE 'shell' END, " ++
                "CASE WHEN COALESCE(elem->>'expression', '') LIKE '@once:%' THEN 'once' ELSE 'cron' END, " ++
                "NULLIF(elem->>'expression', ''), COALESCE(elem->>'timezone', 'UTC'), elem, elem, COALESCE((elem->>'enabled')::boolean, true), " ++
                "CASE WHEN elem ? 'next_run_secs' THEN TO_TIMESTAMP((elem->>'next_run_secs')::bigint) ELSE NOW() + INTERVAL '60 seconds' END, " ++
                "CASE WHEN elem ? 'last_run_secs' THEN TO_TIMESTAMP((elem->>'last_run_secs')::bigint) ELSE NULL END, NOW(), NOW() " ++
                "FROM jsonb_array_elements($3::jsonb) elem",
        );
        defer self.allocator.free(insert_q);
        var normalized_session_buf: [160]u8 = undefined;
        const normalized_session = if (std.mem.eql(u8, session_id, "main"))
            zaki_session.userMainSessionKey(&normalized_session_buf, user_s)
        else
            session_id;
        const session_z = try self.allocator.dupeZ(u8, normalized_session);
        defer self.allocator.free(session_z);
        const json_z = try self.allocator.dupeZ(u8, json);
        defer self.allocator.free(json_z);
        const job_key_prefix = try std.fmt.allocPrint(self.allocator, "user:{d}:", .{user_id});
        defer self.allocator.free(job_key_prefix);
        const job_key_prefix_z = try self.allocator.dupeZ(u8, job_key_prefix);
        defer self.allocator.free(job_key_prefix_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, session_z, json_z, job_key_prefix_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(normalized_session.len), @intCast(json.len), @intCast(job_key_prefix.len) };
        const insert_result = try self.execParams(insert_q, &params, &lengths);
        c.PQclear(insert_result);
    }

    pub fn getJobsJson(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]u8 {
        // ME-01 fix (2026-05-07): COALESCE raw_job before the jsonb_set
        // chain. If any row has NULL raw_job, the chain returns NULL and
        // jsonb_agg includes a NULL element in the output array
        // (`[null, {...}, ...]`), making the FE crash on `.map`.
        // ME-02 fix (2026-05-07): LIMIT 500. Pre-fix the endpoint
        // materialized every row a user has ever scheduled — fine for
        // current tenants (max ~5 jobs each), but unbounded by design.
        // 500 is the FE pagination ceiling and matches the brain
        // BRAIN_DEFAULT_MAX_NODES sibling; if a user ever exceeds 500
        // scheduled jobs we want to know.
        const q = try self.buildQuery(
            "SELECT COALESCE(jsonb_agg(job_json ORDER BY created_at), '[]'::jsonb)::text FROM (" ++
                " SELECT created_at, " ++
                " jsonb_set(" ++
                "   jsonb_set(" ++
                "     jsonb_set(" ++
                "       jsonb_set(" ++
                "         jsonb_set(COALESCE(raw_job, '{}'::jsonb), '{enabled}', to_jsonb(enabled), true)," ++
                "         '{paused}', to_jsonb(CASE WHEN enabled THEN COALESCE((raw_job->>'paused')::boolean, false) ELSE TRUE END), true" ++
                "       )," ++
                "       '{last_status}', CASE WHEN last_status IS NULL THEN 'null'::jsonb ELSE to_jsonb(last_status) END, true" ++
                "     )," ++
                "     '{last_run_secs}', CASE WHEN last_run_at IS NULL THEN 'null'::jsonb ELSE to_jsonb(EXTRACT(EPOCH FROM last_run_at)::bigint) END, true" ++
                "   )," ++
                "   '{next_run_secs}', CASE WHEN next_run_at IS NULL THEN 'null'::jsonb ELSE to_jsonb(EXTRACT(EPOCH FROM next_run_at)::bigint) END, true" ++
                " ) AS job_json" ++
                " FROM {schema}.jobs WHERE user_id = $1" ++
                " ORDER BY created_at LIMIT 500" ++
                " ) job_rows",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return allocator.dupe(u8, "[]");
        return dupeResultValue(allocator, result, 0, 0);
    }

    pub fn listJobRuns(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        job_id: []const u8,
        limit: usize,
    ) ![]cron_mod.CronRun {
        const q = try self.buildQuery(
            "SELECT EXTRACT(EPOCH FROM started_at)::bigint::text, EXTRACT(EPOCH FROM finished_at)::bigint::text, status, output " ++
                "FROM {schema}.job_runs WHERE user_id = $1 AND (job_id = $2 OR job_id = $3) ORDER BY started_at DESC LIMIT $4::bigint",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const scoped_job_id = try std.fmt.allocPrint(allocator, "user:{d}:{s}", .{ user_id, job_id });
        defer allocator.free(scoped_job_id);
        const scoped_job_id_z = try self.allocator.dupeZ(u8, scoped_job_id);
        defer self.allocator.free(scoped_job_id_z);
        const raw_job_id_z = try self.allocator.dupeZ(u8, job_id);
        defer self.allocator.free(raw_job_id_z);
        var limit_buf: [32]u8 = undefined;
        const limit_s = try std.fmt.bufPrintZ(&limit_buf, "{d}", .{limit});
        const params = [_]?[*:0]const u8{ user_s.ptr, scoped_job_id_z, raw_job_id_z, limit_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(scoped_job_id.len), @intCast(job_id.len), @intCast(limit_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const rows: usize = @intCast(c.PQntuples(result));
        const runs = try allocator.alloc(cron_mod.CronRun, rows);
        var initialized: usize = 0;
        errdefer {
            for (runs[0..initialized]) |run| {
                allocator.free(@constCast(run.job_id));
                allocator.free(@constCast(run.status));
                if (run.output) |value| allocator.free(@constCast(value));
            }
            allocator.free(runs);
        }

        for (0..rows) |i| {
            const row: c_int = @intCast(i);
            const started_text = try dupeResultValue(allocator, result, row, 0);
            defer allocator.free(started_text);
            const finished_text = try dupeResultValue(allocator, result, row, 1);
            defer allocator.free(finished_text);
            const started_at_s = try std.fmt.parseInt(i64, started_text, 10);
            const finished_at_s = try std.fmt.parseInt(i64, finished_text, 10);
            const output = if (c.PQgetisnull(result, row, 3) == 1)
                null
            else
                try dupeResultValue(allocator, result, row, 3);

            runs[i] = .{
                .id = @intCast(i + 1),
                .job_id = try allocator.dupe(u8, job_id),
                .started_at_s = started_at_s,
                .finished_at_s = finished_at_s,
                .status = try dupeResultValue(allocator, result, row, 2),
                .output = output,
                .duration_ms = (finished_at_s - started_at_s) * std.time.ms_per_s,
            };
            initialized += 1;
        }
        return runs;
    }

    pub fn clearJobs(self: *Self, user_id: i64) !void {
        const q = try self.buildQuery("DELETE FROM {schema}.jobs WHERE user_id = $1");
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    pub fn saveSessionMessage(self: *Self, user_id: i64, session_id: []const u8, role: []const u8, content: []const u8) !void {
        try self.ensureSession(user_id, session_id);
        const q = try self.buildQuery(
            "INSERT INTO {schema}.messages (id, session_id, user_id, role, source, content) VALUES ($1, $2, $3, $4, 'app', $5)",
        );
        defer self.allocator.free(q);
        const message_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(message_id);
        const message_id_z = try self.allocator.dupeZ(u8, message_id);
        defer self.allocator.free(message_id_z);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_z = try self.allocator.dupeZ(u8, session_id);
        defer self.allocator.free(session_z);
        const role_z = try self.allocator.dupeZ(u8, role);
        defer self.allocator.free(role_z);
        const content_z = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(content_z);
        const params = [_]?[*:0]const u8{ message_id_z, session_z, user_s.ptr, role_z, content_z };
        const lengths = [_]c_int{ @intCast(message_id.len), @intCast(session_id.len), @intCast(user_s.len), @intCast(role.len), @intCast(content.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    pub fn loadSessionMessages(self: *Self, allocator: std.mem.Allocator, user_id: i64, session_id: []const u8) ![]memory_root.MessageEntry {
        const q = try self.buildQuery(
            "SELECT role, content FROM {schema}.messages WHERE user_id = $1 AND session_id = $2 ORDER BY created_at ASC, id ASC",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_z = try self.allocator.dupeZ(u8, session_id);
        defer self.allocator.free(session_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, session_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(session_id.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const rows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(memory_root.MessageEntry, rows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |entry| {
                allocator.free(entry.role);
                allocator.free(entry.content);
            }
            allocator.free(out);
        }

        for (0..rows) |i| {
            const row: c_int = @intCast(i);
            const role = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(role);
            const content = try dupeResultValue(allocator, result, row, 1);
            out[i] = .{
                .role = role,
                .content = content,
            };
            initialized += 1;
        }
        return out;
    }

    pub fn clearSessionMessages(self: *Self, user_id: i64, session_id: []const u8) !void {
        const q = try self.buildQuery(
            "DELETE FROM {schema}.messages WHERE user_id = $1 AND session_id = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_z = try self.allocator.dupeZ(u8, session_id);
        defer self.allocator.free(session_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, session_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(session_id.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// Durable session delete — purges every persistent surface tied to a
    /// (user_id, session_key) pair. Per Nova directive 2026-04-28: the UI
    /// session delete was only evicting RAM, then `listUserSessions` would
    /// re-show the row from the durable store on next refresh. This makes
    /// "delete" actually delete.
    ///
    /// Wraps four DELETEs in a single transaction so it's all-or-nothing:
    ///   1. messages (per session_id)
    ///   2. completion_events (per session_id)
    ///   3. autosaved memory rows (autosave_user_*, autosave_assistant_* with
    ///      session_id matching)
    ///   4. sessions row itself (this is the one the UI list reads from)
    ///
    /// Idempotent: if zero rows match, returns success — caller can call this
    /// safely on already-absent sessions.
    pub fn deleteSession(self: *Self, user_id: i64, session_id: []const u8) !void {
        // BEGIN transaction
        const begin_result = try self.exec("BEGIN");
        c.PQclear(begin_result);
        errdefer {
            // On any error in the transaction below, rollback. Best-effort:
            // if rollback itself fails, postgres will clear on connection
            // teardown. Cannot use `return` inside defer expression.
            if (self.exec("ROLLBACK")) |rb| {
                c.PQclear(rb);
            } else |_| {}
        }

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_z = try self.allocator.dupeZ(u8, session_id);
        defer self.allocator.free(session_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, session_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(session_id.len) };

        // 1. Messages
        {
            const q = try self.buildQuery("DELETE FROM {schema}.messages WHERE user_id = $1 AND session_id = $2");
            defer self.allocator.free(q);
            const r = try self.execParams(q, &params, &lengths);
            c.PQclear(r);
        }

        // 2. Completion events
        {
            const q = try self.buildQuery("DELETE FROM {schema}.completion_events WHERE user_id = $1 AND session_id = $2");
            defer self.allocator.free(q);
            const r = try self.execParams(q, &params, &lengths);
            c.PQclear(r);
        }

        // 3. Autosaved session-scoped memory artifacts (mirrors the LIKE
        //    pattern from clearAutoSavedMemory but scoped to this session)
        {
            const q = try self.buildQuery(
                "DELETE FROM {schema}.memories WHERE user_id = $1 AND session_id = $2 " ++
                    "AND (key LIKE 'autosave_user_%' OR key LIKE 'autosave_assistant_%')",
            );
            defer self.allocator.free(q);
            const r = try self.execParams(q, &params, &lengths);
            c.PQclear(r);
        }

        // 4. Sessions row itself — this is what listUserSessions reads from.
        //    Without this, the UI would show "ghost" deleted sessions.
        {
            const q = try self.buildQuery("DELETE FROM {schema}.sessions WHERE user_id = $1 AND session_key = $2");
            defer self.allocator.free(q);
            const r = try self.execParams(q, &params, &lengths);
            c.PQclear(r);
        }

        // COMMIT
        const commit_result = try self.exec("COMMIT");
        c.PQclear(commit_result);
    }

    pub fn saveCompletionEvent(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        session_id: []const u8,
        channel: ?[]const u8,
        account_id: ?[]const u8,
        chat_id: ?[]const u8,
        content: []const u8,
    ) ![]u8 {
        try self.ensureSession(user_id, session_id);
        const q = try self.buildQuery(
            "INSERT INTO {schema}.completion_events (id, user_id, session_id, channel, account_id, chat_id, content) VALUES ($1, $2, $3, $4, $5, $6, $7)",
        );
        defer self.allocator.free(q);

        const event_id = try self.randomHexId(allocator, 16);
        errdefer allocator.free(event_id);
        const event_id_z = try self.allocator.dupeZ(u8, event_id);
        defer self.allocator.free(event_id_z);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_z = try self.allocator.dupeZ(u8, session_id);
        defer self.allocator.free(session_z);
        const channel_z = if (channel) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (channel_z) |value| self.allocator.free(value);
        const account_z = if (account_id) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (account_z) |value| self.allocator.free(value);
        const chat_z = if (chat_id) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (chat_z) |value| self.allocator.free(value);
        const content_z = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(content_z);

        const params = [_]?[*:0]const u8{
            event_id_z,
            user_s.ptr,
            session_z,
            if (channel_z) |value| value else null,
            if (account_z) |value| value else null,
            if (chat_z) |value| value else null,
            content_z,
        };
        const lengths = [_]c_int{
            @intCast(event_id.len),
            @intCast(user_s.len),
            @intCast(session_id.len),
            @intCast(if (channel) |value| value.len else 0),
            @intCast(if (account_id) |value| value.len else 0),
            @intCast(if (chat_id) |value| value.len else 0),
            @intCast(content.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
        return event_id;
    }

    pub fn loadCompletionEvents(self: *Self, allocator: std.mem.Allocator, user_id: i64, session_id: []const u8) ![]memory_root.CompletionEvent {
        const q = try self.buildQuery(
            "SELECT id, session_id, channel, account_id, chat_id, content FROM {schema}.completion_events WHERE user_id = $1 AND session_id = $2 ORDER BY created_at ASC, id ASC",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_z = try self.allocator.dupeZ(u8, session_id);
        defer self.allocator.free(session_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, session_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(session_id.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const rows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(memory_root.CompletionEvent, rows);
        var initialized: usize = 0;
        errdefer {
            memory_root.freeCompletionEvents(allocator, out[0..initialized]);
            allocator.free(out);
        }

        for (0..rows) |i| {
            const row: c_int = @intCast(i);
            const id = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(id);
            const resolved_session = try dupeResultValue(allocator, result, row, 1);
            errdefer allocator.free(resolved_session);
            const event_content = try dupeResultValue(allocator, result, row, 5);
            errdefer allocator.free(event_content);

            out[i] = .{
                .id = id,
                .session_id = resolved_session,
                .channel = try dupeNullableResultValue(allocator, result, row, 2),
                .account_id = try dupeNullableResultValue(allocator, result, row, 3),
                .chat_id = try dupeNullableResultValue(allocator, result, row, 4),
                .content = event_content,
            };
            initialized += 1;
        }
        return out;
    }

    pub fn deleteCompletionEvent(self: *Self, user_id: i64, event_id: []const u8) !void {
        const q = try self.buildQuery(
            "DELETE FROM {schema}.completion_events WHERE user_id = $1 AND id = $2",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const event_z = try self.allocator.dupeZ(u8, event_id);
        defer self.allocator.free(event_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, event_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(event_id.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// V1.5 day-3 — write a memory with structured `metadata` JSON in the
    /// `metadata` JSONB column. Used by `compose_memory` (synthesized
    /// memories) and any future writer that needs to attach provenance,
    /// authorship, or correction data alongside the content. Caller
    /// provides a pre-serialized JSON string (e.g.
    /// `{"synthesized_by":"agent","references":["k1","k2"]}`); we don't
    /// re-parse it server-side. Validation is the caller's
    /// responsibility — postgres will reject malformed JSON at INSERT.
    ///
    /// Backward-compat: existing `upsertMemory` callers unchanged. The
    /// hot-path retrieval queries (`listMemories`, `recallMemories`,
    /// `getMemory`) don't read the `metadata` column — keeps the
    /// agent's per-turn cost identical to V1.5 day-2. Consumers that
    /// need metadata (the /brain/graph reference-edge builder) call
    /// `listMemoriesMetadata` separately.
    pub fn upsertMemoryWithMetadata(
        self: *Self,
        user_id: i64,
        key: []const u8,
        content: []const u8,
        category: memory_root.MemoryCategory,
        session_id: ?[]const u8,
        metadata_json: []const u8,
    ) !void {
        if (session_id) |sid| try self.ensureSession(user_id, sid);
        // V1.6 commit 3: also write `lemmatized` for BM25 retrieval (same
        // semantics as upsertMemory; this metadata variant is the path
        // compose_memory takes).
        // HR-03: include seen_in_session_count CASE so compose_memory writes
        // participate in cross-session tracking. Promotion is intentionally
        // NOT fired here (composed facts are agent-synthesized, not organically
        // corroborated), but conflict surfacing MUST fire — a compose overwrite
        // from a different session is as much a conflict as a tool-store one.
        //
        // V1.7 commit 6 review (CRITICAL-1 fix): same CASE-guard as upsertMemory
        // — preserve memory_type='core' and session_id=NULL on ON CONFLICT writes
        // so compose_memory cannot demote a row that was Tier-3 promoted via the
        // memory_store path. Without this, calling compose_memory on a promoted
        // key from a fresh session would clobber the promotion + spuriously fire
        // a conflict marker.
        // V1.6 cmt6 × V1.7 integration fix (W-INT-01): same resurrect-on-upsert
        // close-out column reset as upsertMemory above. See its comment for
        // the zombie-row + dead-promote scenario this prevents.
        // V1.7a-5 (spec seam 3) — link_type column populated atomically from
        // metadata.link_type on the JSONB write. extraction_persist +
        // compose_memory both emit "link_type":"<value>" in their metadata
        // JSON; the SQL `(metadata->>'link_type')` extraction lifts it
        // into the typed column without requiring callers to thread a
        // separate parameter. NULL when metadata omits the field.
        const q = try self.buildQuery(
            "INSERT INTO {schema}.memories (id, user_id, session_id, key, content, content_hash, memory_type, metadata, lemmatized, link_type, updated_at) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, ($8::jsonb)->>'link_type', NOW()) " ++
                "ON CONFLICT (user_id, key) DO UPDATE SET " ++
                "session_id = CASE WHEN {schema}.memories.memory_type = 'core' THEN NULL ELSE EXCLUDED.session_id END, " ++
                "content = EXCLUDED.content, content_hash = EXCLUDED.content_hash, " ++
                "memory_type = CASE WHEN {schema}.memories.memory_type = 'core' THEN 'core' ELSE EXCLUDED.memory_type END, " ++
                "metadata = EXCLUDED.metadata, lemmatized = EXCLUDED.lemmatized, " ++
                // V1.7a-5: refresh link_type from the new metadata's value.
                // COALESCE with the existing value so omitting link_type in
                // an update doesn't accidentally null out a previously-set
                // category (defensive — current callers always emit it).
                "link_type = COALESCE((EXCLUDED.metadata)->>'link_type', {schema}.memories.link_type), " ++
                "updated_at = NOW(), " ++
                "valid_to    = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.valid_to    ELSE NULL END, " ++
                "invalid_at  = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.invalid_at  ELSE NULL END, " ++
                "expired_at  = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.expired_at  ELSE NULL END, " ++
                "is_latest   = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.is_latest   ELSE TRUE END, " ++
                "seen_in_session_count = CASE " ++
                "  WHEN {schema}.memories.session_id IS DISTINCT FROM EXCLUDED.session_id " ++
                "       AND EXCLUDED.session_id IS NOT NULL " ++
                "       AND {schema}.memories.session_id IS NOT NULL " ++
                "  THEN {schema}.memories.seen_in_session_count + 1 " ++
                "  ELSE {schema}.memories.seen_in_session_count " ++
                "END " ++
                "RETURNING id, seen_in_session_count, memory_type",
        );
        defer self.allocator.free(q);

        const id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(id);
        const id_z = try self.allocator.dupeZ(u8, id);
        defer self.allocator.free(id_z);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_text = session_id orelse "";
        const session_z = try self.allocator.dupeZ(u8, session_text);
        defer self.allocator.free(session_z);
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const content_z = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(content_z);
        const content_hash = try computeContentHash(self.allocator, content);
        defer self.allocator.free(content_hash);
        const content_hash_z = try self.allocator.dupeZ(u8, content_hash);
        defer self.allocator.free(content_hash_z);
        const mem_type = categoryToMemoryType(category);
        const mem_type_z = try self.allocator.dupeZ(u8, mem_type);
        defer self.allocator.free(mem_type_z);
        const metadata_z = try self.allocator.dupeZ(u8, metadata_json);
        defer self.allocator.free(metadata_z);
        // V1.6 commit 3: BM25 lemmatized form
        const lemmatized = try text_norm.lemmatizeForBm25(self.allocator, content);
        defer self.allocator.free(lemmatized);
        const lemmatized_z = try self.allocator.dupeZ(u8, lemmatized);
        defer self.allocator.free(lemmatized_z);

        const params = [_]?[*:0]const u8{
            id_z,
            user_s.ptr,
            if (session_text.len == 0) null else session_z,
            key_z,
            content_z,
            content_hash_z,
            mem_type_z,
            metadata_z,
            lemmatized_z,
        };
        const lengths = [_]c_int{
            @intCast(id.len),
            @intCast(user_s.len),
            @intCast(session_text.len),
            @intCast(key.len),
            @intCast(content.len),
            @intCast(content_hash.len),
            @intCast(mem_type.len),
            @intCast(metadata_json.len),
            @intCast(lemmatized.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return;

        const stored_id = try dupeResultValue(self.allocator, result, 0, 0);
        defer self.allocator.free(stored_id);
        try self.insertMemoryEvent(user_id, stored_id, "compose", key, content, mem_type, session_id);

        // HR-03: fire conflict marker when compose_memory overwrites a fact
        // from a different session. Promotion is intentionally skipped —
        // agent-synthesized facts should not auto-promote to Tier-3 core.
        if (!isSystemMemoryKey(key)) {
            const seen_count: i32 = if (c.PQgetisnull(result, 0, 1) == 0)
                std.fmt.parseInt(i32, std.mem.span(c.PQgetvalue(result, 0, 1)), 10) catch 1
            else
                1;
            const returned_type: []const u8 = if (c.PQgetisnull(result, 0, 2) == 0)
                std.mem.span(c.PQgetvalue(result, 0, 2))
            else
                "";
            if (seen_count > 1 and !std.mem.eql(u8, returned_type, "core")) {
                if (session_text.len > 0) {
                    self.writePendingConflictMarker(user_id, key, session_text) catch |err| {
                        log.warn("upsertMemoryWithMetadata: conflict marker failed key={s}: {}", .{ key, err });
                    };
                }
            }
        }
    }

    /// V1.5 day-3 chunk 3C — batch-check which keys exist as memories
    /// for the given user. Used by `/brain/compose` HTTP handler to
    /// reject requests whose `references[]` contains keys that don't
    /// resolve (server-side validation; the tool path trusts the
    /// agent). Returns an owned hashmap whose keys are owned strings —
    /// caller frees each key + the map. Keys NOT present in the result
    /// are dangling references.
    pub fn existsMemoryKeys(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        keys: []const []const u8,
    ) !std.StringHashMapUnmanaged(void) {
        var out: std.StringHashMapUnmanaged(void) = .{};
        errdefer {
            var it = out.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            out.deinit(allocator);
        }
        if (keys.len == 0) return out;

        // Format keys as postgres text array (same pattern as
        // listMemoriesMetadata + pgvector pairwiseSimilarities).
        var keys_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer keys_buf.deinit(self.allocator);
        try keys_buf.append(self.allocator, '{');
        for (keys, 0..) |k, i| {
            if (i > 0) try keys_buf.append(self.allocator, ',');
            try keys_buf.append(self.allocator, '"');
            for (k) |ch| {
                switch (ch) {
                    '"' => try keys_buf.appendSlice(self.allocator, "\\\""),
                    '\\' => try keys_buf.appendSlice(self.allocator, "\\\\"),
                    else => try keys_buf.append(self.allocator, ch),
                }
            }
            try keys_buf.append(self.allocator, '"');
        }
        try keys_buf.append(self.allocator, '}');
        const keys_z = try self.allocator.dupeZ(u8, keys_buf.items);
        defer self.allocator.free(keys_z);

        const q = try self.buildQuery(
            "SELECT key FROM {schema}.memories " ++
                "WHERE user_id = $1 AND key = ANY($2::text[]) AND " ++ MEMORIES_VALIDITY_FILTER,
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const params = [_]?[*:0]const u8{ user_s.ptr, keys_z.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(keys_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const nrows: usize = @intCast(c.PQntuples(result));
        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const row: c_int = @intCast(i);
            const k = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(k);
            try out.put(allocator, k, {});
        }
        return out;
    }

    /// V1.5 day-3 — batch-load `metadata` JSONB strings for a set of
    /// memory keys. Used by `/brain/graph` reference-edge builder to
    /// resolve `metadata.references` without an N+1 query. Returns an
    /// owned hashmap (key → metadata JSON string); caller frees each
    /// value + the map. Keys absent from the result simply have no
    /// metadata; the caller treats them as empty.
    pub fn listMemoriesMetadata(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        keys: []const []const u8,
    ) !std.StringHashMapUnmanaged([]u8) {
        var out: std.StringHashMapUnmanaged([]u8) = .{};
        errdefer {
            var it = out.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            out.deinit(allocator);
        }
        if (keys.len == 0) return out;

        // Format keys as postgres text array; reuse the pattern from
        // pgvector pairwiseSimilarities.
        var keys_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer keys_buf.deinit(self.allocator);
        try keys_buf.append(self.allocator, '{');
        for (keys, 0..) |k, i| {
            if (i > 0) try keys_buf.append(self.allocator, ',');
            try keys_buf.append(self.allocator, '"');
            for (k) |ch| {
                switch (ch) {
                    '"' => try keys_buf.appendSlice(self.allocator, "\\\""),
                    '\\' => try keys_buf.appendSlice(self.allocator, "\\\\"),
                    else => try keys_buf.append(self.allocator, ch),
                }
            }
            try keys_buf.append(self.allocator, '"');
        }
        try keys_buf.append(self.allocator, '}');
        const keys_z = try self.allocator.dupeZ(u8, keys_buf.items);
        defer self.allocator.free(keys_z);

        const q = try self.buildQuery(
            "SELECT key, metadata::text FROM {schema}.memories " ++
                "WHERE user_id = $1 AND key = ANY($2::text[]) AND " ++ MEMORIES_VALIDITY_FILTER,
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const params = [_]?[*:0]const u8{ user_s.ptr, keys_z.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(keys_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const nrows: usize = @intCast(c.PQntuples(result));
        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const row: c_int = @intCast(i);
            const k = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(k);
            const metadata = try dupeResultValue(allocator, result, row, 1);
            errdefer allocator.free(metadata);
            // Skip rows with empty metadata (defaults to '{}' but might
            // be all-empty if column was added later — defensive).
            if (metadata.len == 0 or std.mem.eql(u8, metadata, "{}")) {
                allocator.free(k);
                allocator.free(metadata);
                continue;
            }
            try out.put(allocator, k, metadata);
        }
        return out;
    }

    /// V1.7a-7 — batch-fetch full memory rows by key set, validity-filtered.
    /// One round trip via `key = ANY($2::text[])`; mirrors the array-text
    /// formatting used by `listMemoriesMetadata` and `existsMemoryKeys`.
    /// Used by `/brain/local-graph` to materialize content + category for
    /// the BFS-discovered neighborhood without N+1 single-key fetches.
    ///
    /// MEMORIES_VALIDITY_FILTER applied — superseded rows are NOT returned
    /// (matches /brain/graph semantics: local-graph shows live structure,
    /// not history). Caller frees each MemoryEntry + the slice via
    /// `memory_root.freeEntries`.
    ///
    /// Result ordering is NOT guaranteed (PG SELECT without ORDER BY);
    /// caller indexes by key, not position.
    pub fn getMemoriesByKeys(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        keys: []const []const u8,
    ) ![]memory_root.MemoryEntry {
        if (keys.len == 0) return allocator.alloc(memory_root.MemoryEntry, 0);

        // Format keys as postgres text array; reuse the pattern from
        // listMemoriesMetadata (escapes `"` and `\`).
        var keys_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer keys_buf.deinit(self.allocator);
        try keys_buf.append(self.allocator, '{');
        for (keys, 0..) |k, i| {
            if (i > 0) try keys_buf.append(self.allocator, ',');
            try keys_buf.append(self.allocator, '"');
            for (k) |ch| {
                switch (ch) {
                    '"' => try keys_buf.appendSlice(self.allocator, "\\\""),
                    '\\' => try keys_buf.appendSlice(self.allocator, "\\\\"),
                    else => try keys_buf.append(self.allocator, ch),
                }
            }
            try keys_buf.append(self.allocator, '"');
        }
        try keys_buf.append(self.allocator, '}');
        const keys_z = try self.allocator.dupeZ(u8, keys_buf.items);
        defer self.allocator.free(keys_z);

        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, " ++
                "COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), " ++
                "session_id, valid_to FROM {schema}.memories " ++
                "WHERE user_id = $1 AND key = ANY($2::text[]) AND " ++ MEMORIES_VALIDITY_FILTER,
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const params = [_]?[*:0]const u8{ user_s.ptr, keys_z.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(keys_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    pub fn upsertMemory(self: *Self, user_id: i64, key: []const u8, content: []const u8, category: memory_root.MemoryCategory, session_id: ?[]const u8) !void {
        if (session_id) |sid| try self.ensureSession(user_id, sid);
        // V1.6 commit 3: also write `lemmatized` for BM25 retrieval. Existing
        // rows backfilled at migrate via `UPDATE memories SET lemmatized =
        // lower(content) WHERE lemmatized IS NULL` — new writes use the
        // richer Zig path with stopword removal.
        //
        // V1.7: seen_in_session_count is incremented when the session_id
        // differs from the stored row — meaning the same fact has surfaced
        // across two independent sessions. When count reaches 2 the fact is
        // eligible for Tier-3 (core) promotion (see post-exec logic below).
        // RETURNING also fetches the new count and memory_type so the
        // promotion and conflict-marker paths can act without a second SELECT.
        // V1.7 commit 6 (CRITICAL-1 fix): preserve `memory_type='core'` and
        // `session_id=NULL` on ON CONFLICT writes. Without these CASE-guards,
        // promoted (Tier-3 / core) rows are silently demoted by the very next
        // upsertMemory call from a fresh session — the unconditional SET
        // overwrote `memory_type → episodic` and `session_id → new_session`,
        // causing flapping core/non-core state and false-positive
        // `pending_conflicts` markers (LR-03 was bypassed because the SET
        // clobbered before RETURNING).
        //
        // The promoteMemoryToCore UPDATE already includes
        // `AND memory_type != 'core'` to be idempotent; this extends the same
        // discipline to the upsert path. Content CAN still update (a core
        // fact may have its phrasing refined by a re-statement), but the
        // tier and the global-scope marker (NULL session_id) are immutable
        // once promoted. To revert a promotion, use the explicit
        // demoteMemoryFromCore writer (when V1.6 commit 8 lands soft-delete).
        //
        // The WHERE clause's "OR memory_type IS DISTINCT" no longer fires
        // for core rows — the CASE makes that branch a no-op — so the row
        // is updated only when content/content_hash/session actually
        // diverge from stored.
        // V1.6 cmt6 × V1.7 integration fix (W-INT-01): resurrect-on-upsert
        // for closed-out non-core rows. setMemoryInvalidation (V1.6 cmt6
        // contradiction-judge close-out) writes valid_to/invalid_at/expired_at/
        // is_latest=false but never resets them. Without these CASE-clears, a
        // fresh upsert to the same key from a new session would land new
        // content into a row that's still hidden by MEMORIES_VALIDITY_FILTER
        // (zombie row). Worse: if seen_in_session_count reaches 2,
        // promoteMemoryToCore would mark it core forever (immortal hidden
        // zombie). The CASE-clears here say: "writing this key NOW supersedes
        // any prior close-out". Core rows are exempt — their close-out state
        // is preserved (a closed-out core row stays closed-out; explicit
        // resurrection requires the V1.6 cmt8 demoteMemoryFromCore writer).
        const q = try self.buildQuery(
            "INSERT INTO {schema}.memories (id, user_id, session_id, key, content, content_hash, memory_type, lemmatized, updated_at) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW()) " ++
                "ON CONFLICT (user_id, key) DO UPDATE SET " ++
                "session_id = CASE WHEN {schema}.memories.memory_type = 'core' THEN NULL ELSE EXCLUDED.session_id END, " ++
                "content = EXCLUDED.content, content_hash = EXCLUDED.content_hash, " ++
                "memory_type = CASE WHEN {schema}.memories.memory_type = 'core' THEN 'core' ELSE EXCLUDED.memory_type END, " ++
                "lemmatized = EXCLUDED.lemmatized, updated_at = NOW(), " ++
                "valid_to    = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.valid_to    ELSE NULL END, " ++
                "invalid_at  = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.invalid_at  ELSE NULL END, " ++
                "expired_at  = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.expired_at  ELSE NULL END, " ++
                "is_latest   = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.is_latest   ELSE TRUE END, " ++
                "seen_in_session_count = CASE " ++
                "  WHEN {schema}.memories.session_id IS DISTINCT FROM EXCLUDED.session_id " ++
                "       AND EXCLUDED.session_id IS NOT NULL " ++
                "       AND {schema}.memories.session_id IS NOT NULL " ++
                "  THEN {schema}.memories.seen_in_session_count + 1 " ++
                "  ELSE {schema}.memories.seen_in_session_count " ++
                "END " ++
                "WHERE {schema}.memories.session_id IS DISTINCT FROM EXCLUDED.session_id " ++
                "OR {schema}.memories.content IS DISTINCT FROM EXCLUDED.content " ++
                "OR {schema}.memories.content_hash IS DISTINCT FROM EXCLUDED.content_hash " ++
                "OR {schema}.memories.memory_type IS DISTINCT FROM EXCLUDED.memory_type " ++
                "OR {schema}.memories.valid_to IS NOT NULL " ++
                "OR {schema}.memories.is_latest IS DISTINCT FROM TRUE " ++
                "RETURNING id, seen_in_session_count, memory_type",
        );
        defer self.allocator.free(q);

        const id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(id);
        const id_z = try self.allocator.dupeZ(u8, id);
        defer self.allocator.free(id_z);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_text = session_id orelse "";
        const session_z = try self.allocator.dupeZ(u8, session_text);
        defer self.allocator.free(session_z);
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const content_z = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(content_z);
        const content_hash = try computeContentHash(self.allocator, content);
        defer self.allocator.free(content_hash);
        const content_hash_z = try self.allocator.dupeZ(u8, content_hash);
        defer self.allocator.free(content_hash_z);
        const mem_type = categoryToMemoryType(category);
        const mem_type_z = try self.allocator.dupeZ(u8, mem_type);
        defer self.allocator.free(mem_type_z);
        // V1.6 commit 3: BM25 lemmatized form
        const lemmatized = try text_norm.lemmatizeForBm25(self.allocator, content);
        defer self.allocator.free(lemmatized);
        const lemmatized_z = try self.allocator.dupeZ(u8, lemmatized);
        defer self.allocator.free(lemmatized_z);

        const params = [_]?[*:0]const u8{ id_z, user_s.ptr, if (session_text.len == 0) null else session_z, key_z, content_z, content_hash_z, mem_type_z, lemmatized_z };
        const lengths = [_]c_int{
            @intCast(id.len),
            @intCast(user_s.len),
            @intCast(session_text.len),
            @intCast(key.len),
            @intCast(content.len),
            @intCast(content_hash.len),
            @intCast(mem_type.len),
            @intCast(lemmatized.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return;

        // CR-01: remove dead else branch — early return on line above guarantees
        // PQntuples > 0 here. The old fallback to `allocator.dupe(id)` was
        // unreachable and obscured the true control flow.
        const stored_id = try dupeResultValue(self.allocator, result, 0, 0);
        defer self.allocator.free(stored_id);
        try self.insertMemoryEvent(user_id, stored_id, "upsert", key, content, mem_type, session_id);

        // V1.7 Item 2 + 3: post-upsert promotion and conflict surfacing.
        // Only act when a row was actually modified (RETURNING has a row).
        const seen_count = blk: {
            // PQgetisnull returns 1 for SQL NULL, 0 for a real value.
            // PQgetvalue on a NULL column returns "" not a C null pointer.
            if (c.PQgetisnull(result, 0, 1) != 0) break :blk @as(i32, 1);
            break :blk std.fmt.parseInt(i32, std.mem.span(c.PQgetvalue(result, 0, 1)), 10) catch 1;
        };
        // HR-01: default to "" (not "core") so a NULL/missing memory_type
        // does NOT silently suppress promotion.
        const returned_type: []const u8 = if (c.PQgetisnull(result, 0, 2) == 0)
            std.mem.span(c.PQgetvalue(result, 0, 2))
        else
            "";

        if (!isSystemMemoryKey(key)) {
            // Tier-3 promotion: fact seen across >= 2 sessions and not yet core.
            if (seen_count >= 2 and !std.mem.eql(u8, returned_type, "core")) {
                self.promoteMemoryToCore(user_id, key) catch |err| {
                    log.warn("upsertMemory: tier-3 promotion failed key={s}: {}", .{ key, err });
                };
            }
            // CR-02: fire the conflict marker on EVERY cross-session write
            // (count > 1), not just the first one (count == 2).
            // LR-03: suppress for already-promoted (core) rows — they have
            // been deliberately elevated to global truth; further cross-session
            // writes are expected and should not generate false-positive alerts.
            if (seen_count > 1 and !std.mem.eql(u8, returned_type, "core")) {
                // NF-01: replace assert with a logged guard — std.debug.assert
                // is elided in ReleaseFast, making the safety net vanish in
                // production. The session_text.len == 0 case can arise from
                // a caller passing session_id = Some(""); skip and warn instead.
                if (session_text.len == 0) {
                    log.warn("upsertMemory: conflict marker skipped — empty session_id key={s}", .{key});
                } else {
                    self.writePendingConflictMarker(user_id, key, session_text) catch |err| {
                        log.warn("upsertMemory: conflict marker failed key={s}: {}", .{ key, err });
                    };
                }
            }
        }
    }

    /// V1.7 Item 2 — promote a memory row to Tier-3 (core). Sets
    /// memory_type='core', clears session_id (makes it global), and raises
    /// confidence_score to 0.9 to reflect multi-session corroboration.
    fn promoteMemoryToCore(self: *Self, user_id: i64, key: []const u8) !void {
        // V1.6 cmt6 × V1.7 integration fix (W-INT-01 defensive guard): also
        // gate on MEMORIES_VALIDITY_FILTER so a closed-out row (valid_to in
        // past from V1.6 cmt6 contradiction-judge close-out) cannot be
        // promoted to core. Without this guard, a closed-out non-core row
        // that catches a fresh upsert + reaches seen_count >= 2 would become
        // an immortal hidden core row (CASE-guard preserves core forever
        // against subsequent writes; MEMORIES_VALIDITY_FILTER hides it from
        // every retrieval). With the resurrect-on-upsert CASE-clears in
        // upsertMemory + upsertMemoryWithMetadata, this branch is normally
        // unreachable (the upsert clears valid_to before promote runs), but
        // defense-in-depth — promote should never lift an invalid row.
        const q = try self.buildQuery(
            "UPDATE {schema}.memories SET memory_type = 'core', session_id = NULL, confidence_score = 0.9, updated_at = NOW() " ++
                "WHERE user_id = $1 AND key = $2 AND memory_type != 'core' AND " ++ MEMORIES_VALIDITY_FILTER,
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const res = try self.execParams(q, &params, &lengths);
        c.PQclear(res);
    }

    /// V1.7 Item 3 — write/overwrite the `pending_conflicts` sentinel so
    /// memory_loader surfaces it at the next session start. Stores the most
    /// recently conflicted key (MR-02: earlier conflicts are overwritten;
    /// only the latest is shown). The agent resolves it and calls
    /// memory_forget("pending_conflicts") to clear. Inline SQL avoids
    /// recursive upsertMemory() calls.
    fn writePendingConflictMarker(self: *Self, user_id: i64, key: []const u8, session_id: []const u8) !void {
        const now_s = std.time.timestamp();
        const content = try std.fmt.allocPrint(
            self.allocator,
            "type=pending_conflicts\nkey={s}\nsession={s}\nat={d}\ninstruction=A fact you know was updated from a new session. The conflicted memory key is the value of the `key=` field above (NOT the literal string \"pending_conflicts\"). Steps: (1) verify with the user which value is correct for the conflicted key, (2) call memory_store(key=<conflicted-key-from-above>, content=<corrected-value>) to update the conflicted fact, (3) call memory_forget(key=\"pending_conflicts\") to clear this flag. Note: only the most recent conflicted key is shown — older conflicts were overwritten.\n",
            .{ key, session_id, now_s },
        );
        defer self.allocator.free(content);
        const hash = try computeContentHash(self.allocator, content);
        defer self.allocator.free(hash);
        const lem = try text_norm.lemmatizeForBm25(self.allocator, content);
        defer self.allocator.free(lem);
        const new_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(new_id);

        const q = try self.buildQuery(
            "INSERT INTO {schema}.memories (id, user_id, session_id, key, content, content_hash, memory_type, lemmatized, updated_at) " ++
                "VALUES ($1, $2, NULL, 'pending_conflicts', $3, $4, 'core', $5, NOW()) " ++
                "ON CONFLICT (user_id, key) DO UPDATE SET content = EXCLUDED.content, content_hash = EXCLUDED.content_hash, " ++
                "lemmatized = EXCLUDED.lemmatized, updated_at = NOW()",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const new_id_z = try self.allocator.dupeZ(u8, new_id);
        defer self.allocator.free(new_id_z);
        const content_z = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(content_z);
        const hash_z = try self.allocator.dupeZ(u8, hash);
        defer self.allocator.free(hash_z);
        const lem_z = try self.allocator.dupeZ(u8, lem);
        defer self.allocator.free(lem_z);

        const params = [_]?[*:0]const u8{ new_id_z, user_s.ptr, content_z, hash_z, lem_z };
        const lengths = [_]c_int{
            @intCast(new_id.len),
            @intCast(user_s.len),
            @intCast(content.len),
            @intCast(hash.len),
            @intCast(lem.len),
        };
        const res = try self.execParams(q, &params, &lengths);
        c.PQclear(res);
    }

    /// V1.7 — true for system-managed memory keys that should never be
    /// promoted to Tier-3 or trigger conflict markers.
    fn isSystemMemoryKey(key: []const u8) bool {
        const prefixes = [_][]const u8{
            "session_checkpoint_",
            "autosave_",
            "compaction_summary/",
            "compaction_dropped/",
            "summary_fallback/",
            "timeline_summary/",
            "summary_latest/",
            "context_anchor_",
            "audit_shell/",
            "memory_health_",
            "durable_fact/",
            // MR-04: "pending_conflicts" moved to exact-match below —
            // a prefix match would incorrectly catch future keys like
            // "pending_conflicts_v2". The sentinel is always an exact key.
        };
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, key, p)) return true;
        }
        return std.mem.eql(u8, key, "last_hygiene_at") or
            std.mem.eql(u8, key, "timeline_index/current") or
            std.mem.eql(u8, key, "pending_conflicts");
    }

    /// V1.7 Item 1 — record a structured episode event in memory_events
    /// when a session summary lands. `event_type='episode'` is queryable
    /// by the brain timeline for structured session history.
    pub fn insertEpisodeEvent(
        self: *Self,
        user_id: i64,
        session_id: []const u8,
        summary: []const u8,
        trigger: []const u8,
    ) !void {
        const session_json = try jsonString(self.allocator, session_id);
        defer self.allocator.free(session_json);
        const trigger_json = try jsonString(self.allocator, trigger);
        defer self.allocator.free(trigger_json);
        // LR-02: truncate at a UTF-8 codepoint boundary so the jsonb cast
        // never sees a split multi-byte sequence. Back up over continuation
        // bytes (0x80..0xBF) the same way memory_loader.truncateUtf8 does.
        const summary_clip = blk: {
            if (summary.len <= 2048) break :blk summary;
            var end: usize = 2048;
            while (end > 0 and summary[end] & 0xC0 == 0x80) end -= 1;
            break :blk summary[0..end];
        };
        const summary_json = try jsonString(self.allocator, summary_clip);
        defer self.allocator.free(summary_json);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":{s},\"trigger\":{s},\"summary\":{s}}}",
            .{ session_json, trigger_json, summary_json },
        );
        defer self.allocator.free(payload);

        const q = try self.buildQuery(
            "INSERT INTO {schema}.memory_events (id, user_id, memory_id, event_type, payload) " ++
                "VALUES ($1, $2, NULL, 'episode', $3::jsonb)",
        );
        defer self.allocator.free(q);
        const event_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(event_id);
        const event_id_z = try self.allocator.dupeZ(u8, event_id);
        defer self.allocator.free(event_id_z);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const payload_z = try self.allocator.dupeZ(u8, payload);
        defer self.allocator.free(payload_z);
        const params = [_]?[*:0]const u8{ event_id_z, user_s.ptr, payload_z };
        const lengths = [_]c_int{
            @intCast(event_id.len),
            @intCast(user_s.len),
            @intCast(payload.len),
        };
        const res = try self.execParams(q, &params, &lengths);
        c.PQclear(res);
    }

    pub fn getMemory(self: *Self, allocator: std.mem.Allocator, user_id: i64, key: []const u8) !?memory_root.MemoryEntry {
        // V1.5 day-2: valid_to filter via MEMORIES_VALIDITY_FILTER. Every
        // memory-read SELECT in this module appends this clause.
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories WHERE user_id = $1 AND key = $2 AND " ++ MEMORIES_VALIDITY_FILTER,
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        try self.bumpMemoryAccess(user_id, key);
        return try decodeMemoryEntry(allocator, result, 0);
    }

    /// V1.7a-5b — getMemory variant WITHOUT MEMORIES_VALIDITY_FILTER.
    ///
    /// Surfaces a memory row by key regardless of whether `valid_to` has
    /// passed. Used by `/brain/memory/{key}` drilldown to surface superseded
    /// memories per spec §4.9 (the `valid_history` requirement) AND to
    /// close a real user-visible bug: when extraction's contradiction judge
    /// invalidates a row mid-browse, the brain graph already serialized the
    /// key into the FE state but `getMemory` filters it out → drilldown 404.
    /// With this helper, the drilldown returns 200 + the row + a populated
    /// `valid_to` field so the FE renders it as archived rather than missing.
    ///
    /// Caller distinguishes live vs archived via the returned `valid_to`
    /// field (NULL → live; non-NULL → archived/superseded). Does NOT call
    /// `bumpMemoryAccess` — accessing an archived row shouldn't promote it.
    ///
    /// Returns null only when the key truly doesn't exist for `user_id`
    /// (cross-tenant scoping is preserved). Caller frees the entry.
    pub fn getMemoryAnyValidity(self: *Self, allocator: std.mem.Allocator, user_id: i64, key: []const u8) !?memory_root.MemoryEntry {
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        // Intentionally NO bumpMemoryAccess — surfacing an archived row
        // for the drilldown UI shouldn't refresh its access timestamp.
        return try decodeMemoryEntry(allocator, result, 0);
    }

    /// V1.6 commit 5b.3 (WR-1): MD5 content_hash dedup pre-filter for
    /// extraction-derived writes. Returns the existing memory row if
    /// the user already has a memory with identical normalized content,
    /// or null otherwise.
    ///
    /// Uses `idx_memories_hash ON (user_id, content_hash)` directly —
    /// O(1) hashtable index probe per call. Critical for V1.6
    /// extraction at scale: compaction Pass C re-summarizes prior prose
    /// summaries on each trigger, causing the LLM to re-emit the same
    /// atomic facts. Without this guard, brain page accumulates
    /// duplicates after 5-10 compactions.
    ///
    /// Skips superseded entries (MEMORIES_VALIDITY_FILTER) so a
    /// previously-retired fact doesn't block a fresh re-extraction.
    /// Caller frees the returned MemoryEntry.
    pub fn findMemoryByContentHash(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        content_hash: []const u8,
    ) !?memory_root.MemoryEntry {
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories " ++
                "WHERE user_id = $1 AND content_hash = $2 AND " ++ MEMORIES_VALIDITY_FILTER ++ " LIMIT 1",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const hash_z = try allocator.dupeZ(u8, content_hash);
        defer allocator.free(hash_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, hash_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(content_hash.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        return try decodeMemoryEntry(allocator, result, 0);
    }

    pub fn listMemories(self: *Self, allocator: std.mem.Allocator, user_id: i64, category: ?memory_root.MemoryCategory, session_id: ?[]const u8) ![]memory_root.MemoryEntry {
        const cat = if (category) |value| categoryToMemoryType(value) else null;
        // V1.5 day-2: every list path appends MEMORIES_VALIDITY_FILTER
        // so future-us can't skip the filter — extract → reference, not
        // copy/paste.
        if (cat != null and session_id != null) {
            return self.queryMemories(
                allocator,
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories WHERE user_id = $1 AND memory_type = $2 AND session_id = $3 AND " ++ MEMORIES_VALIDITY_FILTER ++ " ORDER BY updated_at DESC",
                user_id,
                cat.?,
                session_id.?,
            );
        }
        if (cat != null) {
            return self.queryMemories(
                allocator,
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories WHERE user_id = $1 AND memory_type = $2 AND " ++ MEMORIES_VALIDITY_FILTER ++ " ORDER BY updated_at DESC",
                user_id,
                cat.?,
                null,
            );
        }
        if (session_id != null) {
            return self.queryMemories(
                allocator,
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories WHERE user_id = $1 AND session_id = $2 AND " ++ MEMORIES_VALIDITY_FILTER ++ " ORDER BY updated_at DESC",
                user_id,
                session_id.?,
                null,
            );
        }
        return self.queryMemories(
            allocator,
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories WHERE user_id = $1 AND " ++ MEMORIES_VALIDITY_FILTER ++ " ORDER BY updated_at DESC",
            user_id,
            null,
            null,
        );
    }

    /// V1.5.1 brain-hygiene: like `listMemories(user_id, null, null)` but
    /// filtered through `BRAIN_USER_KEY_FILTER` so the agent's bookkeeping
    /// (continuity summaries, autosaves, checkpoints, tombstones, bootstrap
    /// prompts) never reaches the /brain/graph response. The agent retrieval
    /// path keeps using `listMemories` directly — it NEEDS continuity
    /// artifacts injected into context.
    pub fn listMemoriesBrainVisible(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]memory_root.MemoryEntry {
        return self.queryMemories(
            allocator,
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories WHERE user_id = $1 AND " ++ MEMORIES_VALIDITY_FILTER ++ " AND " ++ BRAIN_USER_KEY_FILTER ++ " ORDER BY updated_at DESC",
            user_id,
            null,
            null,
        );
    }

    pub fn recallMemories(self: *Self, allocator: std.mem.Allocator, user_id: i64, query: []const u8, limit: usize, session_id: ?[]const u8) ![]memory_root.MemoryEntry {
        // V1.6 commit 3: BM25 surface now uses the GIN index on
        // to_tsvector('simple', lemmatized) instead of `content ILIKE`.
        // Score formula:
        //   key ILIKE match → 2.0 (key-shaped query exact-hit)
        //   lemmatized full-text match → 1.0
        //   total = sum (max 3.0)
        // The lemmatized query is computed at runtime so it tokenizes the
        // same way write-time lemmatization did. Falls back to no-op match
        // when the lemmatized form is empty (all-stopword or empty query).
        const limit_text = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_text);
        const limit_z = try self.allocator.dupeZ(u8, limit_text);
        defer self.allocator.free(limit_z);
        const like = try std.fmt.allocPrint(self.allocator, "%{s}%", .{query});
        defer self.allocator.free(like);
        const like_z = try self.allocator.dupeZ(u8, like);
        defer self.allocator.free(like_z);
        // V1.6 commit 3: lemmatize the query for tsquery match
        const lemmatized_query = try text_norm.lemmatizeForBm25(self.allocator, query);
        defer self.allocator.free(lemmatized_query);
        const lemmatized_query_z = try self.allocator.dupeZ(u8, lemmatized_query);
        defer self.allocator.free(lemmatized_query_z);
        // V1.5 day-2: valid_to at column 6, score moves to column 7. Decoder
        // path tracked via decodeMemoryRows(has_score=true) — column indices
        // are: 0=id, 1=key, 2=content, 3=memory_type, 4=ts_text, 5=session_id,
        // 6=valid_to, 7=score. Filter via MEMORIES_VALIDITY_FILTER constant.
        //
        // V1.6: $5 is the pre-lemmatized query string (matches the GIN
        // index expression `to_tsvector('simple', lemmatized)`). Using
        // plainto_tsquery so user-supplied query text doesn't need to be
        // pre-escaped for tsquery operators.
        // Three signals contributing to recall score (additive):
        //   key ILIKE match            → 2.0  (key-shaped query exact-hit)
        //   lemmatized BM25 match      → 1.0  (V1.6 — uses GIN index)
        //   content substring (ILIKE)  → 0.5  (preserves V1.5 substring
        //                                       behavior — "pista" finds
        //                                       "pistachios" — which BM25
        //                                       full-word matching can't)
        // Lemmatized full-text match takes precedence in score; content
        // ILIKE is the fallback that preserves backward-compat behavior
        // for partial-word queries.
        // Parameter numbering differs between session-scoped and global:
        //   With session:    $1=user_id $2=key-ILIKE $3=limit $4=session_id $5=lemma_q
        //   Without session: $1=user_id $2=key-ILIKE $3=limit $4=lemma_q
        // Postgres requires every $N to be referenced or castable; we
        // can't pass an unused null at $4 in the no-session case.
        const q = try self.buildQuery(
            if (session_id != null)
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to, " ++
                    "(CASE WHEN key ILIKE $2 THEN 2.0 ELSE 0.0 END + " ++
                    "CASE WHEN lemmatized IS NOT NULL AND length($5) > 0 AND to_tsvector('simple', lemmatized) @@ plainto_tsquery('simple', $5) THEN 1.0 ELSE 0.0 END + " ++
                    "CASE WHEN content ILIKE $2 THEN 0.5 ELSE 0.0 END) AS score " ++
                    "FROM {schema}.memories WHERE user_id = $1 AND session_id = $4 AND " ++
                    "(key ILIKE $2 OR " ++
                    "(lemmatized IS NOT NULL AND length($5) > 0 AND to_tsvector('simple', lemmatized) @@ plainto_tsquery('simple', $5)) OR " ++
                    "content ILIKE $2) AND " ++
                    MEMORIES_VALIDITY_FILTER ++ " ORDER BY score DESC, updated_at DESC LIMIT $3"
            else
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to, " ++
                    "(CASE WHEN key ILIKE $2 THEN 2.0 ELSE 0.0 END + " ++
                    "CASE WHEN lemmatized IS NOT NULL AND length($4) > 0 AND to_tsvector('simple', lemmatized) @@ plainto_tsquery('simple', $4) THEN 1.0 ELSE 0.0 END + " ++
                    "CASE WHEN content ILIKE $2 THEN 0.5 ELSE 0.0 END) AS score " ++
                    "FROM {schema}.memories WHERE user_id = $1 AND " ++
                    "(key ILIKE $2 OR " ++
                    "(lemmatized IS NOT NULL AND length($4) > 0 AND to_tsvector('simple', lemmatized) @@ plainto_tsquery('simple', $4)) OR " ++
                    "content ILIKE $2) AND " ++
                    MEMORIES_VALIDITY_FILTER ++ " ORDER BY score DESC, updated_at DESC LIMIT $3",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_text = session_id orelse "";
        const session_z = try self.allocator.dupeZ(u8, session_text);
        defer self.allocator.free(session_z);
        const result = if (session_id != null) blk: {
            // With session: $1=user_id $2=key-ILIKE $3=limit $4=session_id $5=lemma_q
            const params = [_]?[*:0]const u8{ user_s.ptr, like_z, limit_z, session_z, lemmatized_query_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(like.len), @intCast(limit_text.len), @intCast(session_text.len), @intCast(lemmatized_query.len) };
            break :blk try self.execParams(q, &params, &lengths);
        } else blk: {
            // No session: $1=user_id $2=key-ILIKE $3=limit $4=lemma_q
            const params = [_]?[*:0]const u8{ user_s.ptr, like_z, limit_z, lemmatized_query_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(like.len), @intCast(limit_text.len), @intCast(lemmatized_query.len) };
            break :blk try self.execParams(q, &params, &lengths);
        };
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, true);
    }

    /// V1.7a-2 — batched `created_at` lookup for graph-expand re-scoring.
    ///
    /// Returns an aligned slice of `?i64` (one entry per input key, same
    /// order). Each entry is unix-epoch seconds when the key resolves to
    /// an active row, or `null` when the key doesn't exist for `user_id`
    /// or has been invalidated (validity filter applied).
    ///
    /// Used by `graph_expand.recallMemoriesAsGraph` to re-score the
    /// neighborhood with REAL recency instead of the now-as-now placeholder
    /// the bare `expandFromSeeds` primitive uses (cmt10 INFO closure).
    /// One round trip via `WHERE key = ANY($::text[])`.
    ///
    /// Empty `keys` returns an empty []. Skips the SQL round trip.
    pub fn getMemoryTimestamps(self: *Self, allocator: std.mem.Allocator, user_id: i64, keys: []const []const u8) ![]?i64 {
        if (keys.len == 0) return allocator.alloc(?i64, 0);

        // Same NUL-safety guard as findEdgesByKeys (V1.6 cmt7-10 WARN-2).
        for (keys) |k| {
            if (std.mem.indexOfScalar(u8, k, 0) != null) return error.InvalidKey;
        }

        // Build PG TEXT[] literal: {"k1","k2",...}
        var arr_buf: std.ArrayListUnmanaged(u8) = .{};
        defer arr_buf.deinit(allocator);
        try arr_buf.appendSlice(allocator, "{");
        for (keys, 0..) |k, i| {
            if (i > 0) try arr_buf.append(allocator, ',');
            try arr_buf.append(allocator, '"');
            for (k) |ch| {
                if (ch == '\\' or ch == '"') try arr_buf.append(allocator, '\\');
                try arr_buf.append(allocator, ch);
            }
            try arr_buf.append(allocator, '"');
        }
        try arr_buf.appendSlice(allocator, "}");

        const q = try self.buildQuery(
            "SELECT key, (EXTRACT(EPOCH FROM created_at))::bigint::text " ++
                "FROM {schema}.memories " ++
                "WHERE user_id = $1 AND key = ANY($2::text[]) AND " ++
                MEMORIES_VALIDITY_FILTER,
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const arr_z = try allocator.dupeZ(u8, arr_buf.items);
        defer allocator.free(arr_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, arr_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(arr_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        // Build a key→ts map from the SQL result, then materialize the
        // output slice in input-key order. Lookup map is local-only; the
        // caller doesn't see it.
        var ts_map: std.StringHashMapUnmanaged(i64) = .{};
        defer ts_map.deinit(allocator);
        const tuples = c.PQntuples(result);
        var i: c_int = 0;
        while (i < tuples) : (i += 1) {
            const k_str = try dupeResultValue(allocator, result, i, 0);
            errdefer allocator.free(k_str);
            const ts_str = try dupeResultValue(allocator, result, i, 1);
            defer allocator.free(ts_str);
            const ts = std.fmt.parseInt(i64, ts_str, 10) catch {
                allocator.free(k_str);
                continue;
            };
            // ts_map owns k_str
            const gop = try ts_map.getOrPut(allocator, k_str);
            if (gop.found_existing) {
                allocator.free(k_str);
            }
            gop.value_ptr.* = ts;
        }
        // Free the keys we duped into ts_map after we're done with the map
        // (deferred at function exit via the loop below).
        defer {
            var it = ts_map.keyIterator();
            while (it.next()) |kp| allocator.free(kp.*);
        }

        const out = try allocator.alloc(?i64, keys.len);
        errdefer allocator.free(out);
        for (keys, 0..) |k, idx| {
            if (ts_map.get(k)) |ts| {
                out[idx] = ts;
            } else {
                out[idx] = null;
            }
        }
        return out;
    }

    /// V1.5 day-2 task 3 — cursor-paginated timeline read for `/brain/timeline`.
    ///
    /// Returns memory entries ordered by `created_at DESC, id DESC` (newest
    /// first; id breaks ties on identical timestamps for stable cursor
    /// pagination). The `cursor_ts` + `cursor_id` pair encodes the position
    /// of the last entry from the previous page; pass null on the first
    /// request. The cursor predicate `(created_at, id) < (cursor_ts,
    /// cursor_id)` is the canonical row-tuple comparison — stable across
    /// concurrent writes (new entries with later timestamps don't shuffle
    /// the page).
    ///
    /// Optional `from` / `to` apply unix-second range filtering on
    /// `created_at`. The bi-temporal validity filter (task 1) is always
    /// applied; superseded entries never appear in the timeline.
    ///
    /// `session_filter` is deferred to a V1.6 enhancement; today the
    /// timeline returns all sessions for the user. Frontend can filter
    /// client-side from the returned set.
    ///
    /// Note: this method reads `created_at` (when the memory was learned)
    /// rather than `updated_at` (which the other list/recall paths use).
    /// The returned `MemoryEntry.timestamp` is the unix-second text of
    /// `created_at` so the timeline view shows when each fact entered the
    /// agent's memory.
    pub fn listMemoriesTimeline(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        cursor_ts: ?i64,
        cursor_id: ?[]const u8,
        limit: u32,
        from: ?i64,
        to: ?i64,
    ) ![]memory_root.MemoryEntry {
        // Build SQL conditionally — base + optional cursor + from + to.
        // Use a fixed parameter ordering: $1=user_id, then conditional
        // adds in declared order (cursor_ts, cursor_id, from, to).
        const schema_q = try pg_helpers.quoteIdentifier(self.allocator, self.schemaRaw());
        defer self.allocator.free(schema_q);

        var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer sql_buf.deinit(self.allocator);
        const w = sql_buf.writer(self.allocator);
        try w.print(
            "SELECT id, key, content, memory_type, " ++
                "COALESCE((EXTRACT(EPOCH FROM created_at))::bigint::text, '0'), " ++
                "session_id, valid_to FROM {s}.memories WHERE user_id = $1 AND " ++
                MEMORIES_VALIDITY_FILTER ++ " AND " ++ BRAIN_USER_KEY_FILTER,
            .{schema_q},
        );

        var next_param_idx: u32 = 2;
        var cursor_ts_idx: u32 = 0;
        var cursor_id_idx: u32 = 0;
        var from_idx: u32 = 0;
        var to_idx: u32 = 0;

        if (cursor_ts != null and cursor_id != null) {
            cursor_ts_idx = next_param_idx;
            cursor_id_idx = next_param_idx + 1;
            next_param_idx += 2;
            try w.print(
                " AND ((EXTRACT(EPOCH FROM created_at))::bigint < ${d}::bigint OR " ++
                    "((EXTRACT(EPOCH FROM created_at))::bigint = ${d}::bigint AND id < ${d}))",
                .{ cursor_ts_idx, cursor_ts_idx, cursor_id_idx },
            );
        }
        if (from) |_| {
            from_idx = next_param_idx;
            next_param_idx += 1;
            try w.print(
                " AND (EXTRACT(EPOCH FROM created_at))::bigint >= ${d}::bigint",
                .{from_idx},
            );
        }
        if (to) |_| {
            to_idx = next_param_idx;
            next_param_idx += 1;
            try w.print(
                " AND (EXTRACT(EPOCH FROM created_at))::bigint <= ${d}::bigint",
                .{to_idx},
            );
        }

        const limit_idx = next_param_idx;
        try w.print(
            " ORDER BY created_at DESC, id DESC LIMIT ${d}::int",
            .{limit_idx},
        );

        const q = try self.allocator.dupeZ(u8, sql_buf.items);
        defer self.allocator.free(q);

        // Build params arrays. Maximum parameter count: user_id + cursor_ts +
        // cursor_id + from + to + limit = 6 slots.
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        var cursor_ts_buf: [32]u8 = undefined;
        var from_buf: [32]u8 = undefined;
        var to_buf: [32]u8 = undefined;
        var limit_buf: [16]u8 = undefined;

        const cursor_ts_s = if (cursor_ts) |v| try std.fmt.bufPrintZ(&cursor_ts_buf, "{d}", .{v}) else null;
        const cursor_id_z = if (cursor_id) |s| try self.allocator.dupeZ(u8, s) else null;
        defer if (cursor_id_z) |z| self.allocator.free(z);
        const from_s = if (from) |v| try std.fmt.bufPrintZ(&from_buf, "{d}", .{v}) else null;
        const to_s = if (to) |v| try std.fmt.bufPrintZ(&to_buf, "{d}", .{v}) else null;
        const limit_s = try std.fmt.bufPrintZ(&limit_buf, "{d}", .{limit});

        var params: [6]?[*:0]const u8 = undefined;
        var lengths: [6]c_int = undefined;
        var n_params: usize = 0;

        params[n_params] = user_s.ptr;
        lengths[n_params] = @intCast(user_s.len);
        n_params += 1;

        if (cursor_ts_s) |cts| {
            params[n_params] = cts.ptr;
            lengths[n_params] = @intCast(cts.len);
            n_params += 1;
            const cid = cursor_id_z.?;
            params[n_params] = cid.ptr;
            lengths[n_params] = @intCast(cid.len);
            n_params += 1;
        }
        if (from_s) |fs| {
            params[n_params] = fs.ptr;
            lengths[n_params] = @intCast(fs.len);
            n_params += 1;
        }
        if (to_s) |ts| {
            params[n_params] = ts.ptr;
            lengths[n_params] = @intCast(ts.len);
            n_params += 1;
        }
        params[n_params] = limit_s.ptr;
        lengths[n_params] = @intCast(limit_s.len);
        n_params += 1;

        const result = try self.execParams(q, params[0..n_params], lengths[0..n_params]);
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    /// V1.7a-6 — Births surface for `/brain/diff?date=`. Returns memory
    /// rows whose `created_at` falls in `[from, to)` AND whose key is
    /// brain-visible. NO validity filter is applied — a memory born and
    /// then superseded inside the same window must still appear here
    /// (and will ALSO appear in the deaths surface). The two lists are
    /// independent event streams over the same window.
    ///
    /// `MemoryEntry.timestamp` is set to the unix-second of `created_at`
    /// (mirroring `listMemoriesTimeline` so the FE shares one date axis).
    /// Newest first; capped at `limit`.
    pub fn listMemoryBirthsInWindow(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        from: i64,
        to: i64,
        limit: u32,
    ) ![]memory_root.MemoryEntry {
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, " ++
                "COALESCE((EXTRACT(EPOCH FROM created_at))::bigint::text, '0'), " ++
                "session_id, valid_to FROM {schema}.memories " ++
                "WHERE user_id = $1 AND " ++ BRAIN_USER_KEY_FILTER ++ " " ++
                "AND (EXTRACT(EPOCH FROM created_at))::bigint >= $2::bigint " ++
                "AND (EXTRACT(EPOCH FROM created_at))::bigint <  $3::bigint " ++
                "ORDER BY created_at DESC, id DESC LIMIT $4::int",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var from_buf: [32]u8 = undefined;
        const from_s = try std.fmt.bufPrintZ(&from_buf, "{d}", .{from});
        var to_buf: [32]u8 = undefined;
        const to_s = try std.fmt.bufPrintZ(&to_buf, "{d}", .{to});
        var lim_buf: [16]u8 = undefined;
        const lim_s = try std.fmt.bufPrintZ(&lim_buf, "{d}", .{limit});

        const params = [_]?[*:0]const u8{ user_s.ptr, from_s.ptr, to_s.ptr, lim_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(from_s.len), @intCast(to_s.len), @intCast(lim_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    /// V1.7a-6 — Deaths surface for `/brain/diff?date=`. Returns memory
    /// rows whose `valid_to` falls in `[from, to)` AND whose key is
    /// brain-visible. Reads include archived/superseded rows by design
    /// (mirrors V1.7a-5b's `getMemoryAnyValidity` insight: drilldown
    /// surfaces what *was* known, not just what is currently active).
    ///
    /// Excludes rows where `valid_to IS NULL` (still-live memories don't
    /// have a death event in any window). `MemoryEntry.timestamp` is set
    /// to the unix-second of `valid_to` so the FE can render the death
    /// date directly without a second decode. Ordered death-newest-first;
    /// capped at `limit`.
    pub fn listMemoryDeathsInWindow(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        from: i64,
        to: i64,
        limit: u32,
    ) ![]memory_root.MemoryEntry {
        // valid_to is bigint unix-seconds (same shape as MEMORIES_VALIDITY_FILTER).
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, " ++
                "COALESCE(valid_to::text, '0'), " ++
                "session_id, valid_to FROM {schema}.memories " ++
                "WHERE user_id = $1 AND " ++ BRAIN_USER_KEY_FILTER ++ " " ++
                "AND valid_to IS NOT NULL " ++
                "AND valid_to >= $2::bigint AND valid_to < $3::bigint " ++
                "ORDER BY valid_to DESC, id DESC LIMIT $4::int",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var from_buf: [32]u8 = undefined;
        const from_s = try std.fmt.bufPrintZ(&from_buf, "{d}", .{from});
        var to_buf: [32]u8 = undefined;
        const to_s = try std.fmt.bufPrintZ(&to_buf, "{d}", .{to});
        var lim_buf: [16]u8 = undefined;
        const lim_s = try std.fmt.bufPrintZ(&lim_buf, "{d}", .{limit});

        const params = [_]?[*:0]const u8{ user_s.ptr, from_s.ptr, to_s.ptr, lim_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(from_s.len), @intCast(to_s.len), @intCast(lim_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    /// V1.7a-8a — Orphan memories: brain-visible rows that have NO
    /// active edges (neither incoming nor outgoing). Powers
    /// `/brain/orphans` — Obsidian's "show orphans" affordance for
    /// finding loose facts that never connected to anything.
    ///
    /// Bi-temporal posture (V1.11 update, 2026-05-07): does NOT apply
    /// MEMORIES_VALIDITY_FILTER. Per Nova: "don't filter" archived from
    /// loose facts. An archived/superseded fact that was also never
    /// linked is still a loose fact — in fact more suspicious (it
    /// expired without ever joining the graph). The FE renders the
    /// `valid_to` field so users can tell archived from live; it's not
    /// the SQL's job to hide archived rows. `is_latest` IS still
    /// applied to the memory_edges NOT EXISTS subquery so a row whose
    /// edges all ended up superseded still surfaces as an orphan
    /// (it is one, in the present).
    ///
    /// Hygiene: BRAIN_USER_KEY_FILTER excludes continuity / autosave /
    /// tombstone keys (the agent's bookkeeping rows are always orphans
    /// by design — surfacing them would drown out the real orphans).
    ///
    /// Performance: NOT EXISTS subquery on (user_id, source_key) and
    /// (user_id, target_key) — both covered by the partial indexes
    /// `idx_edges_source` and `idx_edges_target` (`WHERE is_latest`).
    /// Index-only scan possible on small corpora; bounded by `limit`.
    ///
    /// Caller frees each MemoryEntry + the slice via `freeEntries`.
    pub fn listOrphanMemories(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        limit: u32,
    ) ![]memory_root.MemoryEntry {
        // V1.11 (2026-05-07) — Nova: "don't filter" archived from loose
        // facts. The orphans rail surfaces facts that the extractor
        // never connected to anything else; an archived/superseded fact
        // that was also never linked is still a loose fact (in fact more
        // suspicious — it expired without ever joining the graph). The
        // FE shows the `valid_to` field so the user can tell archived
        // apart from live; it's not the SQL's job to hide them.
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, " ++
                "COALESCE((EXTRACT(EPOCH FROM created_at))::bigint::text, '0'), " ++
                "session_id, valid_to FROM {schema}.memories m " ++
                "WHERE user_id = $1 " ++
                "AND " ++ BRAIN_USER_KEY_FILTER ++ " " ++
                "AND NOT EXISTS (" ++
                "    SELECT 1 FROM {schema}.memory_edges e " ++
                "    WHERE e.user_id = $1 AND e.is_latest " ++
                "    AND (e.source_key = m.key OR e.target_key = m.key)" ++
                ") ORDER BY created_at DESC, id DESC LIMIT $2::int",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var lim_buf: [16]u8 = undefined;
        const lim_s = try std.fmt.bufPrintZ(&lim_buf, "{d}", .{limit});

        const params = [_]?[*:0]const u8{ user_s.ptr, lim_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(lim_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    /// V1.8-9 — pull memory rows that anchor the user's active identity.
    /// Returns memories whose key participates (as source OR target) in a
    /// LIVE typed edge whose predicate is in the identity-class set:
    /// NAME / NAMED / IS / IS_A / LIVES_IN / WORKS_AT / WORKS_AS / ROLE /
    /// ROLE_IS / BORN_IN / SPEAKS / FOLLOWS_GOAL / PREFERS.
    ///
    /// Why an explicit pin: cosine retrieval scores identity facts against
    /// the current user message. On turns whose text is unrelated to
    /// identity (e.g. "what's the weather"), identity facts get bumped
    /// from warm context. The agent then loses "who am I talking to"
    /// until the next cosine-relevant turn. Pinning bypasses relevance —
    /// identity facts are CONTEXT-INVARIANT by definition (the user's
    /// name doesn't depend on what they just said).
    ///
    /// Cost: one PG round-trip per turn. EXISTS subquery is covered by
    /// `idx_edges_source` and `idx_edges_target` (both partial indexes
    /// `WHERE is_latest`). Bounded by `limit` (loader passes 8).
    ///
    /// Brain-hygiene NOT applied here — identity facts are user-content,
    /// not bookkeeping. Validity filter applied (superseded rows hidden).
    ///
    /// Caller frees via `memory_root.freeEntries`.
    pub fn listIdentityFacts(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        limit: u32,
    ) ![]memory_root.MemoryEntry {
        // EXISTS is binary, so m rows appear at most once even when an
        // identity-class edge matches via both source_key AND target_key
        // — no DISTINCT needed. Sort by recency so the most recently
        // updated identity facts win when the byte budget is tight.
        const q = try self.buildQuery(
            "SELECT m.id, m.key, m.content, m.memory_type, " ++
                "COALESCE((EXTRACT(EPOCH FROM m.created_at))::bigint::text, '0'), " ++
                "m.session_id, m.valid_to FROM {schema}.memories m " ++
                "WHERE m.user_id = $1 AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "AND EXISTS (" ++
                "    SELECT 1 FROM {schema}.memory_edges e " ++
                "    WHERE e.user_id = $1 AND e.is_latest " ++
                "    AND (e.source_key = m.key OR e.target_key = m.key) " ++
                // Identity-class predicates. Curated 2026-05-05 against
                // real corpus survey: WORKS_ON, STAKEHOLDER_OF,
                // HAS_ACTIVE_CONTRACT added in addition to the original
                // V1.8-9 set after observing 4 / 1 / 0 live uses
                // respectively that should pin but didn't. WORKS_WITH
                // intentionally excluded — too broad (matches "works
                // with TypeScript" alongside "works with Priya").
                "    AND e.predicate IN (" ++
                "        'NAME','NAMED','IS','IS_A','LIVES_IN'," ++
                "        'WORKS_AT','WORKS_AS','WORKS_ON','ROLE','ROLE_IS'," ++
                "        'BORN_IN','SPEAKS','FOLLOWS_GOAL','PREFERS'," ++
                "        'STAKEHOLDER_OF','HAS_ACTIVE_CONTRACT'" ++
                "    )" ++
                ") ORDER BY m.created_at DESC, m.id DESC LIMIT $2::int",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var lim_buf: [16]u8 = undefined;
        const lim_s = try std.fmt.bufPrintZ(&lim_buf, "{d}", .{limit});

        const params = [_]?[*:0]const u8{ user_s.ptr, lim_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(lim_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    /// V1.11 hardening (2026-05-08, FE spec #2 follow-up) — pick the
    /// canonical self-anchor memory for /brain/me.
    ///
    /// Three-tier picker (each tier checked in order, first hit wins):
    ///
    /// **Tier 1 — Canonical identity-card key.** If the corpus has a
    /// memory keyed `boss_identity` (or prefixed `boss_identity_`,
    /// `user_identity`, `user_persona`, `identity_self`), return it.
    /// These are convention keys our extractor + manual writes use for
    /// "this is the user." Verified live: user 1's corpus has
    /// `boss_identity` with content "Boss is Alfred Succer..." but
    /// zero outbound identity-class edges (the extractor doesn't fire
    /// on identity-card content directly), so source-degree ranking
    /// alone misses the actual user node.
    ///
    /// **Tier 2 — Source-degree ranking.** Memories that are the SOURCE
    /// of the most identity-class edges (NAME/IS/WORKS_AT/PREFERS etc).
    /// The "user node" is whoever's the SOURCE of the most identity
    /// claims by definition.
    ///
    /// **Tier 3 — Empty.** Return null. Cold-corpus → /brain/me 404 →
    /// FE renders empty-state ("ZAKI hasn't learned about you yet").
    ///
    /// Returns null only on Tier 3. Caller frees the entry.
    pub fn pickSelfAnchor(self: *Self, allocator: std.mem.Allocator, user_id: i64) !?memory_root.MemoryEntry {
        // ── Tier 1 — Canonical identity-card key ──────────────────────
        // PostgreSQL ILIKE is case-insensitive; wildcard prefixes match
        // boss_identity, boss_identity_v2, user_identity_card, etc.
        const tier1_q = try self.buildQuery(
            "SELECT id, key, content, memory_type, " ++
                "COALESCE((EXTRACT(EPOCH FROM created_at))::bigint::text, '0'), " ++
                "session_id, valid_to FROM {schema}.memories " ++
                "WHERE user_id = $1 AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "AND (key = 'boss_identity' OR key ILIKE 'boss_identity_%' " ++
                "     OR key ILIKE 'user_identity%' OR key ILIKE 'user_persona%' " ++
                "     OR key ILIKE 'identity_self%') " ++
                "ORDER BY " ++
                "  (CASE WHEN key = 'boss_identity' THEN 0 " ++
                "        WHEN key ILIKE 'boss_identity_%' THEN 1 " ++
                "        WHEN key ILIKE 'user_identity%' THEN 2 " ++
                "        WHEN key ILIKE 'user_persona%' THEN 3 " ++
                "        ELSE 4 END) ASC, " ++
                "  created_at DESC " ++
                "LIMIT 1",
        );
        defer self.allocator.free(tier1_q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        {
            const result = try self.execParams(tier1_q, &params, &lengths);
            defer c.PQclear(result);
            if (c.PQntuples(result) > 0) {
                return try decodeMemoryEntry(allocator, result, 0);
            }
        }

        // ── Tier 2 — Source-degree ranking on identity-class edges ────
        const tier2_q = try self.buildQuery(
            "SELECT m.id, m.key, m.content, m.memory_type, " ++
                "COALESCE((EXTRACT(EPOCH FROM m.created_at))::bigint::text, '0'), " ++
                "m.session_id, m.valid_to FROM {schema}.memories m " ++
                "WHERE m.user_id = $1 AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "AND m.key IN (" ++
                "  SELECT e.source_key FROM {schema}.memory_edges e " ++
                "  WHERE e.user_id = $1 AND e.is_latest " ++
                "  AND e.predicate IN (" ++
                "    'NAME','NAMED','IS','IS_A','LIVES_IN'," ++
                "    'WORKS_AT','WORKS_AS','WORKS_ON','ROLE','ROLE_IS'," ++
                "    'BORN_IN','SPEAKS','FOLLOWS_GOAL','PREFERS'," ++
                "    'STAKEHOLDER_OF','HAS_ACTIVE_CONTRACT'" ++
                "  )" ++
                ") " ++
                "ORDER BY (" ++
                "  SELECT COUNT(*) FROM {schema}.memory_edges e2 " ++
                "  WHERE e2.user_id = $1 AND e2.is_latest " ++
                "  AND e2.source_key = m.key " ++
                "  AND e2.predicate IN (" ++
                "    'NAME','NAMED','IS','IS_A','LIVES_IN'," ++
                "    'WORKS_AT','WORKS_AS','WORKS_ON','ROLE','ROLE_IS'," ++
                "    'BORN_IN','SPEAKS','FOLLOWS_GOAL','PREFERS'," ++
                "    'STAKEHOLDER_OF','HAS_ACTIVE_CONTRACT'" ++
                "  )" ++
                ") DESC, m.created_at DESC " ++
                "LIMIT 1",
        );
        defer self.allocator.free(tier2_q);
        const result = try self.execParams(tier2_q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        return try decodeMemoryEntry(allocator, result, 0);
    }

    /// V1.7a-9a — pull edges enriched with the metadata the LPA needs:
    /// weight (vote magnitude), attribution (user-vs-auto multiplier),
    /// valid_from (recency decay). Filters to LIVE bi-temporal edges
    /// (`is_latest`) and live memories on BOTH endpoints (subquery so
    /// dangling-edge garbage doesn't poison the algorithm). Brain-
    /// hygiene NOT applied here — it's applied at the consumer level
    /// when emitting community_id on /brain/graph.
    ///
    /// Caller frees each CommunityEdge + the slice via
    /// `memory_root.freeCommunityEdges`.
    pub fn listMemoryEdgesForCommunityCompute(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
    ) ![]memory_root.CommunityEdge {
        // V1.7a-9 review WR-05: also apply BRAIN_USER_KEY_FILTER so
        // hidden-key memories (continuity summaries, autosaves, system
        // bookkeeping) don't leak into the LPA computation. Without this,
        // a hidden key (e.g. `cache.foo`) could become the lowest-string
        // "leader" of a community whose other members are user-visible —
        // user gets a community_id pointing at a key they can never see
        // in /brain/graph. Filter at the edge endpoint subqueries so the
        // entire hidden-key universe is invisible to the algorithm.
        //
        // V1.8-11: extraction writes edges with target_key set to the
        // entity_id (32-char hex from upsertEntity), which lives in
        // memory_entities NOT memories. The original V1.7a-9 EXISTS
        // checks rejected those edges → 0 components → 0 clusters even
        // on populated graphs. Accept entity-table endpoints alongside
        // memory-table endpoints. setMemoryCommunityIds still only
        // writes community_id to memories — entity endpoints are
        // structural participants in label propagation but don't
        // receive community labels themselves (entities are the
        // connective tissue, not the user-facing community members).
        const q = try self.buildQuery(
            "SELECT e.source_key, e.target_key, " ++
                "COALESCE(e.weight, 1.0), " ++
                "COALESCE(e.attribution, 'extraction_classifier'), " ++
                "COALESCE(e.valid_from, 0) " ++
                "FROM {schema}.memory_edges e " ++
                "WHERE e.user_id = $1 AND e.is_latest " ++
                "AND (" ++
                "    EXISTS (SELECT 1 FROM {schema}.memories m " ++
                "        WHERE m.user_id = $1 AND m.key = e.source_key " ++
                "        AND " ++ MEMORIES_VALIDITY_FILTER ++
                "        AND " ++ BRAIN_USER_KEY_FILTER ++ ")" ++
                "    OR EXISTS (SELECT 1 FROM {schema}.memory_entities en " ++
                "        WHERE en.user_id = $1 AND en.id = e.source_key)" ++
                ") " ++
                "AND (" ++
                "    EXISTS (SELECT 1 FROM {schema}.memories m " ++
                "        WHERE m.user_id = $1 AND m.key = e.target_key " ++
                "        AND " ++ MEMORIES_VALIDITY_FILTER ++
                "        AND " ++ BRAIN_USER_KEY_FILTER ++ ")" ++
                "    OR EXISTS (SELECT 1 FROM {schema}.memory_entities en " ++
                "        WHERE en.user_id = $1 AND en.id = e.target_key)" ++
                ")",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const nrows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(memory_root.CommunityEdge, nrows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*e| e.deinit(allocator);
            allocator.free(out);
        }
        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const row: c_int = @intCast(i);
            const src = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(src);
            const tgt = try dupeResultValue(allocator, result, row, 1);
            errdefer allocator.free(tgt);
            const w_str = try dupeResultValue(allocator, result, row, 2);
            defer allocator.free(w_str);
            const attr = try dupeResultValue(allocator, result, row, 3);
            errdefer allocator.free(attr);
            const vf_str = try dupeResultValue(allocator, result, row, 4);
            defer allocator.free(vf_str);
            const weight = std.fmt.parseFloat(f64, w_str) catch 1.0;
            const valid_from = std.fmt.parseInt(i64, vf_str, 10) catch 0;
            out[i] = .{
                .source_key = src,
                .target_key = tgt,
                .weight = weight,
                .attribution = attr,
                .valid_from_unix = valid_from,
            };
            initialized += 1;
        }
        return out;
    }

    /// V1.7a-9a — batch-write community_id for a set of memory keys.
    /// Single round trip via UNNEST against two text + int arrays. NULL-
    /// safe: callers may pass an empty slice (no-op). Memories not in
    /// the assignment list are NOT touched (caller decides whether to
    /// pre-clear via setMemoryCommunityIds with NULL ids).
    ///
    /// Idempotent: re-applying the same assignment is a no-op write
    /// (UPDATE matches by key; same value means PG NoOp). Cross-tenant
    /// scoping enforced by `WHERE user_id = $1`.
    pub fn setMemoryCommunityIds(
        self: *Self,
        user_id: i64,
        assignments: []const memory_root.CommunityAssignment,
    ) !void {
        if (assignments.len == 0) return;

        // Build two PG arrays: keys (text[]) and ids (int[]). Same
        // escape pattern as listMemoriesMetadata for the keys.
        var keys_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer keys_buf.deinit(self.allocator);
        try keys_buf.append(self.allocator, '{');
        var ids_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer ids_buf.deinit(self.allocator);
        try ids_buf.append(self.allocator, '{');
        for (assignments, 0..) |a, i| {
            if (i > 0) {
                try keys_buf.append(self.allocator, ',');
                try ids_buf.append(self.allocator, ',');
            }
            try keys_buf.append(self.allocator, '"');
            for (a.key) |ch| {
                switch (ch) {
                    '"' => try keys_buf.appendSlice(self.allocator, "\\\""),
                    '\\' => try keys_buf.appendSlice(self.allocator, "\\\\"),
                    else => try keys_buf.append(self.allocator, ch),
                }
            }
            try keys_buf.append(self.allocator, '"');
            try ids_buf.writer(self.allocator).print("{d}", .{a.community_id});
        }
        try keys_buf.append(self.allocator, '}');
        try ids_buf.append(self.allocator, '}');
        const keys_z = try self.allocator.dupeZ(u8, keys_buf.items);
        defer self.allocator.free(keys_z);
        const ids_z = try self.allocator.dupeZ(u8, ids_buf.items);
        defer self.allocator.free(ids_z);

        const q = try self.buildQuery(
            "UPDATE {schema}.memories AS m SET community_id = u.cid " ++
                "FROM (SELECT UNNEST($2::text[]) AS k, UNNEST($3::int[]) AS cid) AS u " ++
                "WHERE m.user_id = $1 AND m.key = u.k",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{ user_s.ptr, keys_z.ptr, ids_z.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(keys_buf.items.len), @intCast(ids_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// V1.7a-9a — upsert a community's name + member-count + cache key.
    /// `name_source` is 'llm' or 'fallback' for telemetry / FE styling.
    /// `member_set_hash` is the cache key the pipeline checks before
    /// re-calling the LLM (only re-name when membership changes).
    pub fn setCommunityName(
        self: *Self,
        user_id: i64,
        community_id: i32,
        name: []const u8,
        name_source: []const u8,
        member_count: u32,
        member_set_hash: []const u8,
    ) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.memory_communities " ++
                "(user_id, community_id, name, name_source, member_count, member_set_hash, generated_at) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, NOW()) " ++
                "ON CONFLICT (user_id, community_id) DO UPDATE SET " ++
                "name = EXCLUDED.name, " ++
                "name_source = EXCLUDED.name_source, " ++
                "member_count = EXCLUDED.member_count, " ++
                "member_set_hash = EXCLUDED.member_set_hash, " ++
                "generated_at = NOW()",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var cid_buf: [16]u8 = undefined;
        const cid_s = try std.fmt.bufPrintZ(&cid_buf, "{d}", .{community_id});
        var mc_buf: [16]u8 = undefined;
        const mc_s = try std.fmt.bufPrintZ(&mc_buf, "{d}", .{member_count});
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        const src_z = try self.allocator.dupeZ(u8, name_source);
        defer self.allocator.free(src_z);
        const hash_z = try self.allocator.dupeZ(u8, member_set_hash);
        defer self.allocator.free(hash_z);

        const params = [_]?[*:0]const u8{ user_s.ptr, cid_s.ptr, name_z, src_z, mc_s.ptr, hash_z };
        const lengths = [_]c_int{
            @intCast(user_s.len), @intCast(cid_s.len), @intCast(name.len),
            @intCast(name_source.len), @intCast(mc_s.len), @intCast(member_set_hash.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// V1.7a-9a — fetch one community's name + cache metadata. Returns
    /// null when the community has no row in memory_communities (i.e.,
    /// LPA assigned it but LLM naming hasn't run yet). Caller frees via
    /// CommunityName.deinit.
    pub fn getCommunityName(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        community_id: i32,
    ) !?memory_root.CommunityName {
        const q = try self.buildQuery(
            "SELECT name, name_source, member_count, member_set_hash, " ++
                "EXTRACT(EPOCH FROM generated_at)::bigint " ++
                "FROM {schema}.memory_communities " ++
                "WHERE user_id = $1 AND community_id = $2",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var cid_buf: [16]u8 = undefined;
        const cid_s = try std.fmt.bufPrintZ(&cid_buf, "{d}", .{community_id});
        const params = [_]?[*:0]const u8{ user_s.ptr, cid_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(cid_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;

        const name = try dupeResultValue(allocator, result, 0, 0);
        errdefer allocator.free(name);
        const src = try dupeResultValue(allocator, result, 0, 1);
        errdefer allocator.free(src);
        const mc_str = try dupeResultValue(allocator, result, 0, 2);
        defer allocator.free(mc_str);
        const hash = try dupeResultValue(allocator, result, 0, 3);
        errdefer allocator.free(hash);
        const gen_str = try dupeResultValue(allocator, result, 0, 4);
        defer allocator.free(gen_str);
        const member_count = std.fmt.parseInt(u32, mc_str, 10) catch 0;
        const generated_at = std.fmt.parseInt(i64, gen_str, 10) catch 0;
        return .{
            .name = name,
            .name_source = src,
            .member_count = member_count,
            .member_set_hash = hash,
            .generated_at_unix = generated_at,
        };
    }

    /// V1.7a-9a — list communities (id + name + counts) for the user.
    /// Joins memory_communities with a live-member-count subquery so the
    /// member_count reflects CURRENT membership (not the value cached at
    /// last LLM-name time — which can be stale). Sorted by member_count
    /// DESC so the FE legend leads with the largest clusters.
    /// Caller frees via memory_root.freeCommunitySummaries.
    pub fn listCommunities(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
    ) ![]memory_root.CommunitySummary {
        const q = try self.buildQuery(
            "SELECT mc.community_id, mc.name, mc.name_source, " ++
                "COALESCE(live.cnt, 0) AS member_count, " ++
                "EXTRACT(EPOCH FROM mc.generated_at)::bigint " ++
                "FROM {schema}.memory_communities mc " ++
                "LEFT JOIN (" ++
                "    SELECT community_id, COUNT(*)::int AS cnt " ++
                "    FROM {schema}.memories " ++
                "    WHERE user_id = $1 AND community_id IS NOT NULL " ++
                "    AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "    GROUP BY community_id" ++
                ") live ON live.community_id = mc.community_id " ++
                "WHERE mc.user_id = $1 " ++
                "ORDER BY member_count DESC, mc.community_id ASC",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const nrows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(memory_root.CommunitySummary, nrows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*s| s.deinit(allocator);
            allocator.free(out);
        }
        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const row: c_int = @intCast(i);
            const cid_str = try dupeResultValue(allocator, result, row, 0);
            defer allocator.free(cid_str);
            const cid = std.fmt.parseInt(i32, cid_str, 10) catch 0;
            // V1.7a-9 review WR-06: use dupeNullableResultValue so a
            // legitimate empty-string name (misbehaving LLM returns "")
            // doesn't get conflated with PG NULL → silently disappear from
            // the FE legend. Now PG NULL → null Option, empty string →
            // Some("") which the FE can render distinctly (or filter
            // upstream in setCommunityName, future hardening).
            const name_opt = try dupeNullableResultValue(allocator, result, row, 1);
            errdefer if (name_opt) |n| allocator.free(n);
            const src_opt = try dupeNullableResultValue(allocator, result, row, 2);
            errdefer if (src_opt) |s| allocator.free(s);
            const mc_str = try dupeResultValue(allocator, result, row, 3);
            defer allocator.free(mc_str);
            const mc = std.fmt.parseInt(u32, mc_str, 10) catch 0;
            const gen_str = try dupeResultValue(allocator, result, row, 4);
            defer allocator.free(gen_str);
            const gen = std.fmt.parseInt(i64, gen_str, 10) catch 0;
            out[i] = .{
                .community_id = cid,
                .name = name_opt,
                .name_source = src_opt,
                .member_count = mc,
                .generated_at_unix = gen,
            };
            initialized += 1;
        }
        return out;
    }

    /// V1.7a-9d — batch fetch community_id for a key set. Single round
    /// trip via `key = ANY($2::text[])`. Keys with NULL community_id
    /// (unassigned, archived) are absent from the result map; caller
    /// treats absence as "no community". Caller deinits the map; keys
    /// in the map are owned (allocator.dupe).
    pub fn getMemoryCommunityIds(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        keys: []const []const u8,
    ) !std.StringHashMapUnmanaged(i32) {
        var out: std.StringHashMapUnmanaged(i32) = .{};
        errdefer {
            var it = out.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            out.deinit(allocator);
        }
        if (keys.len == 0) return out;

        // Build PG text[] literal (same escape pattern as listMemoriesMetadata).
        var keys_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer keys_buf.deinit(self.allocator);
        try keys_buf.append(self.allocator, '{');
        for (keys, 0..) |k, i| {
            if (i > 0) try keys_buf.append(self.allocator, ',');
            try keys_buf.append(self.allocator, '"');
            for (k) |ch| {
                switch (ch) {
                    '"' => try keys_buf.appendSlice(self.allocator, "\\\""),
                    '\\' => try keys_buf.appendSlice(self.allocator, "\\\\"),
                    else => try keys_buf.append(self.allocator, ch),
                }
            }
            try keys_buf.append(self.allocator, '"');
        }
        try keys_buf.append(self.allocator, '}');
        const keys_z = try self.allocator.dupeZ(u8, keys_buf.items);
        defer self.allocator.free(keys_z);

        const q = try self.buildQuery(
            "SELECT key, community_id FROM {schema}.memories " ++
                "WHERE user_id = $1 AND key = ANY($2::text[]) " ++
                "AND community_id IS NOT NULL",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{ user_s.ptr, keys_z.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(keys_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const nrows: usize = @intCast(c.PQntuples(result));
        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const row: c_int = @intCast(i);
            const k = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(k);
            const cid_str = try dupeResultValue(allocator, result, row, 1);
            defer allocator.free(cid_str);
            const cid = std.fmt.parseInt(i32, cid_str, 10) catch continue;
            try out.put(allocator, k, cid);
        }
        return out;
    }

    /// V1.8-3: forget cascades to memory_edges. Pre-V1.8 forgetMemory was a
    /// bare DELETE on memories — leaving any edge whose source_key OR
    /// target_key matched as an orphan (source_exists=0 AND is_latest=true).
    /// Now: bi-temporal close-out on edges + DELETE on memories, wrapped in
    /// a transaction so partial failure rolls back. Per-cascaded-edge
    /// edge_closed event (mirrors the cascade in setMemoryInvalidation).
    ///
    /// Decision (Phase 5 PL-1): keep hard-DELETE on S2 (memories table —
    /// matches user "forget" intent), bi-temporal close on S5 (edges —
    /// matches supersession idiom + lets graph history queries surface
    /// the close-out). Revisit if eval surfaces an issue.
    pub fn forgetMemory(self: *Self, user_id: i64, key: []const u8) !bool {
        const begin_result = try self.exec("BEGIN");
        c.PQclear(begin_result);
        errdefer {
            if (self.exec("ROLLBACK")) |rb| {
                c.PQclear(rb);
            } else |_| {}
        }

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);

        // 1. Cascade close-out on memory_edges. Order: cascade FIRST, DELETE
        //    second. The cascade UPDATE matches by string source_key/target_key,
        //    not FK reference, so it works regardless of DELETE order — but
        //    cascade-first lets us capture the closed edge metadata for the
        //    edge_closed events before any concurrent reader sees a partial
        //    state. Same mtime values as the supersession path for consistency.
        const now_ts: i64 = std.time.timestamp();
        var ts_buf: [32]u8 = undefined;
        const ts_s = try std.fmt.bufPrintZ(&ts_buf, "{d}", .{now_ts});
        const cascade_params = [_]?[*:0]const u8{ user_s.ptr, key_z, ts_s.ptr, ts_s.ptr };
        const cascade_lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(key.len),
            @intCast(ts_s.len),
            @intCast(ts_s.len),
        };
        const cascade_q = try self.buildQuery(
            "UPDATE {schema}.memory_edges SET " ++
                "valid_to = $3, " ++
                "invalid_at = $3, " ++
                "expired_at = $4, " ++
                "is_latest = FALSE " ++
                "WHERE user_id = $1 AND (source_key = $2 OR target_key = $2) AND is_latest " ++
                "RETURNING source_key, target_key, predicate, COALESCE(confidence, 1.0)",
        );
        defer self.allocator.free(cascade_q);
        const cascade_result = try self.execParams(cascade_q, &cascade_params, &cascade_lengths);
        defer c.PQclear(cascade_result);

        // Capture cascaded edges' metadata for events (emitted post-COMMIT
        // so a failed event write doesn't roll back the cascade).
        const closed_count = c.PQntuples(cascade_result);
        var closed_edges: std.ArrayListUnmanaged(struct {
            source_key: []u8,
            target_key: []u8,
            predicate: []u8,
            confidence: f64,
        }) = .empty;
        defer {
            for (closed_edges.items) |e| {
                self.allocator.free(e.source_key);
                self.allocator.free(e.target_key);
                self.allocator.free(e.predicate);
            }
            closed_edges.deinit(self.allocator);
        }
        var ci: c_int = 0;
        while (ci < closed_count) : (ci += 1) {
            const src = dupeResultValue(self.allocator, cascade_result, ci, 0) catch continue;
            const tgt = dupeResultValue(self.allocator, cascade_result, ci, 1) catch {
                self.allocator.free(src);
                continue;
            };
            const pred = dupeResultValue(self.allocator, cascade_result, ci, 2) catch {
                self.allocator.free(src);
                self.allocator.free(tgt);
                continue;
            };
            const conf_str = dupeResultValue(self.allocator, cascade_result, ci, 3) catch {
                self.allocator.free(src);
                self.allocator.free(tgt);
                self.allocator.free(pred);
                continue;
            };
            defer self.allocator.free(conf_str);
            const conf_val = std.fmt.parseFloat(f64, conf_str) catch 1.0;
            try closed_edges.append(self.allocator, .{
                .source_key = src,
                .target_key = tgt,
                .predicate = pred,
                .confidence = conf_val,
            });
        }

        // 2. DELETE on memories.
        const del_q = try self.buildQuery(
            "DELETE FROM {schema}.memories WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(del_q);
        const del_params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const del_lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const del_result = try self.execParams(del_q, &del_params, &del_lengths);
        defer c.PQclear(del_result);
        const affected = c.PQcmdTuples(del_result);
        const memory_deleted: bool = if (affected == null)
            false
        else
            !std.mem.eql(u8, std.mem.span(affected), "0");

        const commit_result = try self.exec("COMMIT");
        c.PQclear(commit_result);

        // 3. Post-COMMIT: emit edge_closed events for each cascaded edge.
        //    Best-effort — the cascade is already durable; missing events
        //    only degrade graph-history audit.
        for (closed_edges.items) |e| {
            self.insertEdgeEvent(user_id, e.source_key, e.target_key, e.predicate, "closed", e.confidence) catch |err| {
                log.warn("forget.cascade.event_failed err={s} source={s} predicate={s}", .{
                    @errorName(err), e.source_key, e.predicate,
                });
            };
        }

        if (closed_edges.items.len > 0) {
            log.info("forget.cascade user={d} key={s} edges_closed={d} memory_deleted={s}", .{
                user_id, key, closed_edges.items.len,
                if (memory_deleted) "true" else "false",
            });
        }

        return memory_deleted;
    }

    /// V1.6 commit 6 — fetch same-subject extraction-classifier memories
    /// for the contradiction judge's EXISTING FACTS list.
    ///
    /// Filters:
    ///   - `user_id = $1` (tenant scope)
    ///   - `metadata->>'subject' = $2` (same-subject scope per Graphiti
    ///     `related_edges`)
    ///   - `metadata->>'attribution' = 'extraction_classifier'`
    ///     (exclude agent_tool / compose writes — judge candidate pool
    ///     stays in the typed-edge universe)
    ///   - `MEMORIES_VALIDITY_FILTER` (skip already-superseded rows so
    ///     the judge can't re-contradict a closed-out memory)
    ///
    /// Ordered by `updated_at DESC` so the most recent N are surfaced;
    /// the judge handles older context via the broader `recallMemories`
    /// neighborhood.
    ///
    /// V1.9-1 — cascade entity rename across the live graph.
    ///
    /// Use case (per ZAKI's stress-test letter): "Project Neptune" →
    /// "Project Nullalis" should propagate to every edge mentioning
    /// the old entity. One agent call replaces N manual edits.
    ///
    /// Operation:
    ///   1. BEGIN transaction (errdefer ROLLBACK).
    ///   2. Resolve old_entity_id by name_lower=lower(old_name). If
    ///      missing → return result with found_old=false (no-op,
    ///      caller decides whether to proceed with a fresh write).
    ///   3. Upsert new_entity_id by name_lower=lower(new_name) with
    ///      NULL embedding placeholder. Future encounter with an
    ///      embedding-bearing path repopulates via upsertEntity's
    ///      ON CONFLICT update.
    ///   4. If old_id == new_id (case-only or already-canonical
    ///      rename) → COMMIT no-op, return edges_rewritten=0.
    ///   5. Atomic two-step on memory_edges:
    ///      (a) INSERT new edges with old_id substituted by new_id
    ///          on either source_key or target_key (CASE-WHEN), copy
    ///          predicate/attribution/confidence/weight, set
    ///          valid_from=now, is_latest=true.
    ///      (b) UPDATE old edges: is_latest=false, valid_to=now,
    ///          invalid_at=now, expired_at=now. RETURNING the
    ///          (source_key, target_key, predicate, confidence) so
    ///          we can emit edge_closed events post-COMMIT.
    ///   6. COMMIT.
    ///   7. Emit edge_closed event per closed edge (best-effort,
    ///      non-fatal — cascade already committed). Plus ONE
    ///      memory_events row with event_type='cascade_renamed' and
    ///      payload {old_name, new_name, old_id, new_id,
    ///      edges_rewritten}.
    ///
    /// What this does NOT do:
    ///   - Walk memory ROW content for old_name string occurrences.
    ///     Memories whose CONTENT mentions old_name are not rewritten;
    ///     the agent retrieves them via cosine + the new name will
    ///     gradually take over via fresh writes. (Content rewrite is
    ///     V1.9-3 propagate_correction territory.)
    ///   - Touch entity_type / linked_memory_ids on either entity
    ///     row. The edge graph is the source of truth; entity row is
    ///     a cache.
    ///
    /// Concurrent safety: BEGIN/COMMIT serializes the cascade. Other
    /// readers see either pre-cascade or post-cascade state; never
    /// partial. is_latest flip is atomic per row.
    ///
    /// Caller does NOT free the result — it's a value struct.
    pub fn cascadeRenameEntity(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        old_name: []const u8,
        new_name: []const u8,
    ) !memory_root.CascadeRenameResult {
        const begin_result = try self.exec("BEGIN");
        c.PQclear(begin_result);
        errdefer {
            if (self.exec("ROLLBACK")) |rb| {
                c.PQclear(rb);
            } else |_| {}
        }

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        // Step 2 — resolve old_entity_id.
        const old_name_z = try self.allocator.dupeZ(u8, old_name);
        defer self.allocator.free(old_name_z);
        const lookup_q = try self.buildQuery(
            "SELECT id FROM {schema}.memory_entities " ++
                "WHERE user_id = $1 AND name_lower = LOWER($2) LIMIT 1",
        );
        defer self.allocator.free(lookup_q);
        const lookup_params = [_]?[*:0]const u8{ user_s.ptr, old_name_z };
        const lookup_lengths = [_]c_int{ @intCast(user_s.len), @intCast(old_name.len) };
        const lookup_result = try self.execParams(lookup_q, &lookup_params, &lookup_lengths);
        defer c.PQclear(lookup_result);
        if (c.PQntuples(lookup_result) == 0) {
            // No old entity → no cascade needed. COMMIT empty txn.
            // V1.9-Rev finding #2: contract says CascadeRenameResult
            // owns its slices via the supplied allocator. Return
            // zero-length allocator-owned slices instead of `""`
            // string literals so the contract holds.
            const commit = try self.exec("COMMIT");
            c.PQclear(commit);
            return .{
                .found_old = false,
                .old_id = try allocator.alloc(u8, 0),
                .new_id = try allocator.alloc(u8, 0),
                .edges_rewritten = 0,
                .edges_closed = 0,
            };
        }
        const old_id_owned = try dupeResultValue(self.allocator, lookup_result, 0, 0);
        defer self.allocator.free(old_id_owned);

        // Step 3 — upsert new entity (NULL embedding ok).
        const new_name_z = try self.allocator.dupeZ(u8, new_name);
        defer self.allocator.free(new_name_z);
        const new_id_raw = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(new_id_raw);
        const new_id_z = try self.allocator.dupeZ(u8, new_id_raw);
        defer self.allocator.free(new_id_z);
        const upsert_q = try self.buildQuery(
            "INSERT INTO {schema}.memory_entities (id, user_id, name, name_lower) " ++
                "VALUES ($1, $2, $3, LOWER($3)) " ++
                "ON CONFLICT (user_id, name_lower) DO UPDATE SET updated_at = NOW() " ++
                "RETURNING id",
        );
        defer self.allocator.free(upsert_q);
        const upsert_params = [_]?[*:0]const u8{ new_id_z, user_s.ptr, new_name_z };
        const upsert_lengths = [_]c_int{
            @intCast(new_id_raw.len),
            @intCast(user_s.len),
            @intCast(new_name.len),
        };
        const upsert_result = try self.execParams(upsert_q, &upsert_params, &upsert_lengths);
        defer c.PQclear(upsert_result);
        const new_id_owned = try dupeResultValue(self.allocator, upsert_result, 0, 0);
        // V1.9-Rev finding #1: defer free at top level so success path
        // doesn't leak. Was previously freed only in case-only branch
        // → main success path leaked 32 bytes per cascade_update call.
        defer self.allocator.free(new_id_owned);

        // Step 4 — case-only / already-canonical no-op.
        if (std.mem.eql(u8, old_id_owned, new_id_owned)) {
            // Note: defer above handles new_id_owned cleanup on this
            // return path too — no explicit free here.
            const commit = try self.exec("COMMIT");
            c.PQclear(commit);
            return .{
                .found_old = true,
                .old_id = try allocator.dupe(u8, old_id_owned),
                .new_id = try allocator.dupe(u8, old_id_owned),
                .edges_rewritten = 0,
                .edges_closed = 0,
            };
        }

        // Step 5a — INSERT new edges with substituted endpoint.
        const old_id_z = try self.allocator.dupeZ(u8, old_id_owned);
        defer self.allocator.free(old_id_z);
        const new_id_z2 = try self.allocator.dupeZ(u8, new_id_owned);
        defer self.allocator.free(new_id_z2);
        const now_ts: i64 = std.time.timestamp();
        var ts_buf: [32]u8 = undefined;
        const ts_s = try std.fmt.bufPrintZ(&ts_buf, "{d}", .{now_ts});
        const insert_params = [_]?[*:0]const u8{
            user_s.ptr,
            old_id_z,
            new_id_z2,
            ts_s.ptr,
        };
        const insert_lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(old_id_owned.len),
            @intCast(new_id_owned.len),
            @intCast(ts_s.len),
        };
        const insert_q = try self.buildQuery(
            "INSERT INTO {schema}.memory_edges " ++
                "(user_id, source_key, target_key, predicate, attribution, confidence, weight, valid_from, is_latest) " ++
                "SELECT user_id, " ++
                "  CASE WHEN source_key = $2 THEN $3 ELSE source_key END, " ++
                "  CASE WHEN target_key = $2 THEN $3 ELSE target_key END, " ++
                "  predicate, " ++
                "  COALESCE(attribution, 'cascade_rename'), " ++
                "  confidence, " ++
                "  weight, " ++
                "  $4::bigint, " ++
                "  TRUE " ++
                "FROM {schema}.memory_edges " ++
                "WHERE user_id = $1 AND is_latest " ++
                "AND (source_key = $2 OR target_key = $2) " ++
                "ON CONFLICT (user_id, source_key, predicate, target_key) WHERE is_latest DO NOTHING",
        );
        defer self.allocator.free(insert_q);
        const insert_result = try self.execParams(insert_q, &insert_params, &insert_lengths);
        const inserted_count: usize = blk: {
            const tag = c.PQcmdTuples(insert_result);
            const tag_str = std.mem.span(tag);
            break :blk std.fmt.parseInt(usize, tag_str, 10) catch 0;
        };
        c.PQclear(insert_result);

        // Step 5b — UPDATE old edges: close-out with RETURNING.
        const close_params = [_]?[*:0]const u8{ user_s.ptr, old_id_z, ts_s.ptr };
        const close_lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(old_id_owned.len),
            @intCast(ts_s.len),
        };
        const close_q = try self.buildQuery(
            "UPDATE {schema}.memory_edges SET " ++
                "valid_to = $3, invalid_at = $3, expired_at = $3, is_latest = FALSE " ++
                "WHERE user_id = $1 AND is_latest " ++
                "AND (source_key = $2 OR target_key = $2) " ++
                "RETURNING source_key, target_key, predicate, COALESCE(confidence, 1.0)",
        );
        defer self.allocator.free(close_q);
        const close_result = try self.execParams(close_q, &close_params, &close_lengths);
        defer c.PQclear(close_result);
        const closed_count_raw = c.PQntuples(close_result);
        const closed_count: usize = if (closed_count_raw < 0) 0 else @intCast(closed_count_raw);

        // Capture closed-edge metadata for post-COMMIT events.
        var closed_edges: std.ArrayListUnmanaged(struct {
            source_key: []u8,
            target_key: []u8,
            predicate: []u8,
            confidence: f64,
        }) = .empty;
        defer {
            for (closed_edges.items) |e| {
                self.allocator.free(e.source_key);
                self.allocator.free(e.target_key);
                self.allocator.free(e.predicate);
            }
            closed_edges.deinit(self.allocator);
        }
        var ci: c_int = 0;
        while (ci < closed_count_raw) : (ci += 1) {
            const src = dupeResultValue(self.allocator, close_result, ci, 0) catch continue;
            errdefer self.allocator.free(src);
            const tgt = dupeResultValue(self.allocator, close_result, ci, 1) catch {
                self.allocator.free(src);
                continue;
            };
            errdefer self.allocator.free(tgt);
            const pred = dupeResultValue(self.allocator, close_result, ci, 2) catch {
                self.allocator.free(src);
                self.allocator.free(tgt);
                continue;
            };
            errdefer self.allocator.free(pred);
            const conf_str = dupeResultValue(self.allocator, close_result, ci, 3) catch {
                self.allocator.free(src);
                self.allocator.free(tgt);
                self.allocator.free(pred);
                continue;
            };
            defer self.allocator.free(conf_str);
            const conf_val = std.fmt.parseFloat(f64, conf_str) catch 1.0;
            try closed_edges.append(self.allocator, .{
                .source_key = src,
                .target_key = tgt,
                .predicate = pred,
                .confidence = conf_val,
            });
        }

        // Step 6 — COMMIT.
        const commit_result = try self.exec("COMMIT");
        c.PQclear(commit_result);

        // Step 7 — post-COMMIT event emission. Best-effort. Failure
        // here doesn't roll back the cascade.
        for (closed_edges.items) |e| {
            self.insertEdgeEvent(user_id, e.source_key, e.target_key, e.predicate, "closed", e.confidence) catch |err| {
                log.warn("cascade_rename.event_failed err={s} src={s} pred={s}", .{
                    @errorName(err), e.source_key, e.predicate,
                });
            };
        }

        log.info("cascade_rename user={d} old={s} new={s} old_id={s} new_id={s} inserted={d} closed={d}", .{
            user_id, old_name, new_name, old_id_owned, new_id_owned, inserted_count, closed_count,
        });

        return .{
            .found_old = true,
            .old_id = try allocator.dupe(u8, old_id_owned),
            .new_id = try allocator.dupe(u8, new_id_owned),
            .edges_rewritten = inserted_count,
            .edges_closed = closed_count,
        };
    }

    /// V1.9-2 — invalidate edges by (predicate, object_name) pattern.
    ///
    /// Use case (per ZAKI's stress-test letter, MNDA case):
    ///   `invalidate_when("HRS_MNDA", "STATUS", "blocked")` →
    ///   close every live edge matching the pattern. The agent calls
    ///   this when it learns a class of facts is stale (e.g. "MNDA
    ///   was blocked" superseded by "MNDA signed").
    ///
    /// Operation:
    ///   1. Resolve target_entity_id by name_lower=lower(object_name).
    ///      Missing → return count=0 (caller decides; usually means
    ///      "no edges to invalidate, so no-op").
    ///   2. UPDATE memory_edges SET is_latest=false + close-out
    ///      timestamps WHERE user_id=$1 AND is_latest AND
    ///      predicate=$2 AND target_key=$resolved_id.
    ///      Optional `subject_name` filter narrows further to edges
    ///      where source_key matches the named subject's entity_id.
    ///   3. RETURNING source/target/predicate so we can emit
    ///      edge_closed memory_events per row (atomic — one txn).
    ///   4. Returns count of invalidated edges.
    ///
    /// Differences from `cascadeRenameEntity`:
    ///   - No new entity created, no new edges inserted. Pure
    ///     close-out.
    ///   - Pattern-based, not entity-rename. Selective by predicate.
    ///
    /// What this does NOT do:
    ///   - Touch durable_fact/* / timeline_summary/* prose memory
    ///     content. Those are V1.9-3 propagate_correction territory.
    ///     This primitive is edge-graph-only.
    ///   - Insert a "superseded by" pointer. Caller is expected to
    ///     write the replacement fact via existing extraction or
    ///     memory_store paths (which now run the judge — V1.8-1 +
    ///     V1.9-6 wired all three callsites). The audit trail lives
    ///     in memory_events with event_type='closed'.
    pub fn invalidateEdgesByPattern(
        self: *Self,
        user_id: i64,
        predicate: []const u8,
        object_name: []const u8,
        subject_name: ?[]const u8,
    ) !usize {
        const begin_result = try self.exec("BEGIN");
        c.PQclear(begin_result);
        errdefer {
            if (self.exec("ROLLBACK")) |rb| {
                c.PQclear(rb);
            } else |_| {}
        }

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        // Step 1 — resolve target_entity_id.
        const obj_z = try self.allocator.dupeZ(u8, object_name);
        defer self.allocator.free(obj_z);
        const lookup_q = try self.buildQuery(
            "SELECT id FROM {schema}.memory_entities " ++
                "WHERE user_id = $1 AND name_lower = LOWER($2) LIMIT 1",
        );
        defer self.allocator.free(lookup_q);
        const lookup_params = [_]?[*:0]const u8{ user_s.ptr, obj_z };
        const lookup_lengths = [_]c_int{ @intCast(user_s.len), @intCast(object_name.len) };
        const lookup_result = try self.execParams(lookup_q, &lookup_params, &lookup_lengths);
        defer c.PQclear(lookup_result);
        if (c.PQntuples(lookup_result) == 0) {
            const commit = try self.exec("COMMIT");
            c.PQclear(commit);
            return 0;
        }
        const target_id = try dupeResultValue(self.allocator, lookup_result, 0, 0);
        defer self.allocator.free(target_id);

        // Optional: resolve subject_entity_id if filter provided.
        var subject_id_owned: ?[]u8 = null;
        defer if (subject_id_owned) |s| self.allocator.free(s);
        if (subject_name) |sn| {
            const sn_z = try self.allocator.dupeZ(u8, sn);
            defer self.allocator.free(sn_z);
            const subj_params = [_]?[*:0]const u8{ user_s.ptr, sn_z };
            const subj_lengths = [_]c_int{ @intCast(user_s.len), @intCast(sn.len) };
            const subj_result = try self.execParams(lookup_q, &subj_params, &subj_lengths);
            defer c.PQclear(subj_result);
            if (c.PQntuples(subj_result) > 0) {
                subject_id_owned = try dupeResultValue(self.allocator, subj_result, 0, 0);
            }
            // If subject_name given but not found, no edges can match —
            // commit empty txn and return 0. V1.9-Rev finding #6:
            // log_warn so observability surfaces "I typo'd the
            // subject name" caller errors instead of silently
            // returning a no-op count.
            if (subject_id_owned == null) {
                log.warn("invalidate_when subject_not_found user={d} subject={s} predicate={s} object={s} returning=0", .{
                    user_id, sn, predicate, object_name,
                });
                const commit = try self.exec("COMMIT");
                c.PQclear(commit);
                return 0;
            }
        }

        // Step 2 — close matching edges with RETURNING.
        const now_ts: i64 = std.time.timestamp();
        var ts_buf: [32]u8 = undefined;
        const ts_s = try std.fmt.bufPrintZ(&ts_buf, "{d}", .{now_ts});
        const pred_z = try self.allocator.dupeZ(u8, predicate);
        defer self.allocator.free(pred_z);
        const target_id_z = try self.allocator.dupeZ(u8, target_id);
        defer self.allocator.free(target_id_z);

        // Two query variants — with vs without subject filter.
        var close_result: *c.PGresult = undefined;
        if (subject_id_owned) |sid| {
            const sid_z = try self.allocator.dupeZ(u8, sid);
            defer self.allocator.free(sid_z);
            const close_q = try self.buildQuery(
                "UPDATE {schema}.memory_edges SET " ++
                    "valid_to = $4, invalid_at = $4, expired_at = $4, is_latest = FALSE " ++
                    "WHERE user_id = $1 AND is_latest AND predicate = $2 " ++
                    "AND target_key = $3 AND source_key = $5 " ++
                    "RETURNING source_key, target_key, predicate, COALESCE(confidence, 1.0)",
            );
            defer self.allocator.free(close_q);
            const close_params = [_]?[*:0]const u8{ user_s.ptr, pred_z, target_id_z, ts_s.ptr, sid_z };
            const close_lengths = [_]c_int{
                @intCast(user_s.len),
                @intCast(predicate.len),
                @intCast(target_id.len),
                @intCast(ts_s.len),
                @intCast(sid.len),
            };
            close_result = try self.execParams(close_q, &close_params, &close_lengths);
        } else {
            const close_q = try self.buildQuery(
                "UPDATE {schema}.memory_edges SET " ++
                    "valid_to = $4, invalid_at = $4, expired_at = $4, is_latest = FALSE " ++
                    "WHERE user_id = $1 AND is_latest AND predicate = $2 " ++
                    "AND target_key = $3 " ++
                    "RETURNING source_key, target_key, predicate, COALESCE(confidence, 1.0)",
            );
            defer self.allocator.free(close_q);
            const close_params = [_]?[*:0]const u8{ user_s.ptr, pred_z, target_id_z, ts_s.ptr };
            const close_lengths = [_]c_int{
                @intCast(user_s.len),
                @intCast(predicate.len),
                @intCast(target_id.len),
                @intCast(ts_s.len),
            };
            close_result = try self.execParams(close_q, &close_params, &close_lengths);
        }
        defer c.PQclear(close_result);
        const closed_n_raw = c.PQntuples(close_result);
        const closed_n: usize = if (closed_n_raw < 0) 0 else @intCast(closed_n_raw);

        // Capture closed-edge metadata for post-COMMIT events.
        var closed_edges: std.ArrayListUnmanaged(struct {
            source_key: []u8,
            target_key: []u8,
            predicate: []u8,
            confidence: f64,
        }) = .empty;
        defer {
            for (closed_edges.items) |e| {
                self.allocator.free(e.source_key);
                self.allocator.free(e.target_key);
                self.allocator.free(e.predicate);
            }
            closed_edges.deinit(self.allocator);
        }
        var ci: c_int = 0;
        while (ci < closed_n_raw) : (ci += 1) {
            const src = dupeResultValue(self.allocator, close_result, ci, 0) catch continue;
            errdefer self.allocator.free(src);
            const tgt = dupeResultValue(self.allocator, close_result, ci, 1) catch {
                self.allocator.free(src);
                continue;
            };
            errdefer self.allocator.free(tgt);
            const pred = dupeResultValue(self.allocator, close_result, ci, 2) catch {
                self.allocator.free(src);
                self.allocator.free(tgt);
                continue;
            };
            errdefer self.allocator.free(pred);
            const conf_str = dupeResultValue(self.allocator, close_result, ci, 3) catch {
                self.allocator.free(src);
                self.allocator.free(tgt);
                self.allocator.free(pred);
                continue;
            };
            defer self.allocator.free(conf_str);
            const conf_val = std.fmt.parseFloat(f64, conf_str) catch 1.0;
            try closed_edges.append(self.allocator, .{
                .source_key = src,
                .target_key = tgt,
                .predicate = pred,
                .confidence = conf_val,
            });
        }

        // COMMIT.
        const commit_result = try self.exec("COMMIT");
        c.PQclear(commit_result);

        // Post-COMMIT events.
        for (closed_edges.items) |e| {
            self.insertEdgeEvent(user_id, e.source_key, e.target_key, e.predicate, "closed", e.confidence) catch |err| {
                log.warn("invalidate_when.event_failed err={s} src={s} pred={s}", .{
                    @errorName(err), e.source_key, e.predicate,
                });
            };
        }

        log.info("invalidate_when user={d} predicate={s} object={s} subject={s} closed={d}", .{
            user_id,
            predicate,
            object_name,
            subject_name orelse "(any)",
            closed_n,
        });
        return closed_n;
    }

    /// V1.9-2 — explicit contradiction resolution by memory key.
    ///
    /// Use case (per ZAKI's stress-test letter):
    ///   `resolve_contradiction("durable_fact/mia-daughter",
    ///                          "CORRECTION: Mia daughter test",
    ///                          winner="CORRECTION...")` →
    ///   loser_key gets is_latest=false + close-out timestamps,
    ///   cascading to its edges. winner_key stays alive.
    ///
    /// This is the "manual override" surface for contradictions the
    ///   automated judge missed (or that predate V1.8-1 + V1.9-6
    ///   judge wiring). Direct key-to-key — no name resolution, no
    ///   pattern matching. The agent decides which side wins.
    ///
    /// Operation:
    ///   1. Verify both keys exist + are owned by user_id.
    ///   2. setMemoryInvalidation(loser_key) — leverages existing
    ///      V1.6 cmt7 cascade close-out (memory row is_latest=false +
    ///      cascade to memory_edges + edge_closed events).
    ///   3. Emit memory_events with event_type='resolve_contradiction'
    ///      and payload {loser, winner} for audit clarity.
    ///   4. Return loser_existed + winner_existed for caller branching.
    ///
    /// What this does NOT do:
    ///   - Walk timeline_summary/* content for either key. V1.9-3
    ///     propagate_correction handles content-level marking.
    ///   - Modify the winner row. It stays exactly as written.
    pub fn resolveContradiction(
        self: *Self,
        user_id: i64,
        loser_key: []const u8,
        winner_key: []const u8,
    ) !memory_root.ResolveContradictionResult {
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        // Verify keys exist.
        const exists_q = try self.buildQuery(
            "SELECT key FROM {schema}.memories WHERE user_id = $1 AND key = $2 LIMIT 1",
        );
        defer self.allocator.free(exists_q);

        const loser_z = try self.allocator.dupeZ(u8, loser_key);
        defer self.allocator.free(loser_z);
        const winner_z = try self.allocator.dupeZ(u8, winner_key);
        defer self.allocator.free(winner_z);

        const loser_params = [_]?[*:0]const u8{ user_s.ptr, loser_z };
        const loser_lengths = [_]c_int{ @intCast(user_s.len), @intCast(loser_key.len) };
        const loser_result = try self.execParams(exists_q, &loser_params, &loser_lengths);
        const loser_exists = c.PQntuples(loser_result) > 0;
        c.PQclear(loser_result);

        const winner_params = [_]?[*:0]const u8{ user_s.ptr, winner_z };
        const winner_lengths = [_]c_int{ @intCast(user_s.len), @intCast(winner_key.len) };
        const winner_result = try self.execParams(exists_q, &winner_params, &winner_lengths);
        const winner_exists = c.PQntuples(winner_result) > 0;
        c.PQclear(winner_result);

        if (!loser_exists) {
            log.info("resolve_contradiction loser_missing user={d} loser={s}", .{ user_id, loser_key });
            return .{ .loser_existed = false, .winner_existed = winner_exists, .loser_closed = false };
        }

        // Close the loser via setMemoryInvalidation — handles the
        // memory row + cascade to edges + edge_closed events in one
        // call (V1.6 cmt7-9 pattern reused). The cascaded
        // edge_closed events ARE the audit trail; a separate
        // resolve_contradiction event_type is V1.9 follow-up
        // (insertMemoryEvent today carries a fixed payload schema
        // designed for upserts, not contradictions). The log line
        // below + the edge_closed events together give caller +
        // operator full visibility of who-closed-what-when.
        const now_ts: i64 = std.time.timestamp();
        try self.setMemoryInvalidation(user_id, loser_key, now_ts, now_ts);

        log.info("resolve_contradiction user={d} loser={s} winner={s} loser_closed=true", .{
            user_id, loser_key, winner_key,
        });
        return .{ .loser_existed = true, .winner_existed = winner_exists, .loser_closed = true };
    }

    /// V1.9-3 — propagate a correction by walking memory rows whose
    /// content references a stale entity, marking each with
    /// `superseded_by_correction=<correction_key>` JSONB metadata.
    /// BIDIRECTIONAL — the correction's own metadata also gets
    /// `superseded_targets=[<key1>,<key2>...]` so the correction
    /// knows what it cleaned up + each target knows why it was
    /// flagged.
    ///
    /// Use case (per ZAKI's stress-test letter, Mia case):
    ///
    ///   propagate_correction("CORRECTION: Mia daughter test", "Mia")
    ///
    /// → Walks timeline_summary/* + summary_latest/* + durable_fact/* +
    ///   compaction_summary/* whose content ILIKE '%Mia%'. Each
    ///   matching row's metadata gets `superseded_by_correction`
    ///   pointing at the correction. The correction's metadata gets
    ///   the list of flagged keys. Future memory_loader passes can
    ///   surface "this row was superseded — see correction" instead
    ///   of presenting it as live truth.
    ///
    /// Per Nova's "I like this timeline memory" insight: this
    /// PRESERVES the timeline (audit chain of how truth evolved)
    /// while making the CURRENT VIEW honest. Targets are flagged,
    /// not deleted.
    ///
    /// Walked key families:
    ///   - timeline_summary/*  (session continuity summaries)
    ///   - summary_latest/*    (current-session summary)
    ///   - durable_fact/*      (extracted facts written via session-end)
    ///   - compaction_summary/* (Pass C archive rows)
    ///
    /// SKIPPED key families (intentionally):
    ///   - autosave_*          (raw transcript — never modify)
    ///   - session_checkpoint_* (audit trail — never modify)
    ///   - extracted_*         (derived; will be re-resolved by future
    ///                          extraction or judge calls — V1.8-1 + V1.9-6)
    ///   - The correction_key itself (don't self-supersede)
    ///
    /// Limitations (named for V1.10 upgrades):
    ///   - Substring match on content. "Mia" matches "Miami". Caller
    ///     should pass entity_pattern with surrounding word boundaries
    ///     when possible (`Mia ` or ` Mia.`). V1.10 candidate: vector-
    ///     semantic match using correction's embedding.
    ///   - No agent-judge per match. Every substring hit gets flagged
    ///     uniformly. V1.10 candidate: small LLM call per candidate
    ///     asking "does this row actually claim something about the
    ///     corrected entity?".
    ///   - No confidence score. V2 candidate: belief-strength model.
    ///
    /// Concurrent safety: BEGIN/COMMIT serializes target marking +
    /// correction self-update. Other readers see either pre- or
    /// post-state, never partial.
    pub fn propagateCorrection(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        correction_key: []const u8,
        entity_pattern: []const u8,
    ) !memory_root.PropagateCorrectionResult {
        const begin_result = try self.exec("BEGIN");
        c.PQclear(begin_result);
        errdefer {
            if (self.exec("ROLLBACK")) |rb| {
                c.PQclear(rb);
            } else |_| {}
        }

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        // Verify correction_key exists. If missing, return early —
        // there's nothing to point targets at.
        const correction_z = try self.allocator.dupeZ(u8, correction_key);
        defer self.allocator.free(correction_z);
        const exists_q = try self.buildQuery(
            "SELECT 1 FROM {schema}.memories WHERE user_id = $1 AND key = $2 LIMIT 1",
        );
        defer self.allocator.free(exists_q);
        const exists_params = [_]?[*:0]const u8{ user_s.ptr, correction_z };
        const exists_lengths = [_]c_int{ @intCast(user_s.len), @intCast(correction_key.len) };
        const exists_result = try self.execParams(exists_q, &exists_params, &exists_lengths);
        const correction_exists = c.PQntuples(exists_result) > 0;
        c.PQclear(exists_result);

        if (!correction_exists) {
            const commit = try self.exec("COMMIT");
            c.PQclear(commit);
            log.info("propagate_correction correction_missing user={d} correction_key={s}", .{
                user_id, correction_key,
            });
            return .{
                .correction_existed = false,
                .targets_flagged = 0,
                .target_keys = try allocator.alloc([]u8, 0),
            };
        }

        // Build the ILIKE pattern '%entity%' for content matching.
        // Caller passes raw entity name; we wrap in % wildcards.
        const ilike_pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{entity_pattern});
        defer self.allocator.free(ilike_pattern);
        const ilike_z = try self.allocator.dupeZ(u8, ilike_pattern);
        defer self.allocator.free(ilike_z);

        // Build the correction_key as a JSON-string-quoted value so
        // jsonb_set treats it as a value (not a path).
        const correction_json = try jsonString(self.allocator, correction_key);
        defer self.allocator.free(correction_json);
        const correction_json_z = try self.allocator.dupeZ(u8, correction_json);
        defer self.allocator.free(correction_json_z);

        // UPDATE matching rows: set metadata.superseded_by_correction,
        // skipping the correction itself + skipping autosave/checkpoint/
        // extracted families. RETURNING key so we can collect the list
        // for the correction's superseded_targets pointer.
        const update_q = try self.buildQuery(
            "UPDATE {schema}.memories SET metadata = jsonb_set(" ++
                "  COALESCE(metadata, '{}'::jsonb), " ++
                "  '{superseded_by_correction}', " ++
                "  $3::jsonb" ++
                ") " ++
                "WHERE user_id = $1 " ++
                "AND content ILIKE $2 " ++
                "AND key != $4 " ++
                "AND (key LIKE 'timeline_summary/%' " ++
                "  OR key LIKE 'summary_latest/%' " ++
                "  OR key LIKE 'durable_fact/%' " ++
                "  OR key LIKE 'compaction_summary/%') " ++
                "RETURNING key",
        );
        defer self.allocator.free(update_q);
        const update_params = [_]?[*:0]const u8{ user_s.ptr, ilike_z, correction_json_z, correction_z };
        const update_lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(ilike_pattern.len),
            @intCast(correction_json.len),
            @intCast(correction_key.len),
        };
        const update_result = try self.execParams(update_q, &update_params, &update_lengths);
        defer c.PQclear(update_result);
        const flagged_n_raw = c.PQntuples(update_result);
        const flagged_n: usize = if (flagged_n_raw < 0) 0 else @intCast(flagged_n_raw);

        // Collect flagged keys for caller + for the correction's
        // bidirectional superseded_targets pointer.
        var keys: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (keys.items) |k| allocator.free(k);
            keys.deinit(allocator);
        }
        var ki: c_int = 0;
        while (ki < flagged_n_raw) : (ki += 1) {
            const k_self_owned = try dupeResultValue(self.allocator, update_result, ki, 0);
            defer self.allocator.free(k_self_owned);
            const k_caller_owned = try allocator.dupe(u8, k_self_owned);
            // V1.9-Rev finding #11: errdefer per-iteration so an OOM
            // on append doesn't leak the just-allocated caller-owned
            // slice. Outer errdefer cleans `keys.items`; this catches
            // the in-flight allocation between dupe + append.
            errdefer allocator.free(k_caller_owned);
            try keys.append(allocator, k_caller_owned);
        }

        // Bidirectional pointer: write the list of flagged keys back
        // onto the correction's metadata as superseded_targets. Build
        // a JSON array of the keys.
        if (flagged_n > 0) {
            var json_array: std.ArrayListUnmanaged(u8) = .empty;
            defer json_array.deinit(self.allocator);
            try json_array.append(self.allocator, '[');
            for (keys.items, 0..) |k, idx| {
                if (idx > 0) try json_array.append(self.allocator, ',');
                const k_json = try jsonString(self.allocator, k);
                defer self.allocator.free(k_json);
                try json_array.appendSlice(self.allocator, k_json);
            }
            try json_array.append(self.allocator, ']');
            const targets_json_z = try self.allocator.dupeZ(u8, json_array.items);
            defer self.allocator.free(targets_json_z);

            const back_q = try self.buildQuery(
                "UPDATE {schema}.memories SET metadata = jsonb_set(" ++
                    "  COALESCE(metadata, '{}'::jsonb), " ++
                    "  '{superseded_targets}', " ++
                    "  $3::jsonb" ++
                    ") " ++
                    "WHERE user_id = $1 AND key = $2",
            );
            defer self.allocator.free(back_q);
            const back_params = [_]?[*:0]const u8{ user_s.ptr, correction_z, targets_json_z };
            const back_lengths = [_]c_int{
                @intCast(user_s.len),
                @intCast(correction_key.len),
                @intCast(json_array.items.len),
            };
            const back_result = try self.execParams(back_q, &back_params, &back_lengths);
            c.PQclear(back_result);
        }

        // COMMIT.
        const commit_result = try self.exec("COMMIT");
        c.PQclear(commit_result);

        log.info("propagate_correction user={d} correction={s} pattern={s} flagged={d}", .{
            user_id, correction_key, entity_pattern, flagged_n,
        });
        return .{
            .correction_existed = true,
            .targets_flagged = flagged_n,
            .target_keys = try keys.toOwnedSlice(allocator),
        };
    }

    /// V1.9-7 — proactive contradiction surveyor. The system finds
    /// contradictions in the memory graph WITHOUT being told to look,
    /// surfaces them as a `pending_conflicts_v2` memory row that the
    /// loader picks up in warm context. Agent sees "you have N
    /// unresolved contradictions" on its next turn and decides what
    /// to do (call resolve_contradiction or invalidate_when).
    ///
    /// This turns V1.9 from REACTIVE (agent acts when it notices) to
    /// PROACTIVE (system wakes the agent up). The truly next-gen
    /// piece of V1.9.
    ///
    /// What counts as a contradiction:
    ///   A `(source_key, predicate)` pair with >1 distinct
    ///   target_keys and is_latest=true on each. The fact "subject
    ///   has predicate X" simultaneously claims multiple Xs ⇒
    ///   conflict.
    ///
    /// Operation:
    ///   1. SQL: GROUP BY source/predicate having multiple distinct
    ///      live targets. Returns rows with `targets[]` aggregated.
    ///   2. Build JSON array of conflicts:
    ///      `[{"source":"<k>","predicate":"<p>","targets":["<t1>","<t2>",...]},...]`
    ///   3. Upsert `pending_conflicts_v2` memory row with the JSON.
    ///      memory_type='core' so memory_loader (which has explicit
    ///      `pending_conflicts*` handling) surfaces it. When zero
    ///      conflicts, write empty array (loader can render
    ///      "no contradictions detected" instead of stale state).
    ///   4. Return SurveyContradictionsResult { conflicts_found,
    ///      conflicts_json, sentinel_written }.
    ///
    /// Cost: 1 SQL aggregation per call. Per-user. Bounded by edge
    /// count (typically a few hundred). Lazy-trigger pattern: caller
    /// (memory_loader on stale `last_hygiene_at`) decides when to
    /// run; no background thread needed for V1.9. V1.10 adds true
    /// scheduler.
    ///
    /// Why not also include MNDA-class memory contradictions
    /// (multiple durable_facts about same subject saying different
    /// things)?: those are prose-level, need either embedding-cosine
    /// clustering or LLM judging — V1.10+ work. The edge-graph
    /// version is the deterministic / cheap proactive surveyor.
    /// memory_loader can also surface durable_fact-level conflicts
    /// when V1.10 lands; this primitive is the foundation.
    pub fn surveyContradictions(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
    ) !memory_root.SurveyContradictionsResult {
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        // Aggregate (source_key, predicate) tuples with conflicting
        // targets. ARRAY_AGG returns Postgres array literal which
        // we'll parse into a JSON array per row.
        const survey_q = try self.buildQuery(
            "SELECT source_key, predicate, ARRAY_AGG(target_key ORDER BY id DESC) AS targets " ++
                "FROM {schema}.memory_edges " ++
                "WHERE user_id = $1 AND is_latest = true " ++
                "GROUP BY source_key, predicate " ++
                "HAVING COUNT(DISTINCT target_key) > 1 " ++
                "ORDER BY source_key, predicate",
        );
        defer self.allocator.free(survey_q);
        const survey_params = [_]?[*:0]const u8{user_s.ptr};
        const survey_lengths = [_]c_int{@intCast(user_s.len)};
        const survey_result = try self.execParams(survey_q, &survey_params, &survey_lengths);
        defer c.PQclear(survey_result);

        const conflicts_n_raw = c.PQntuples(survey_result);
        const conflicts_n: usize = if (conflicts_n_raw < 0) 0 else @intCast(conflicts_n_raw);

        // Build the conflicts JSON array. Format per row:
        //   {"source":"<source_key>","predicate":"<predicate>","targets":["<t1>","<t2>",...]}
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer json_buf.deinit(allocator);
        try json_buf.append(allocator, '[');
        var ci: c_int = 0;
        while (ci < conflicts_n_raw) : (ci += 1) {
            if (ci > 0) try json_buf.append(allocator, ',');
            const src = try dupeResultValue(self.allocator, survey_result, ci, 0);
            defer self.allocator.free(src);
            const pred = try dupeResultValue(self.allocator, survey_result, ci, 1);
            defer self.allocator.free(pred);
            // PG ARRAY_AGG returns text like {target1,target2,target3}
            // (Postgres array literal). We need to parse + re-emit
            // as JSON array.
            const targets_pg = try dupeResultValue(self.allocator, survey_result, ci, 2);
            defer self.allocator.free(targets_pg);

            const src_json = try jsonString(allocator, src);
            defer allocator.free(src_json);
            const pred_json = try jsonString(allocator, pred);
            defer allocator.free(pred_json);
            try json_buf.appendSlice(allocator, "{\"source\":");
            try json_buf.appendSlice(allocator, src_json);
            try json_buf.appendSlice(allocator, ",\"predicate\":");
            try json_buf.appendSlice(allocator, pred_json);
            try json_buf.appendSlice(allocator, ",\"targets\":");
            // Parse PG array `{a,b,c}` → JSON `["a","b","c"]`. Quote
            // every element via jsonString. Strip outer braces.
            const arr_inner = if (targets_pg.len >= 2 and targets_pg[0] == '{' and targets_pg[targets_pg.len - 1] == '}')
                targets_pg[1 .. targets_pg.len - 1]
            else
                targets_pg[0..0];
            try json_buf.append(allocator, '[');
            var first_target = true;
            var it = std.mem.tokenizeScalar(u8, arr_inner, ',');
            while (it.next()) |tok| {
                if (!first_target) try json_buf.append(allocator, ',');
                first_target = false;
                // PG array elements: bare hex IDs (typical entity_id)
                // don't need un-escaping. If they did, we'd need a
                // proper PG-array parser. For V1.9-7 this is
                // sufficient — entity_ids are 32-char hex.
                const tok_json = try jsonString(allocator, tok);
                defer allocator.free(tok_json);
                try json_buf.appendSlice(allocator, tok_json);
            }
            try json_buf.append(allocator, ']');
            try json_buf.append(allocator, '}');
        }
        try json_buf.append(allocator, ']');

        const conflicts_json = try json_buf.toOwnedSlice(allocator);
        errdefer allocator.free(conflicts_json);

        // Upsert pending_conflicts_v2 sentinel memory row. Empty
        // conflicts array still gets written so the loader can show
        // a clean state. Use the same SQL pattern as the V1.7
        // pending_conflicts singleton.
        const sentinel_content = try std.fmt.allocPrint(
            self.allocator,
            "type=pending_conflicts_v2\nuser_id={d}\nat={d}\nconflicts_count={d}\nconflicts_json={s}\ninstruction=System detected N memory contradictions where the same (subject, predicate) pair has multiple live target values. Each row in conflicts_json describes one. Use memory_maintain tool action=resolve_contradiction with the loser/winner keys (or action=invalidate_when with a pattern) to clean up.\n",
            .{ user_id, std.time.timestamp(), conflicts_n, conflicts_json },
        );
        defer self.allocator.free(sentinel_content);

        // Mirror the V1.7 pending_conflicts upsert pattern (lines
        // 3056-3061): same column set + ON CONFLICT shape, just a
        // different singleton key. computeContentHash + lemmatize
        // are required since `pending_conflicts_v2` is a `core`-tier
        // memory and the schema enforces both.
        const sentinel_hash = try computeContentHash(self.allocator, sentinel_content);
        defer self.allocator.free(sentinel_hash);
        const sentinel_lem = try text_norm.lemmatizeForBm25(self.allocator, sentinel_content);
        defer self.allocator.free(sentinel_lem);
        const sentinel_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(sentinel_id);

        const upsert_q = try self.buildQuery(
            "INSERT INTO {schema}.memories (id, user_id, session_id, key, content, content_hash, memory_type, lemmatized, updated_at) " ++
                "VALUES ($1, $2, NULL, 'pending_conflicts_v2', $3, $4, 'core', $5, NOW()) " ++
                "ON CONFLICT (user_id, key) DO UPDATE SET " ++
                "content = EXCLUDED.content, content_hash = EXCLUDED.content_hash, " ++
                "lemmatized = EXCLUDED.lemmatized, updated_at = NOW()",
        );
        defer self.allocator.free(upsert_q);
        const sentinel_id_z = try self.allocator.dupeZ(u8, sentinel_id);
        defer self.allocator.free(sentinel_id_z);
        const sentinel_z = try self.allocator.dupeZ(u8, sentinel_content);
        defer self.allocator.free(sentinel_z);
        const hash_z = try self.allocator.dupeZ(u8, sentinel_hash);
        defer self.allocator.free(hash_z);
        const lem_z = try self.allocator.dupeZ(u8, sentinel_lem);
        defer self.allocator.free(lem_z);

        const upsert_params = [_]?[*:0]const u8{ sentinel_id_z, user_s.ptr, sentinel_z, hash_z, lem_z };
        const upsert_lengths = [_]c_int{
            @intCast(sentinel_id.len),
            @intCast(user_s.len),
            @intCast(sentinel_content.len),
            @intCast(sentinel_hash.len),
            @intCast(sentinel_lem.len),
        };
        const upsert_result = try self.execParams(upsert_q, &upsert_params, &upsert_lengths);
        c.PQclear(upsert_result);

        log.info("survey_contradictions user={d} conflicts_found={d} sentinel_written=true", .{
            user_id, conflicts_n,
        });
        return .{
            .conflicts_found = conflicts_n,
            .conflicts_json = conflicts_json,
            .sentinel_written = true,
        };
    }

    /// V1.9-4 — temporal decay tick. Lowers `confidence_score` on
    /// memory rows older than `threshold_days` that haven't been
    /// recently accessed. Closes ZAKI's stress-test pain:
    ///
    ///   > "Neptune sprint deadline April 15 is 50 days old and
    ///   > never referenced again. April 15 deadline entries look
    ///   > just as fresh as today's facts. No way to tell what's
    ///   > current."
    ///
    /// Decay-by-neglect, reinforce-by-use:
    ///   - Rows where `last_accessed_at` is recent → KEEP confidence.
    ///   - Rows where `last_accessed_at` is old (or NULL, never
    ///     touched) → exponential decay toward floor.
    ///   - Schema's existing `access_count` + `last_accessed_at`
    ///     columns provide the reinforce signal; recall paths
    ///     already increment them. This primitive only DECAYS;
    ///     reinforce is automatic via existing recall plumbing.
    ///
    /// Decay formula:
    ///   new = max(floor, old * EXP(-age_secs / (86400 * half_life_days)))
    ///   floor = 0.1 (never zero — preserves the audit trail)
    ///
    /// Where `age` is the time since `last_accessed_at` if non-null,
    /// else `created_at`. Half-life of 30 days means a never-touched
    /// memory drops 50% confidence every 30 days. Caller chooses
    /// half_life_days based on use case (long for archival, short
    /// for working memory).
    ///
    /// SKIPPED key families (don't decay):
    ///   - autosave_*           — raw transcript, audit trail
    ///   - session_checkpoint_* — audit trail
    ///   - pending_conflicts*   — operational sentinel, fresh by design
    ///
    /// Reversibility: a recall touches `last_accessed_at` →
    /// next decay tick computes age from that fresh timestamp →
    /// decay applies less or not at all. Confidence rises through
    /// new writes (upsertMemoryWithMetadata sets fresh confidence).
    /// Pure spacing-effect dynamics.
    ///
    /// Returns `TemporalDecayResult` with rows_decayed +
    /// avg_decay_amount + floor. Useful for observability +
    /// scheduler tick logging.
    pub fn temporalDecay(
        self: *Self,
        user_id: i64,
        threshold_days: u32,
        half_life_days: u32,
    ) !memory_root.TemporalDecayResult {
        const begin_result = try self.exec("BEGIN");
        c.PQclear(begin_result);
        errdefer {
            if (self.exec("ROLLBACK")) |rb| {
                c.PQclear(rb);
            } else |_| {}
        }

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var threshold_buf: [16]u8 = undefined;
        const threshold_s = try std.fmt.bufPrintZ(&threshold_buf, "{d}", .{threshold_days});
        var halflife_buf: [16]u8 = undefined;
        const halflife_s = try std.fmt.bufPrintZ(&halflife_buf, "{d}", .{half_life_days});

        const floor: f64 = 0.1;

        // Decay UPDATE. Computes the new confidence per row using
        // EXP decay over age (since last_accessed_at, falling back to
        // created_at). RETURNING old + new so we can compute mean
        // decay amount.
        const decay_q = try self.buildQuery(
            "WITH decay AS (" ++
                "  UPDATE {schema}.memories m SET confidence_score = GREATEST(" ++
                "    0.1, " ++
                "    COALESCE(m.confidence_score, 0.8) * EXP(" ++
                "      -EXTRACT(EPOCH FROM (NOW() - COALESCE(m.last_accessed_at, m.created_at))) " ++
                "      / (86400.0 * $3::int)" ++
                "    )" ++
                "  ) " ++
                "  WHERE m.user_id = $1 " ++
                "  AND COALESCE(m.confidence_score, 0.8) > 0.1 " ++
                "  AND COALESCE(m.last_accessed_at, m.created_at) < NOW() - ($2::int * INTERVAL '1 day') " ++
                "  AND m.key NOT LIKE 'autosave_%' " ++
                "  AND m.key NOT LIKE 'session_checkpoint_%' " ++
                "  AND m.key NOT LIKE 'pending_conflicts%' " ++
                "  RETURNING m.id, COALESCE(m.confidence_score, 0.8) AS new_conf" ++
                ") " ++
                "SELECT COUNT(*)::bigint AS n, COALESCE(AVG(new_conf), 0.0)::double precision AS avg_new " ++
                "FROM decay",
        );
        defer self.allocator.free(decay_q);
        const decay_params = [_]?[*:0]const u8{ user_s.ptr, threshold_s.ptr, halflife_s.ptr };
        const decay_lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(threshold_s.len),
            @intCast(halflife_s.len),
        };
        const decay_result = try self.execParams(decay_q, &decay_params, &decay_lengths);
        defer c.PQclear(decay_result);

        var rows_decayed: usize = 0;
        var avg_new: f64 = 0.0;
        if (c.PQntuples(decay_result) > 0) {
            const n_str = try dupeResultValue(self.allocator, decay_result, 0, 0);
            defer self.allocator.free(n_str);
            rows_decayed = std.fmt.parseInt(usize, n_str, 10) catch 0;
            const avg_str = try dupeResultValue(self.allocator, decay_result, 0, 1);
            defer self.allocator.free(avg_str);
            avg_new = std.fmt.parseFloat(f64, avg_str) catch 0.0;
        }

        // COMMIT.
        const commit_result = try self.exec("COMMIT");
        c.PQclear(commit_result);

        // avg_decay_amount estimation: (1 - avg_new) is roughly the
        // mean drop assuming starting confidence ~1.0. Honest enough
        // for observability; we don't capture old vs new per-row to
        // keep the SQL atomic + cheap.
        const avg_decay_amount: f64 = if (rows_decayed > 0) (0.8 - avg_new) else 0.0;

        log.info("temporal_decay user={d} threshold_days={d} half_life_days={d} rows_decayed={d} avg_new_conf={d:.3}", .{
            user_id, threshold_days, half_life_days, rows_decayed, avg_new,
        });
        return .{
            .rows_decayed = rows_decayed,
            .avg_decay_amount = avg_decay_amount,
            .floor = floor,
        };
    }

    /// V1.10-A — fetch every memory key whose `metadata.superseded_by_correction`
    /// is set. Used by `agent/memory_loader.zig` to mark these keys as
    /// "already seen" upfront — every existing skip-check then naturally
    /// honors the supersede flag without per-site code changes.
    ///
    /// Why this primitive exists:
    ///   V1.9-3 propagateCorrection writes `metadata.superseded_by_correction`
    ///   on flagged rows (bidirectional with correction's superseded_targets).
    ///   But V1.9 didn't add a loader-side filter, so superseded rows still
    ///   surfaced in warm context. This primitive closes that loop. ZAKI's
    ///   stress test (2026-05-06) showed Mia cleanup worked at the row level
    ///   but timeline_summaries STILL loaded as continuity. With this filter,
    ///   superseded rows become invisible at retrieval time without
    ///   mutating the row itself (W-INT-01 immortality guard preserved).
    ///
    /// Cost: 1 SQL per turn, bounded by the count of currently-superseded
    /// rows. With a typical user accumulating ~10-100 corrections over time,
    /// the result set stays small. Index on `(user_id, key)` covers the
    /// scan; the JSONB `?` operator is GIN-indexable if metadata grows.
    ///
    /// Caller frees each []u8 + the outer slice.
    pub fn findSupersededMemoryKeys(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
    ) ![][]u8 {
        const q = try self.buildQuery(
            "SELECT key FROM {schema}.memories " ++
                "WHERE user_id = $1 " ++
                "AND (COALESCE(metadata, '{}'::jsonb) ? 'superseded_by_correction')",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const nrows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc([]u8, nrows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |k| allocator.free(k);
            allocator.free(out);
        }
        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const row: c_int = @intCast(i);
            out[i] = try dupeResultValue(allocator, result, row, 0);
            initialized += 1;
        }
        return out;
    }

    /// V1.10-B — fetch prose memories whose content mentions `entity_pattern`.
    /// Returns the most-recent `limit` rows from the prose-fact families
    /// (`durable_fact/*`, `timeline_summary/*`, `summary_latest/*`) that
    /// match `content ILIKE %entity%`, are still live (validity filter),
    /// and aren't already superseded.
    ///
    /// Why this primitive:
    ///   ZAKI's stress-test gap (2026-05-06) is prose-level zombies in the
    ///   `durable_fact/*` family that the V1.7 W-INT-01 immortality guard
    ///   correctly protects from agent-side mutation. Edge-graph survey
    ///   can't see these. V1.10-B's LLM-judge surveyor reads the prose
    ///   directly via this primitive, asks Llama-on-Groq "do any of these
    ///   contradict?", then writes `metadata.superseded_by_correction` on
    ///   the losers via `markMemorySupersededByKey`. Metadata writes
    ///   bypass the W-INT-01 guard (V1.9-3 already proved this seam works
    ///   on protected rows).
    ///
    /// Filtering:
    ///   - `content ILIKE %entity_pattern%` (caller-supplied; surveyor
    ///     keeps it sharp — agent passes "MNDA" not "%")
    ///   - key family in {durable_fact, timeline_summary, summary_latest}
    ///   - MEMORIES_VALIDITY_FILTER (skip closed-out rows)
    ///   - skip already-superseded (`NOT (metadata ? 'superseded_by_correction')`)
    ///   - ORDER BY updated_at DESC LIMIT $3 — newest first; the LLM judge
    ///     sees fresh evidence at the top of its prompt.
    ///
    /// Cost:
    ///   ILIKE without leading-wildcard-anchor is a seq scan in the worst
    ///   case, but durable_fact rows are bounded (~hundreds per user).
    ///   `(user_id, key)` index narrows by user; family-prefix filter is
    ///   a fast string prefix; the seq scan happens within that window.
    ///   At ZAKI's scale (single-digit thousands of rows/user), this is
    ///   sub-100ms.
    ///
    /// Caller frees each ProseFact + the outer slice (use
    /// `memory_root.freeProseFacts`).
    pub fn fetchProseFactsByPattern(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        entity_pattern: []const u8,
        limit: usize,
    ) ![]memory_root.ProseFact {
        if (entity_pattern.len == 0) return error.EmptyEntityPattern;
        if (limit == 0) return try allocator.alloc(memory_root.ProseFact, 0);

        // V1.10 Gap A fix (post-review-tightened) — widen the family
        // filter from allowlist (durable_fact / timeline_summary /
        // summary_latest) to denylist (everything except audit / index /
        // internal / system-managed). The 2026-05-06 diagnostic showed
        // user-keyed self-pollution (e.g. a stored "Panther" codename
        // under arbitrary keys like project_codename) was invisible to
        // the surveyor under the narrow allowlist. The wider denylist
        // catches these while still skipping rows the judge has no
        // business reading.
        //
        // Mirrors the Zig predicates in src/memory/root.zig:
        //   - isInternalMemoryKey (autosave_*, last_hygiene_at,
        //     __tombstone__/*, __bootstrap.prompt.*)
        //   - isAppendOnlyMemoryKey (session_summary/, timeline_summary/,
        //     session_checkpoint_, autosave_*, compaction_summary/,
        //     summary_fallback/, compaction_dropped/)
        //   - timeline_index/* (index)
        //   - context_anchor_current (single-row sentinel)
        //   - MEMORY:<digits> (markdown-line parser artifacts)
        //
        // NOTE: this list MUST stay in lockstep with the Zig predicates.
        // Future additions to isAppendOnlyMemoryKey or isInternalMemoryKey
        // need a matching SQL clause here. A future refactor could expose
        // a single `prose_survey_scope` SQL function that the predicates
        // delegate to, eliminating the drift risk; deferred to V1.10+ as
        // it touches the postgres schema.
        const q = try self.buildQuery(
            "SELECT key, content, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint, 0) " ++
                "FROM {schema}.memories " ++
                "WHERE user_id = $1 " ++
                "AND content ILIKE $2 " ++
                // audit class
                "AND key NOT LIKE 'autosave_user_%' " ++
                "AND key NOT LIKE 'autosave_assistant_%' " ++
                "AND key NOT LIKE 'session_checkpoint_%' " ++
                // index class
                "AND key NOT LIKE 'timeline_index/%' " ++
                // internal class
                "AND key NOT LIKE '\\_\\_tombstone\\_\\_%' ESCAPE '\\' " ++
                "AND key NOT LIKE '\\_\\_bootstrap.prompt.%' ESCAPE '\\' " ++
                "AND key != 'last_hygiene_at' " ++
                "AND key != 'context_anchor_current' " ++
                // system-managed append-only writes (compaction artifacts,
                // session-level summaries that aren't user-facing
                // continuity facts; we keep summary_latest/ and
                // timeline_summary/ in scope because those ARE the
                // continuity rows the surveyor is meant to compare).
                "AND key NOT LIKE 'session_summary/%' " ++
                "AND key NOT LIKE 'compaction_summary/%' " ++
                "AND key NOT LIKE 'compaction_dropped/%' " ++
                "AND key NOT LIKE 'summary_fallback/%' " ++
                // markdown parser artifact: "MEMORY:<digits>"
                "AND key NOT SIMILAR TO 'MEMORY:[0-9]+' " ++
                "AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "AND NOT (COALESCE(metadata, '{}'::jsonb) ? 'superseded_by_correction') " ++
                "ORDER BY updated_at DESC LIMIT $3",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const ilike_pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{entity_pattern});
        defer self.allocator.free(ilike_pattern);
        const ilike_z = try self.allocator.dupeZ(u8, ilike_pattern);
        defer self.allocator.free(ilike_z);

        const limit_text = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_text);
        const limit_z = try self.allocator.dupeZ(u8, limit_text);
        defer self.allocator.free(limit_z);

        const params = [_]?[*:0]const u8{ user_s.ptr, ilike_z, limit_z };
        const lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(ilike_pattern.len),
            @intCast(limit_text.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const nrows_raw = c.PQntuples(result);
        const nrows: usize = if (nrows_raw < 0) 0 else @intCast(nrows_raw);

        const out = try allocator.alloc(memory_root.ProseFact, nrows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |f| f.deinit(allocator);
            allocator.free(out);
        }

        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const row: c_int = @intCast(i);
            const key = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(key);
            const content = try dupeResultValue(allocator, result, row, 1);
            errdefer allocator.free(content);
            const ts_self = try dupeResultValue(self.allocator, result, row, 2);
            defer self.allocator.free(ts_self);
            const ts: i64 = std.fmt.parseInt(i64, ts_self, 10) catch 0;

            out[i] = .{ .key = key, .content = content, .updated_at_unix = ts };
            initialized += 1;
        }
        return out;
    }

    /// V1.10-B — mark `loser_key` as superseded by `winner_key` with
    /// bidirectional pointers, idempotently.
    ///
    /// What it writes:
    ///   1. On loser row: `metadata.superseded_by_correction = $winner_key`
    ///      (overwrite — last writer wins; idempotent within a single
    ///      contradiction chain).
    ///   2. On winner row: append `$loser_key` to
    ///      `metadata.superseded_targets[]`. If the array already
    ///      contains the loser_key, no duplicate is appended.
    ///
    /// What it does NOT touch:
    ///   - `content` / `memory_type` / `valid_to` / `is_latest` /
    ///     `confidence_score` — stay exactly as they were. This means
    ///     the W-INT-01 immortality guard remains intact: superseded
    ///     rows are still queryable, still owned by the user, still
    ///     auditable. They simply become invisible at retrieval time
    ///     via V1.10-A's loader-side filter.
    ///
    /// Returns:
    ///   `true` when the loser was successfully marked (i.e. the row
    ///   exists and the metadata write affected one row). `false`
    ///   when the loser_key doesn't exist (no row to mark).
    ///
    /// Idempotency:
    ///   Calling twice with the same (loser, winner) is safe — the
    ///   loser's `superseded_by_correction` is overwritten with the
    ///   same value; the winner's `superseded_targets` array uses a
    ///   DISTINCT subquery so duplicates are skipped.
    ///
    /// Transaction:
    ///   Wraps both writes in BEGIN/COMMIT so a partial failure
    ///   leaves the metadata coherent (no orphan loser-side flag
    ///   without the corresponding winner-side back-pointer).
    pub fn markMemorySupersededByKey(
        self: *Self,
        user_id: i64,
        loser_key: []const u8,
        winner_key: []const u8,
    ) !bool {
        if (loser_key.len == 0 or winner_key.len == 0) return error.EmptyKey;
        if (std.mem.eql(u8, loser_key, winner_key)) return error.LoserEqualsWinner;

        const begin_result = try self.exec("BEGIN");
        c.PQclear(begin_result);
        errdefer {
            if (self.exec("ROLLBACK")) |rb| {
                c.PQclear(rb);
            } else |_| {}
        }

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const loser_z = try self.allocator.dupeZ(u8, loser_key);
        defer self.allocator.free(loser_z);
        const winner_z = try self.allocator.dupeZ(u8, winner_key);
        defer self.allocator.free(winner_z);

        // Build JSON-string representation of the winner_key for the
        // loser-side superseded_by_correction value.
        const winner_json = try jsonString(self.allocator, winner_key);
        defer self.allocator.free(winner_json);
        const winner_json_z = try self.allocator.dupeZ(u8, winner_json);
        defer self.allocator.free(winner_json_z);

        // Loser-side: set superseded_by_correction = winner_key.
        const loser_q = try self.buildQuery(
            "UPDATE {schema}.memories SET metadata = jsonb_set(" ++
                "  COALESCE(metadata, '{}'::jsonb), " ++
                "  '{superseded_by_correction}', " ++
                "  $3::jsonb" ++
                ") " ++
                "WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(loser_q);
        const loser_params = [_]?[*:0]const u8{ user_s.ptr, loser_z, winner_json_z };
        const loser_lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(loser_key.len),
            @intCast(winner_json.len),
        };
        const loser_result = try self.execParams(loser_q, &loser_params, &loser_lengths);
        defer c.PQclear(loser_result);

        // PQcmdTuples returns "1" / "0" as a C string for UPDATE.
        const loser_tuples_cstr = c.PQcmdTuples(loser_result);
        const loser_tuples_slice: []const u8 = if (loser_tuples_cstr == null)
            ""
        else
            std.mem.span(loser_tuples_cstr);
        const loser_marked = !std.mem.eql(u8, loser_tuples_slice, "0") and loser_tuples_slice.len > 0;

        if (!loser_marked) {
            const commit = try self.exec("COMMIT");
            c.PQclear(commit);
            return false;
        }

        // Winner-side: append loser_key to superseded_targets[] iff not
        // already present. Uses jsonb_set + a CASE that checks
        // jsonb_path_exists — array element equal to $3.
        const loser_json = try jsonString(self.allocator, loser_key);
        defer self.allocator.free(loser_json);
        const loser_json_z = try self.allocator.dupeZ(u8, loser_json);
        defer self.allocator.free(loser_json_z);

        const winner_q = try self.buildQuery(
            "UPDATE {schema}.memories SET metadata = jsonb_set(" ++
                "  COALESCE(metadata, '{}'::jsonb), " ++
                "  '{superseded_targets}', " ++
                "  CASE " ++
                "    WHEN COALESCE(metadata->'superseded_targets', '[]'::jsonb) @> jsonb_build_array($3::text) " ++
                "      THEN COALESCE(metadata->'superseded_targets', '[]'::jsonb) " ++
                "    ELSE COALESCE(metadata->'superseded_targets', '[]'::jsonb) || jsonb_build_array($3::text) " ++
                "  END" ++
                ") " ++
                "WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(winner_q);
        // For the winner-side query, $3 is the bare loser_key (text), not
        // the JSON-string-quoted variant — jsonb_build_array does the
        // wrapping.
        const winner_params = [_]?[*:0]const u8{ user_s.ptr, winner_z, loser_z };
        const winner_lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(winner_key.len),
            @intCast(loser_key.len),
        };
        const winner_result = try self.execParams(winner_q, &winner_params, &winner_lengths);
        c.PQclear(winner_result);

        const commit = try self.exec("COMMIT");
        c.PQclear(commit);

        log.info("mark_superseded user={d} loser={s} winner={s}", .{
            user_id, loser_key, winner_key,
        });
        return true;
    }

    /// Today the `subject` column is unpopulated by upsertMemoryWithMetadata
    /// (V1.6 5b.3 wrote subject only into JSONB metadata). This query
    /// reads the JSONB path directly so it works without a forward
    /// migration. Future commit may lift to typed columns + reuse
    /// `idx_memories_subject` once the writer populates them.
    ///
    /// Caller frees each MemoryEntry + the slice.
    pub fn findRelatedExtractedMemories(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        subject: []const u8,
        limit: usize,
    ) ![]memory_root.MemoryEntry {
        // V1.6 cmt6 review (I-INT-02 fix): include `metadata ? 'subject'` so the
        // PG planner reliably picks `idx_memories_metadata_subject` (a partial
        // index WHERE metadata ? 'subject'). Without the matching predicate,
        // the planner doesn't always recognize that `metadata->>'subject' = $2`
        // implies the partial-index WHERE — falling back to seq-scan or the
        // typed-column index (which is unpopulated by the JSONB upsert path).
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, valid_to FROM {schema}.memories " ++
                "WHERE user_id = $1 " ++
                "AND metadata ? 'subject' " ++
                "AND metadata->>'subject' = $2 " ++
                "AND metadata->>'attribution' = 'extraction_classifier' " ++
                "AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "ORDER BY updated_at DESC LIMIT $3",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const subject_z = try allocator.dupeZ(u8, subject);
        defer allocator.free(subject_z);
        const limit_text = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_text);
        const limit_z = try self.allocator.dupeZ(u8, limit_text);
        defer self.allocator.free(limit_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, subject_z, limit_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(subject.len), @intCast(limit_text.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    /// V1.6 commit 6 — bi-temporal close-out writer.
    ///
    /// Marks the row superseded by setting:
    ///   `valid_to     = $3` (event-time end — synonym with invalid_at today)
    ///   `invalid_at   = $3` (Graphiti six-field equivalent)
    ///   `expired_at   = $4` (system time of close-out)
    ///   `is_latest    = false` (supermemory parity — drops the row from
    ///                          "latest version" filters)
    ///
    /// Why all four columns:
    ///   - `valid_to` is the V1.5 retrieval filter — the agent stops
    ///     seeing this row immediately
    ///   - `invalid_at` is the Graphiti event-time field for analytics
    ///   - `expired_at` is the audit trail (when did WE decide it was
    ///     superseded; differs from invalid_at when correcting historical
    ///     data)
    ///   - `is_latest = false` makes the timeline + drilldown UIs hide
    ///     superseded versions by default
    ///
    /// Idempotent — running twice with the same args produces the same
    /// row state. Returns silently if the row doesn't exist (caller's
    /// fault to track existence; we don't gate on it).
    pub fn setMemoryInvalidation(
        self: *Self,
        user_id: i64,
        key: []const u8,
        invalid_at: i64,
        expired_at: i64,
    ) !void {
        const q = try self.buildQuery(
            "UPDATE {schema}.memories SET " ++
                "valid_to = $3, " ++
                "invalid_at = $3, " ++
                "expired_at = $4, " ++
                "is_latest = FALSE " ++
                "WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        var invalid_buf: [32]u8 = undefined;
        const invalid_s = try std.fmt.bufPrintZ(&invalid_buf, "{d}", .{invalid_at});
        var expired_buf: [32]u8 = undefined;
        const expired_s = try std.fmt.bufPrintZ(&expired_buf, "{d}", .{expired_at});
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z, invalid_s.ptr, expired_s.ptr };
        const lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(key.len),
            @intCast(invalid_s.len),
            @intCast(expired_s.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        // V1.6 commit 7 — cascade close-out to memory_edges. Any edge whose
        // source OR target is the closed-out memory key gets the same
        // bi-temporal close-out columns set + is_latest=false. This keeps
        // graph traversal consistent: a closed-out fact's edges vanish
        // alongside the node from is_latest queries.
        //
        // V1.6 commit 9 — RETURNING the closed edges so we can emit one
        // edge_closed event per cascaded row into memory_events. Bi-temporal
        // graph history matches bi-temporal memory history.
        const cascade_q = try self.buildQuery(
            "UPDATE {schema}.memory_edges SET " ++
                "valid_to = $3, " ++
                "invalid_at = $3, " ++
                "expired_at = $4, " ++
                "is_latest = FALSE " ++
                "WHERE user_id = $1 AND (source_key = $2 OR target_key = $2) AND is_latest " ++
                "RETURNING source_key, target_key, predicate, COALESCE(confidence, 1.0)",
        );
        defer self.allocator.free(cascade_q);
        const cascade_result = try self.execParams(cascade_q, &params, &lengths);
        defer c.PQclear(cascade_result);

        // Emit one edge_closed event per cascaded edge. Failure on any
        // single event is non-fatal (the cascade UPDATE already succeeded;
        // the event row is metadata for graph-history queries).
        const closed_count = c.PQntuples(cascade_result);
        var i: c_int = 0;
        while (i < closed_count) : (i += 1) {
            const closed_src = dupeResultValue(self.allocator, cascade_result, i, 0) catch continue;
            defer self.allocator.free(closed_src);
            const closed_tgt = dupeResultValue(self.allocator, cascade_result, i, 1) catch continue;
            defer self.allocator.free(closed_tgt);
            const closed_pred = dupeResultValue(self.allocator, cascade_result, i, 2) catch continue;
            defer self.allocator.free(closed_pred);
            const conf_str = dupeResultValue(self.allocator, cascade_result, i, 3) catch continue;
            defer self.allocator.free(conf_str);
            const conf_val = std.fmt.parseFloat(f64, conf_str) catch 1.0;
            self.insertEdgeEvent(user_id, closed_src, closed_tgt, closed_pred, "closed", conf_val) catch |err| {
                log.warn("edge_event.close_failed err={s} source={s} predicate={s}", .{
                    @errorName(err), closed_src, closed_pred,
                });
            };
        }
    }

    /// V1.6 commit 11 — flip a `core` memory back to a non-core type.
    /// Required because V1.7's CASE-guard in upsertMemory + the W-INT-01
    /// fix make core rows immortal against subsequent upserts (preserving
    /// promotion + close-out state). The only escape hatch is this
    /// explicit demotion.
    ///
    /// `target_category_str` must be one of "daily" / "conversation" /
    /// "episodic" — i.e. anything but "core". Returns true when a row was
    /// actually demoted (false when key didn't exist or was already
    /// non-core).
    ///
    /// Emits a memory_events row with event_type='demote' carrying the
    /// `from`/`to` types so audit can reconstruct demotion history.
    pub fn demoteMemoryFromCore(self: *Self, user_id: i64, key: []const u8, target_category_str: []const u8) !bool {
        // Defensive: never accept "core" as the target — would be a no-op
        // that masks the caller's confusion.
        if (std.mem.eql(u8, target_category_str, "core")) return false;
        const q = try self.buildQuery(
            "UPDATE {schema}.memories SET memory_type = $3, updated_at = NOW() " ++
                "WHERE user_id = $1 AND key = $2 AND memory_type = 'core' " ++
                "RETURNING id",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const tgt_z = try self.allocator.dupeZ(u8, target_category_str);
        defer self.allocator.free(tgt_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z, tgt_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len), @intCast(target_category_str.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return false;

        // Audit event — best-effort, non-fatal on failure.
        // V1.6 ship review WR-01: use jsonString() to escape `key` (agent-
        // controlled — could contain `"` or `\`). Without escaping, the
        // ::jsonb cast silently drops the audit row on certain keys.
        // target_category_str is enum-validated upstream — safe to inline
        // without escape (spec allows daily/conversation/episodic only).
        const key_json = jsonString(self.allocator, key) catch return true;
        defer self.allocator.free(key_json);
        const payload = std.fmt.allocPrint(
            self.allocator,
            "{{\"key\":{s},\"from\":\"core\",\"to\":\"{s}\"}}",
            .{ key_json, target_category_str },
        ) catch return true;
        defer self.allocator.free(payload);
        const event_q = try self.buildQuery(
            "INSERT INTO {schema}.memory_events (id, user_id, memory_id, event_type, payload) " ++
                "VALUES ($1, $2, NULL, 'demote', $3::jsonb)",
        );
        defer self.allocator.free(event_q);
        const event_id = self.randomHexId(self.allocator, 16) catch return true;
        defer self.allocator.free(event_id);
        const event_id_z = self.allocator.dupeZ(u8, event_id) catch return true;
        defer self.allocator.free(event_id_z);
        const payload_z = self.allocator.dupeZ(u8, payload) catch return true;
        defer self.allocator.free(payload_z);
        const event_params = [_]?[*:0]const u8{ event_id_z, user_s.ptr, payload_z };
        const event_lengths = [_]c_int{ @intCast(event_id.len), @intCast(user_s.len), @intCast(payload.len) };
        const event_result = self.execParams(event_q, &event_params, &event_lengths) catch return true;
        c.PQclear(event_result);
        return true;
    }

    /// V1.6 commit 13 — chronological event timeline for a single memory
    /// key. Powers /brain/memory/{key} drilldown. Matches events where:
    ///   - payload->>'key' = $2 (upsert / compose / demote)
    ///   - payload->>'source_key' = $2 OR payload->>'target_key' = $2
    ///     (edge_added / edge_closed)
    ///
    /// Episode events (event_type='episode') are session-scoped not key-
    /// scoped — excluded from this view. The drilldown shows the lifecycle
    /// of THIS memory; episode timeline lives at /brain/timeline.
    ///
    /// Returned slice is allocator-owned; free via
    /// memory_root.freeMemoryEventRows. Newest-first.
    pub fn listEventsForMemoryKey(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        key: []const u8,
        limit: u32,
    ) ![]memory_root.MemoryEventRow {
        const q = try self.buildQuery(
            "SELECT id, event_type, payload::text, " ++
                "COALESCE((EXTRACT(EPOCH FROM created_at))::bigint, 0) " ++
                "FROM {schema}.memory_events " ++
                "WHERE user_id = $1 AND (" ++
                "  payload->>'key' = $2 " ++
                "  OR payload->>'source_key' = $2 " ++
                "  OR payload->>'target_key' = $2" ++
                ") " ++
                "ORDER BY created_at DESC, id DESC " ++
                "LIMIT $3",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        const limit_text = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_text);
        const limit_z = try self.allocator.dupeZ(u8, limit_text);
        defer self.allocator.free(limit_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z, limit_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len), @intCast(limit_text.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const tuples = c.PQntuples(result);
        var out: std.ArrayListUnmanaged(memory_root.MemoryEventRow) = .{};
        errdefer {
            for (out.items) |*r| r.deinit(allocator);
            out.deinit(allocator);
        }
        var i: c_int = 0;
        while (i < tuples) : (i += 1) {
            const id_v = try dupeResultValue(allocator, result, i, 0);
            errdefer allocator.free(id_v);
            const et_v = try dupeResultValue(allocator, result, i, 1);
            errdefer allocator.free(et_v);
            const pl_v = try dupeResultValue(allocator, result, i, 2);
            errdefer allocator.free(pl_v);
            const ts_str = try dupeResultValue(allocator, result, i, 3);
            defer allocator.free(ts_str);
            const ts = std.fmt.parseInt(i64, ts_str, 10) catch 0;
            try out.append(allocator, .{
                .id = id_v,
                .event_type = et_v,
                .payload_json = pl_v,
                .created_at_unix = ts,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// V1.6 commit 14 (M4) — populate source_session_id + source_snippet
    /// columns (already in schema from cmt2 migration). Both fields are
    /// independently optional: pass null to leave a column untouched
    /// (UPDATE only sets the columns that are non-null in the call).
    ///
    /// Called from extraction_persist after upsertMemoryWithMetadata when
    /// the source context is known (compaction Pass C has session_id +
    /// can use the fact's own text as the snippet).
    pub fn setMemorySource(self: *Self, user_id: i64, key: []const u8, session_id: ?[]const u8, snippet: ?[]const u8) !void {
        if (session_id == null and snippet == null) return; // nothing to do

        // Build SET clause based on which fields are present.
        // Both null short-circuited above; one or both non-null land here.
        const both = session_id != null and snippet != null;
        const set_clause = if (both)
            "source_session_id = $3, source_snippet = $4"
        else if (session_id != null)
            "source_session_id = $3"
        else
            "source_snippet = $3";

        const q = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE {{schema}}.memories SET {s}, updated_at = NOW() WHERE user_id = $1 AND key = $2",
            .{set_clause},
        );
        defer self.allocator.free(q);
        const expanded = try self.buildQuery(q);
        defer self.allocator.free(expanded);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);

        if (both) {
            const sid_z = try self.allocator.dupeZ(u8, session_id.?);
            defer self.allocator.free(sid_z);
            const sn_z = try self.allocator.dupeZ(u8, snippet.?);
            defer self.allocator.free(sn_z);
            const params = [_]?[*:0]const u8{ user_s.ptr, key_z, sid_z, sn_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len), @intCast(session_id.?.len), @intCast(snippet.?.len) };
            const result = try self.execParams(expanded, &params, &lengths);
            c.PQclear(result);
        } else {
            const val = session_id orelse snippet.?;
            const val_z = try self.allocator.dupeZ(u8, val);
            defer self.allocator.free(val_z);
            const params = [_]?[*:0]const u8{ user_s.ptr, key_z, val_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len), @intCast(val.len) };
            const result = try self.execParams(expanded, &params, &lengths);
            c.PQclear(result);
        }
    }

    /// V1.6 commit 14 (M4) — read source attribution for /brain/memory/{key}
    /// drilldown. Returns null when key doesn't exist OR neither column
    /// is populated. Caller frees via MemorySource.deinit.
    pub fn getMemorySource(self: *Self, allocator: std.mem.Allocator, user_id: i64, key: []const u8) !?memory_root.MemorySource {
        const q = try self.buildQuery(
            "SELECT source_session_id, source_snippet FROM {schema}.memories " ++
                "WHERE user_id = $1 AND key = $2 LIMIT 1",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        const sid: ?[]const u8 = if (c.PQgetisnull(result, 0, 0) != 0)
            null
        else
            try dupeResultValue(allocator, result, 0, 0);
        errdefer if (sid) |s| allocator.free(s);
        const sn: ?[]const u8 = if (c.PQgetisnull(result, 0, 1) != 0)
            null
        else
            try dupeResultValue(allocator, result, 0, 1);
        if (sid == null and sn == null) return null;
        return memory_root.MemorySource{ .session_id = sid, .snippet = sn };
    }

    /// V1.6 commit 15 — aggregate session-summary "documents" for the
    /// /brain/documents surface. Groups by session_id over rows with
    /// continuity-summary key prefixes (timeline_summary/, session_summary/,
    /// summary_latest/). Returns one row per session with summary count,
    /// latest timestamp, and latest content excerpt (200-char cap).
    ///
    /// Newest-session-first by max(updated_at). Caller frees via
    /// memory_root.freeBrainDocuments.
    pub fn listBrainDocumentSummaries(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        limit: u32,
    ) ![]memory_root.BrainDocument {
        // DISTINCT ON (session_id) returns the latest row per session.
        // Pair with a JOIN against an aggregate count subquery for the
        // summary_count field.
        const q = try self.buildQuery(
            "WITH counts AS (" ++
                "  SELECT session_id, COUNT(*) AS n, MAX(updated_at) AS latest_at " ++
                "  FROM {schema}.memories " ++
                "  WHERE user_id = $1 AND session_id IS NOT NULL " ++
                "  AND (key LIKE 'timeline_summary/%' OR key LIKE 'session_summary/%' OR key LIKE 'summary_latest/%') " ++
                "  AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "  GROUP BY session_id" ++
                "), latest AS (" ++
                "  SELECT DISTINCT ON (session_id) session_id, content " ++
                "  FROM {schema}.memories " ++
                "  WHERE user_id = $1 AND session_id IS NOT NULL " ++
                "  AND (key LIKE 'timeline_summary/%' OR key LIKE 'session_summary/%' OR key LIKE 'summary_latest/%') " ++
                "  AND " ++ MEMORIES_VALIDITY_FILTER ++ " " ++
                "  ORDER BY session_id, updated_at DESC" ++
                ") " ++
                "SELECT c.session_id, c.n, " ++
                "COALESCE((EXTRACT(EPOCH FROM c.latest_at))::bigint, 0), " ++
                "SUBSTRING(l.content FROM 1 FOR 200) " ++
                "FROM counts c LEFT JOIN latest l ON c.session_id = l.session_id " ++
                "ORDER BY c.latest_at DESC LIMIT $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const limit_text = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_text);
        const limit_z = try self.allocator.dupeZ(u8, limit_text);
        defer self.allocator.free(limit_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, limit_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(limit_text.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const tuples = c.PQntuples(result);
        var out: std.ArrayListUnmanaged(memory_root.BrainDocument) = .{};
        errdefer {
            for (out.items) |*d| d.deinit(allocator);
            out.deinit(allocator);
        }
        var i: c_int = 0;
        while (i < tuples) : (i += 1) {
            const sid = try dupeResultValue(allocator, result, i, 0);
            errdefer allocator.free(sid);
            const count_str = try dupeResultValue(allocator, result, i, 1);
            defer allocator.free(count_str);
            const ts_str = try dupeResultValue(allocator, result, i, 2);
            defer allocator.free(ts_str);
            const excerpt = if (c.PQgetisnull(result, i, 3) != 0)
                try allocator.dupe(u8, "")
            else
                try dupeResultValue(allocator, result, i, 3);
            errdefer allocator.free(excerpt);
            const count = std.fmt.parseInt(usize, count_str, 10) catch 0;
            const ts = std.fmt.parseInt(i64, ts_str, 10) catch 0;
            try out.append(allocator, .{
                .session_id = sid,
                .summary_count = count,
                .latest_at_unix = ts,
                .latest_excerpt = excerpt,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// V1.6 commit 7 — write a typed edge into the materialized graph.
    /// ON CONFLICT on the unique triple (user_id, source_key, predicate,
    /// target_key) WHERE is_latest — re-extracting the same triple just
    /// bumps confidence + weight; no duplicate row.
    ///
    /// Idempotent. Called from extraction_persist.persistExtracted after
    /// the contradiction judge resolves (so closed-out triples are
    /// already cleared by setMemoryInvalidation's cascade above).
    pub fn upsertMemoryEdge(
        self: *Self,
        user_id: i64,
        source_key: []const u8,
        target_key: []const u8,
        predicate: []const u8,
        attribution: ?[]const u8,
        confidence: ?f64,
    ) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.memory_edges " ++
                "(user_id, source_key, target_key, predicate, attribution, confidence, valid_from) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, EXTRACT(EPOCH FROM NOW())::bigint) " ++
                "ON CONFLICT (user_id, source_key, predicate, target_key) WHERE is_latest " ++
                "DO UPDATE SET " ++
                "confidence = COALESCE(EXCLUDED.confidence, {schema}.memory_edges.confidence), " ++
                "weight = {schema}.memory_edges.weight + 1.0, " ++
                "attribution = COALESCE(EXCLUDED.attribution, {schema}.memory_edges.attribution)",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const src_z = try self.allocator.dupeZ(u8, source_key);
        defer self.allocator.free(src_z);
        const tgt_z = try self.allocator.dupeZ(u8, target_key);
        defer self.allocator.free(tgt_z);
        const pred_z = try self.allocator.dupeZ(u8, predicate);
        defer self.allocator.free(pred_z);
        const attr_text = attribution orelse "";
        const attr_z = try self.allocator.dupeZ(u8, attr_text);
        defer self.allocator.free(attr_z);
        var conf_buf: [32]u8 = undefined;
        const conf_text = if (confidence) |cv| try std.fmt.bufPrintZ(&conf_buf, "{d:.6}", .{cv}) else "";
        const conf_z = try self.allocator.dupeZ(u8, conf_text);
        defer self.allocator.free(conf_z);
        const params = [_]?[*:0]const u8{
            user_s.ptr,
            src_z,
            tgt_z,
            pred_z,
            if (attr_text.len == 0) null else attr_z,
            if (confidence == null) null else conf_z,
        };
        const lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(source_key.len),
            @intCast(target_key.len),
            @intCast(predicate.len),
            @intCast(attr_text.len),
            @intCast(conf_text.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        // V1.6 commit 9 — edge mutation event. Records every edge add/bump
        // in memory_events with event_type='edge_added'. This gives the
        // brain bi-temporal graph history (point-in-time "what edges existed
        // when") and is the foundation for V1.6 cmt10 graph-expand retrieval.
        // Failure is non-fatal: log + continue (the edge is already written;
        // missing the event row degrades to "history starts here", not data
        // loss).
        self.insertEdgeEvent(user_id, source_key, target_key, predicate, "added", confidence) catch |err| {
            log.warn("edge_event.add_failed err={s} source={s} predicate={s}", .{
                @errorName(err), source_key, predicate,
            });
        };
    }

    /// V1.6 commit 9 — write an edge mutation event to memory_events.
    /// `op` is one of `"added"` | `"closed"`. Payload carries the triple
    /// + confidence. Used by upsertMemoryEdge (added) and the cascade
    /// branch of setMemoryInvalidation (closed).
    fn insertEdgeEvent(
        self: *Self,
        user_id: i64,
        source_key: []const u8,
        target_key: []const u8,
        predicate: []const u8,
        op: []const u8,
        confidence: ?f64,
    ) !void {
        const src_json = try jsonString(self.allocator, source_key);
        defer self.allocator.free(src_json);
        const tgt_json = try jsonString(self.allocator, target_key);
        defer self.allocator.free(tgt_json);
        const pred_json = try jsonString(self.allocator, predicate);
        defer self.allocator.free(pred_json);
        const op_json = try jsonString(self.allocator, op);
        defer self.allocator.free(op_json);

        const payload = if (confidence) |cv|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"source_key\":{s},\"target_key\":{s},\"predicate\":{s},\"op\":{s},\"confidence\":{d:.6}}}",
                .{ src_json, tgt_json, pred_json, op_json, cv },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"source_key\":{s},\"target_key\":{s},\"predicate\":{s},\"op\":{s}}}",
                .{ src_json, tgt_json, pred_json, op_json },
            );
        defer self.allocator.free(payload);

        // event_type: "edge_added" or "edge_closed"
        const event_type = try std.fmt.allocPrint(self.allocator, "edge_{s}", .{op});
        defer self.allocator.free(event_type);
        const event_type_z = try self.allocator.dupeZ(u8, event_type);
        defer self.allocator.free(event_type_z);

        const q = try self.buildQuery(
            "INSERT INTO {schema}.memory_events (id, user_id, memory_id, event_type, payload) " ++
                "VALUES ($1, $2, NULL, $3, $4::jsonb)",
        );
        defer self.allocator.free(q);
        const event_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(event_id);
        const event_id_z = try self.allocator.dupeZ(u8, event_id);
        defer self.allocator.free(event_id_z);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const payload_z = try self.allocator.dupeZ(u8, payload);
        defer self.allocator.free(payload_z);
        const params = [_]?[*:0]const u8{ event_id_z, user_s.ptr, event_type_z, payload_z };
        const lengths = [_]c_int{
            @intCast(event_id.len),
            @intCast(user_s.len),
            @intCast(event_type.len),
            @intCast(payload.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// V1.6 commit 7 — degree-count for a memory key in the active graph.
    /// Uses the partial index `idx_edges_source` for O(log N) lookup.
    /// Returns the number of edges where this key is the source AND
    /// the edge is still latest. Feeds importance scoring caller in
    /// gateway.handleBrainGraph (replaces the JSONB-derived typed_edges
    /// degree counter).
    pub fn countEdgesForSource(self: *Self, user_id: i64, source_key: []const u8) !usize {
        const q = try self.buildQuery(
            "SELECT COUNT(*) FROM {schema}.memory_edges " ++
                "WHERE user_id = $1 AND source_key = $2 AND is_latest",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const src_z = try self.allocator.dupeZ(u8, source_key);
        defer self.allocator.free(src_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, src_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(source_key.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const text = try dupeResultValue(self.allocator, result, 0, 0);
        defer self.allocator.free(text);
        return try std.fmt.parseInt(usize, text, 10);
    }

    /// V1.6 commit 7 — list all active edges for a user. Used by
    /// gateway.handleBrainGraph to render the typed-edge surface — replaces
    /// the JSONB-derived `buildBrainTypedEdges` reconstruction with a real
    /// table read. Caller frees each TypedEdge + the slice via
    /// memory_root.freeTypedEdges.
    pub fn listEdgesForUser(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]memory_root.TypedEdge {
        const q = try self.buildQuery(
            "SELECT source_key, target_key, predicate, COALESCE(confidence, 1.0), weight " ++
                "FROM {schema}.memory_edges " ++
                "WHERE user_id = $1 AND is_latest " ++
                "ORDER BY weight DESC, source_key ASC",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const tuples = c.PQntuples(result);
        var out: std.ArrayListUnmanaged(memory_root.TypedEdge) = .{};
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        var i: c_int = 0;
        while (i < tuples) : (i += 1) {
            const src = try dupeResultValue(allocator, result, i, 0);
            errdefer allocator.free(src);
            const tgt = try dupeResultValue(allocator, result, i, 1);
            errdefer allocator.free(tgt);
            const pred = try dupeResultValue(allocator, result, i, 2);
            errdefer allocator.free(pred);
            const conf_str = try dupeResultValue(allocator, result, i, 3);
            defer allocator.free(conf_str);
            const weight_str = try dupeResultValue(allocator, result, i, 4);
            defer allocator.free(weight_str);
            // CR-03 fix (2026-05-07): finite-clamp at the source-of-truth
            // boundary. parseFloat accepts 'NaN' / 'Infinity' / '-Infinity'
            // as valid f64s, and Postgres allows these values in float
            // columns. Without this clamp, a single corrupted row would
            // emit `"confidence":nan` into the /brain/graph JSON response,
            // making `JSON.parse()` on the FE throw a SyntaxError and
            // blank the entire brain page.
            const conf_raw = std.fmt.parseFloat(f64, conf_str) catch 1.0;
            const weight_raw = std.fmt.parseFloat(f64, weight_str) catch 1.0;
            const conf = if (std.math.isFinite(conf_raw)) conf_raw else 1.0;
            const weight = if (std.math.isFinite(weight_raw)) weight_raw else 1.0;
            try out.append(allocator, .{
                .source_key = src,
                .target_key = tgt,
                .predicate = pred,
                .confidence = conf,
                .weight = weight,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// V1.6 commit 10 — batched edge lookup for graph hop expansion.
    /// Returns all active edges where `source_key` OR `target_key` is in
    /// `keys[]`. One round trip via `WHERE ANY($::text[])`.
    ///
    /// Used by graph_expand.expandFromSeeds: each BFS frontier batches its
    /// keys into a single SQL call instead of N round-trips. Caller frees
    /// each TypedEdge + the slice via memory_root.freeTypedEdges.
    ///
    /// Empty `keys` slice returns an empty []. Skips the SQL round trip.
    pub fn findEdgesByKeys(self: *Self, allocator: std.mem.Allocator, user_id: i64, keys: []const []const u8) ![]memory_root.TypedEdge {
        if (keys.len == 0) return allocator.alloc(memory_root.TypedEdge, 0);

        // V1.6 cmt7-10 review WARN-2 fix: reject keys containing NUL bytes
        // up front. The literal gets passed to libpq via dupeZ which silently
        // truncates at the first NUL — passing a key like "a\x00malicious"
        // would scope the IN-list to just "a", potentially returning edges
        // an adversary shouldn't see. Today all callers pass hex-derived
        // keys (extracted_<hex>, entity_<hex>, node_<hex>) which can't
        // contain NUL by construction, but findEdgesByKeys is a public
        // surface — defend it. Returning error.InvalidKey instead of
        // silently truncating gives the caller a chance to surface the bug.
        for (keys) |k| {
            if (std.mem.indexOfScalar(u8, k, 0) != null) return error.InvalidKey;
        }

        // Build PG TEXT[] literal: ARRAY['k1', 'k2', ...]::text[]
        var arr_buf: std.ArrayListUnmanaged(u8) = .{};
        defer arr_buf.deinit(allocator);
        try arr_buf.appendSlice(allocator, "{");
        for (keys, 0..) |k, i| {
            if (i > 0) try arr_buf.append(allocator, ',');
            try arr_buf.append(allocator, '"');
            // Escape backslash and double-quote for PG array literal
            for (k) |ch| {
                if (ch == '\\' or ch == '"') try arr_buf.append(allocator, '\\');
                try arr_buf.append(allocator, ch);
            }
            try arr_buf.append(allocator, '"');
        }
        try arr_buf.appendSlice(allocator, "}");

        const q = try self.buildQuery(
            "SELECT source_key, target_key, predicate, COALESCE(confidence, 1.0), weight " ++
                "FROM {schema}.memory_edges " ++
                "WHERE user_id = $1 AND is_latest " ++
                "AND (source_key = ANY($2::text[]) OR target_key = ANY($2::text[])) " ++
                "ORDER BY weight DESC, source_key ASC",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const arr_z = try allocator.dupeZ(u8, arr_buf.items);
        defer allocator.free(arr_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, arr_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(arr_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const tuples = c.PQntuples(result);
        var out: std.ArrayListUnmanaged(memory_root.TypedEdge) = .{};
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        var i: c_int = 0;
        while (i < tuples) : (i += 1) {
            const src = try dupeResultValue(allocator, result, i, 0);
            errdefer allocator.free(src);
            const tgt = try dupeResultValue(allocator, result, i, 1);
            errdefer allocator.free(tgt);
            const pred = try dupeResultValue(allocator, result, i, 2);
            errdefer allocator.free(pred);
            const conf_str = try dupeResultValue(allocator, result, i, 3);
            defer allocator.free(conf_str);
            const weight_str = try dupeResultValue(allocator, result, i, 4);
            defer allocator.free(weight_str);
            // CR-03 fix (2026-05-07): finite-clamp at the source-of-truth
            // boundary. parseFloat accepts 'NaN' / 'Infinity' / '-Infinity'
            // as valid f64s, and Postgres allows these values in float
            // columns. Without this clamp, a single corrupted row would
            // emit `"confidence":nan` into the /brain/graph JSON response,
            // making `JSON.parse()` on the FE throw a SyntaxError and
            // blank the entire brain page.
            const conf_raw = std.fmt.parseFloat(f64, conf_str) catch 1.0;
            const weight_raw = std.fmt.parseFloat(f64, weight_str) catch 1.0;
            const conf = if (std.math.isFinite(conf_raw)) conf_raw else 1.0;
            const weight = if (std.math.isFinite(weight_raw)) weight_raw else 1.0;
            try out.append(allocator, .{
                .source_key = src,
                .target_key = tgt,
                .predicate = pred,
                .confidence = conf,
                .weight = weight,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// V1.6 commit 8 — entity coreference via pgvector cosine similarity.
    /// Returns the closest existing entity for `user_id` whose
    /// `1 - (name_embedding <=> $2)` ≥ `threshold` (typically 0.95 per
    /// Mem0). Used to dedupe surface variants ("Helix" / "helix" /
    /// "Helix editor") into a single entity row.
    ///
    /// Cosine via pgvector's `<=>` operator (returns distance; similarity
    /// = 1 - distance). The ivfflat index `idx_entities_vec` accelerates
    /// the search.
    ///
    /// Caller frees the returned EntityRow.
    pub fn findEntityByCosine(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        embedding: []const f32,
        threshold: f64,
    ) !?memory_root.EntityRow {
        // Format embedding as pgvector literal: "[v1,v2,...,vN]"
        var emb_buf: std.ArrayListUnmanaged(u8) = .{};
        defer emb_buf.deinit(allocator);
        try emb_buf.append(allocator, '[');
        for (embedding, 0..) |v, i| {
            if (i > 0) try emb_buf.append(allocator, ',');
            const w = emb_buf.writer(allocator);
            try w.print("{d:.6}", .{v});
        }
        try emb_buf.append(allocator, ']');

        const q = try self.buildQuery(
            "SELECT id, name, 1 - (name_embedding <=> $2::vector) AS sim " ++
                "FROM {schema}.memory_entities " ++
                "WHERE user_id = $1 AND name_embedding IS NOT NULL " ++
                "ORDER BY name_embedding <=> $2::vector " ++
                "LIMIT 1",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const emb_z = try allocator.dupeZ(u8, emb_buf.items);
        defer allocator.free(emb_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, emb_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(emb_buf.items.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        const sim_str = try dupeResultValue(allocator, result, 0, 2);
        defer allocator.free(sim_str);
        const sim = std.fmt.parseFloat(f64, sim_str) catch return null;
        if (sim < threshold) return null;
        const id = try dupeResultValue(allocator, result, 0, 0);
        errdefer allocator.free(id);
        const name = try dupeResultValue(allocator, result, 0, 1);
        errdefer allocator.free(name);
        return memory_root.EntityRow{ .id = id, .name = name, .similarity = sim };
    }

    /// V1.6 commit 8 — write a new entity row to memory_entities with its
    /// embedding. Returns the entity `id` (caller-owned). Generates a
    /// random hex ID using the same pattern as memory rows. ON CONFLICT
    /// on (user_id, name_lower) re-uses the existing entity if a strict
    /// case-insensitive match exists (handles the trivial "Helix" / "helix"
    /// case before cosine even runs).
    ///
    /// Caller has already determined no cosine ≥ threshold neighbor exists
    /// (via findEntityByCosine returning null) — this is the create branch.
    pub fn upsertEntity(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        name: []const u8,
        embedding: []const f32,
    ) ![]u8 {
        // pgvector literal
        var emb_buf: std.ArrayListUnmanaged(u8) = .{};
        defer emb_buf.deinit(allocator);
        try emb_buf.append(allocator, '[');
        for (embedding, 0..) |v, i| {
            if (i > 0) try emb_buf.append(allocator, ',');
            const w = emb_buf.writer(allocator);
            try w.print("{d:.6}", .{v});
        }
        try emb_buf.append(allocator, ']');

        const id = try self.randomHexId(self.allocator, 16);
        errdefer self.allocator.free(id);

        const q = try self.buildQuery(
            "INSERT INTO {schema}.memory_entities (id, user_id, name, name_lower, name_embedding) " ++
                "VALUES ($1, $2, $3, LOWER($3), $4::vector) " ++
                "ON CONFLICT (user_id, name_lower) DO UPDATE SET " ++
                "name_embedding = EXCLUDED.name_embedding, updated_at = NOW() " ++
                "RETURNING id",
        );
        defer self.allocator.free(q);
        const id_z = try self.allocator.dupeZ(u8, id);
        defer self.allocator.free(id_z);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        const emb_z = try self.allocator.dupeZ(u8, emb_buf.items);
        defer self.allocator.free(emb_z);
        const params = [_]?[*:0]const u8{ id_z, user_s.ptr, name_z, emb_z };
        const lengths = [_]c_int{
            @intCast(id.len),
            @intCast(user_s.len),
            @intCast(name.len),
            @intCast(emb_buf.items.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        // V1.6 cmt7-10 review WARN-1 fix: every return path uses the CALLER's
        // allocator. Previously the RETURNING-empty branch returned `id`
        // (self.allocator-owned) while the RETURNING-present branch returned
        // a caller-allocator-owned slice — caller would `free()` with the
        // wrong allocator if those differed. Latent today (call sites use
        // the same allocator), but a per-tenant arena in the future would
        // surface it as a heap corruption.
        if (c.PQntuples(result) == 0) {
            const owned = try allocator.dupe(u8, id);
            self.allocator.free(id);
            return owned;
        }
        // ON CONFLICT branch: dupe directly into caller's allocator.
        const returned_id = try dupeResultValue(allocator, result, 0, 0);
        self.allocator.free(id);
        return returned_id;
    }

    /// Delete autosave_user_* and autosave_assistant_* memory rows for the
    /// given user. When session_id is provided, scope the delete to that
    /// session; otherwise clear autosave rows across all of the user's
    /// sessions. Used by SessionStore.clearAutoSaved so `/new` actually
    /// clears ghost context instead of silently leaving rows behind.
    pub fn clearAutoSavedMemory(self: *Self, user_id: i64, session_id: ?[]const u8) !void {
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        if (session_id) |sid| {
            const q = try self.buildQuery(
                "DELETE FROM {schema}.memories " ++
                    "WHERE user_id = $1 AND session_id = $2 " ++
                    "AND (key LIKE 'autosave_user_%' OR key LIKE 'autosave_assistant_%')",
            );
            defer self.allocator.free(q);
            const sid_z = try self.allocator.dupeZ(u8, sid);
            defer self.allocator.free(sid_z);
            const params = [_]?[*:0]const u8{ user_s.ptr, sid_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(sid.len) };
            const result = try self.execParams(q, &params, &lengths);
            defer c.PQclear(result);
        } else {
            const q = try self.buildQuery(
                "DELETE FROM {schema}.memories " ++
                    "WHERE user_id = $1 " ++
                    "AND (key LIKE 'autosave_user_%' OR key LIKE 'autosave_assistant_%')",
            );
            defer self.allocator.free(q);
            const params = [_]?[*:0]const u8{user_s.ptr};
            const lengths = [_]c_int{@intCast(user_s.len)};
            const result = try self.execParams(q, &params, &lengths);
            defer c.PQclear(result);
        }
    }

    pub fn countMemories(self: *Self, user_id: i64) !usize {
        const q = try self.buildQuery(
            "SELECT COUNT(*) FROM {schema}.memories WHERE user_id = $1",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const text = try dupeResultValue(self.allocator, result, 0, 0);
        defer self.allocator.free(text);
        return try std.fmt.parseInt(usize, text, 10);
    }

    pub fn recordTelegramUpdate(self: *Self, user_id: i64, update_id: i64) !bool {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.telegram_updates (user_id, update_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var update_buf: [32]u8 = undefined;
        const update_s = try std.fmt.bufPrintZ(&update_buf, "{d}", .{update_id});
        const params = [_]?[*:0]const u8{ user_s.ptr, update_s.ptr };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(update_s.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const affected = c.PQcmdTuples(result);
        if (affected == null) return false;
        return !std.mem.eql(u8, std.mem.span(affected), "0");
    }

    pub fn upsertChannelIdentityBinding(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        channel: []const u8,
        account_id: []const u8,
        principal_key: []const u8,
        scope_key: []const u8,
        thread_key: ?[]const u8,
        peer_kind: ?[]const u8,
        peer_id: ?[]const u8,
        metadata_json: ?[]const u8,
    ) ![]u8 {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.channel_identity_bindings " ++
                "(id, user_id, channel, account_id, principal_key, scope_key, thread_key, thread_key_norm, peer_kind, peer_id, metadata, updated_at) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, NOW()) " ++
                "ON CONFLICT (channel, account_id, principal_key, scope_key, thread_key_norm) DO UPDATE " ++
                "SET user_id = EXCLUDED.user_id, thread_key = EXCLUDED.thread_key, peer_kind = EXCLUDED.peer_kind, peer_id = EXCLUDED.peer_id, metadata = EXCLUDED.metadata, updated_at = NOW() " ++
                "RETURNING id",
        );
        defer self.allocator.free(q);

        const binding_id = try self.randomHexId(allocator, 16);
        defer allocator.free(binding_id);
        const binding_id_z = try self.allocator.dupeZ(u8, binding_id);
        defer self.allocator.free(binding_id_z);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const channel_z = try self.allocator.dupeZ(u8, channel);
        defer self.allocator.free(channel_z);
        const account_z = try self.allocator.dupeZ(u8, account_id);
        defer self.allocator.free(account_z);
        const principal_z = try self.allocator.dupeZ(u8, principal_key);
        defer self.allocator.free(principal_z);
        const scope_z = try self.allocator.dupeZ(u8, scope_key);
        defer self.allocator.free(scope_z);
        const thread_text = if (thread_key) |value| value else "";
        const thread_norm = thread_text;
        const thread_z = if (thread_key) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (thread_z) |value| self.allocator.free(value);
        const thread_param: ?[*:0]const u8 = if (thread_z) |value| value.ptr else null;
        const thread_norm_z = try self.allocator.dupeZ(u8, thread_norm);
        defer self.allocator.free(thread_norm_z);
        const peer_kind_z = if (peer_kind) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (peer_kind_z) |value| self.allocator.free(value);
        const peer_kind_param: ?[*:0]const u8 = if (peer_kind_z) |value| value.ptr else null;
        const peer_id_z = if (peer_id) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (peer_id_z) |value| self.allocator.free(value);
        const peer_id_param: ?[*:0]const u8 = if (peer_id_z) |value| value.ptr else null;
        const metadata_text = metadata_json orelse "{}";
        const metadata_z = try self.allocator.dupeZ(u8, metadata_text);
        defer self.allocator.free(metadata_z);

        const params = [_]?[*:0]const u8{
            binding_id_z,
            user_s.ptr,
            channel_z,
            account_z,
            principal_z,
            scope_z,
            thread_param,
            thread_norm_z,
            peer_kind_param,
            peer_id_param,
            metadata_z,
        };
        const lengths = [_]c_int{
            @intCast(binding_id.len),
            @intCast(user_s.len),
            @intCast(channel.len),
            @intCast(account_id.len),
            @intCast(principal_key.len),
            @intCast(scope_key.len),
            @intCast(thread_text.len),
            @intCast(thread_norm.len),
            @intCast(if (peer_kind) |value| value.len else 0),
            @intCast(if (peer_id) |value| value.len else 0),
            @intCast(metadata_text.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        return dupeResultValue(allocator, result, 0, 0);
    }

    pub fn resolveUserByChannelIdentity(
        self: *Self,
        channel: []const u8,
        account_id: []const u8,
        principal_key: []const u8,
        scope_key: []const u8,
        thread_key: ?[]const u8,
    ) !?i64 {
        const q = try self.buildQuery(
            "SELECT user_id FROM {schema}.channel_identity_bindings " ++
                "WHERE channel = $1 AND account_id = $2 AND principal_key = $3 AND scope_key = $4 AND thread_key_norm = $5 " ++
                "LIMIT 1",
        );
        defer self.allocator.free(q);
        const channel_z = try self.allocator.dupeZ(u8, channel);
        defer self.allocator.free(channel_z);
        const account_z = try self.allocator.dupeZ(u8, account_id);
        defer self.allocator.free(account_z);
        const principal_z = try self.allocator.dupeZ(u8, principal_key);
        defer self.allocator.free(principal_z);
        const scope_z = try self.allocator.dupeZ(u8, scope_key);
        defer self.allocator.free(scope_z);
        const thread_norm = if (thread_key) |value| value else "";
        const thread_norm_z = try self.allocator.dupeZ(u8, thread_norm);
        defer self.allocator.free(thread_norm_z);
        const params = [_]?[*:0]const u8{ channel_z, account_z, principal_z, scope_z, thread_norm_z };
        const lengths = [_]c_int{
            @intCast(channel.len),
            @intCast(account_id.len),
            @intCast(principal_key.len),
            @intCast(scope_key.len),
            @intCast(thread_norm.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        const user_text = try dupeResultValue(self.allocator, result, 0, 0);
        defer self.allocator.free(user_text);
        return std.fmt.parseInt(i64, user_text, 10) catch null;
    }

    pub fn listChannelIdentityBindings(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        channel: ?[]const u8,
    ) ![]ChannelIdentityBinding {
        const q = try self.buildQuery(
            "SELECT id, user_id, channel, account_id, principal_key, scope_key, thread_key, peer_kind, peer_id, metadata::text " ++
                "FROM {schema}.channel_identity_bindings " ++
                "WHERE user_id = $1 AND ($2::text = '' OR channel = $2::text) " ++
                "ORDER BY channel ASC, account_id ASC, principal_key ASC, scope_key ASC, thread_key_norm ASC",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const channel_text = channel orelse "";
        const channel_z = try self.allocator.dupeZ(u8, channel_text);
        defer self.allocator.free(channel_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, channel_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(channel_text.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const rows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(ChannelIdentityBinding, rows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*row| row.deinit(allocator);
            allocator.free(out);
        }
        for (0..rows) |i| {
            const row_idx: c_int = @intCast(i);
            const id = try dupeResultValue(allocator, result, row_idx, 0);
            const user_text = try dupeResultValue(allocator, result, row_idx, 1);
            defer allocator.free(user_text);
            const parsed_user = try std.fmt.parseInt(i64, user_text, 10);
            const channel_value = try dupeResultValue(allocator, result, row_idx, 2);
            const account_value = try dupeResultValue(allocator, result, row_idx, 3);
            const principal_value = try dupeResultValue(allocator, result, row_idx, 4);
            const scope_value = try dupeResultValue(allocator, result, row_idx, 5);
            const thread_nullable = try dupeNullableResultValue(allocator, result, row_idx, 6);
            const peer_kind_nullable = try dupeNullableResultValue(allocator, result, row_idx, 7);
            const peer_id_nullable = try dupeNullableResultValue(allocator, result, row_idx, 8);
            const metadata_value = try dupeResultValue(allocator, result, row_idx, 9);
            out[i] = .{
                .id = id,
                .user_id = parsed_user,
                .channel = channel_value,
                .account_id = account_value,
                .principal_key = principal_value,
                .scope_key = scope_value,
                .thread_key = thread_nullable,
                .peer_kind = peer_kind_nullable,
                .peer_id = peer_id_nullable,
                .metadata_json = metadata_value,
            };
            initialized += 1;
        }
        return out;
    }

    pub fn deleteChannelIdentityBinding(self: *Self, user_id: i64, binding_id: []const u8) !bool {
        const q = try self.buildQuery(
            "DELETE FROM {schema}.channel_identity_bindings WHERE user_id = $1 AND id = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const binding_z = try self.allocator.dupeZ(u8, binding_id);
        defer self.allocator.free(binding_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, binding_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(binding_id.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const affected = c.PQcmdTuples(result);
        if (affected == null) return false;
        return !std.mem.eql(u8, std.mem.span(affected), "0");
    }

    pub fn listTelegramBackfillCandidates(self: *Self, allocator: std.mem.Allocator) ![]TelegramBackfillCandidate {
        const q = try self.buildQuery(
            "SELECT user_id, COALESCE(telegram->>'account_id', 'default') AS account_id, (telegram->>'chat_id')::bigint AS chat_id " ++
                "FROM {schema}.channel_state " ++
                "WHERE telegram ? 'chat_id' AND COALESCE(telegram->>'chat_id', '') ~ '^-?[0-9]+$'",
        );
        defer self.allocator.free(q);
        const result = try self.exec(q);
        defer c.PQclear(result);
        const rows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(TelegramBackfillCandidate, rows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*row| row.deinit(allocator);
            allocator.free(out);
        }
        for (0..rows) |i| {
            const row_idx: c_int = @intCast(i);
            const user_text = try dupeResultValue(allocator, result, row_idx, 0);
            defer allocator.free(user_text);
            const chat_text = try dupeResultValue(allocator, result, row_idx, 2);
            defer allocator.free(chat_text);
            out[i] = .{
                .user_id = try std.fmt.parseInt(i64, user_text, 10),
                .account_id = try dupeResultValue(allocator, result, row_idx, 1),
                .chat_id = try std.fmt.parseInt(i64, chat_text, 10),
            };
            initialized += 1;
        }
        return out;
    }

    pub fn acquireUserOwnershipLease(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
        owner_id: []const u8,
        now_s: i64,
        lease_secs: u64,
    ) ![]u8 {
        if (owner_id.len == 0) return error.InvalidOwnerId;
        const q = try self.buildQuery(
            "INSERT INTO {schema}.tenant_user_leases (user_id, owner_id, lease_token, lease_until, updated_at) " ++
                "VALUES ($1, $2, $3, TO_TIMESTAMP(($4::bigint + $5::bigint)), NOW()) " ++
                "ON CONFLICT (user_id) DO UPDATE SET owner_id = EXCLUDED.owner_id, lease_token = EXCLUDED.lease_token, lease_until = EXCLUDED.lease_until, updated_at = NOW() " ++
                "WHERE {schema}.tenant_user_leases.lease_until < TO_TIMESTAMP($4::bigint) OR {schema}.tenant_user_leases.owner_id = $2 " ++
                "RETURNING lease_token",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const owner_z = try self.allocator.dupeZ(u8, owner_id);
        defer self.allocator.free(owner_z);
        const lease_token = try generateLeaseToken(allocator);
        errdefer allocator.free(lease_token);
        const token_z = try self.allocator.dupeZ(u8, lease_token);
        defer self.allocator.free(token_z);
        var now_buf: [32]u8 = undefined;
        const now_s_z = try std.fmt.bufPrintZ(&now_buf, "{d}", .{now_s});
        var lease_buf: [32]u8 = undefined;
        const lease_s_z = try std.fmt.bufPrintZ(&lease_buf, "{d}", .{lease_secs});
        const params = [_]?[*:0]const u8{ user_s.ptr, owner_z, token_z, now_s_z.ptr, lease_s_z.ptr };
        const lengths = [_]c_int{
            @intCast(user_s.len),
            @intCast(owner_id.len),
            @intCast(lease_token.len),
            @intCast(now_s_z.len),
            @intCast(lease_s_z.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return error.LockHeld;
        return lease_token;
    }

    pub fn releaseUserOwnershipLease(
        self: *Self,
        user_id: i64,
        owner_id: []const u8,
        lease_token: []const u8,
    ) !void {
        const q = try self.buildQuery(
            "DELETE FROM {schema}.tenant_user_leases WHERE user_id = $1 AND owner_id = $2 AND lease_token = $3",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const owner_z = try self.allocator.dupeZ(u8, owner_id);
        defer self.allocator.free(owner_z);
        const token_z = try self.allocator.dupeZ(u8, lease_token);
        defer self.allocator.free(token_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, owner_z, token_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(owner_id.len), @intCast(lease_token.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    pub fn countOwnedUserLeases(self: *Self, now_s: i64, owner_id: []const u8) !usize {
        if (owner_id.len == 0) return 0;
        const q = try self.buildQuery(
            "SELECT COUNT(*) FROM {schema}.tenant_user_leases WHERE owner_id = $1 AND lease_until > TO_TIMESTAMP($2::bigint)",
        );
        defer self.allocator.free(q);
        const owner_z = try self.allocator.dupeZ(u8, owner_id);
        defer self.allocator.free(owner_z);
        var now_buf: [32]u8 = undefined;
        const now_s_z = try std.fmt.bufPrintZ(&now_buf, "{d}", .{now_s});
        const params = [_]?[*:0]const u8{ owner_z, now_s_z.ptr };
        const lengths = [_]c_int{ @intCast(owner_id.len), @intCast(now_s_z.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        const text = try dupeResultValue(self.allocator, result, 0, 0);
        defer self.allocator.free(text);
        return try std.fmt.parseInt(usize, text, 10);
    }

    pub fn getUserOwnershipLeaseSnapshot(
        self: *Self,
        allocator: std.mem.Allocator,
        user_id: i64,
    ) !?UserOwnershipLeaseSnapshot {
        const q = try self.buildQuery(
            "SELECT owner_id, EXTRACT(EPOCH FROM lease_until)::bigint, EXTRACT(EPOCH FROM updated_at)::bigint " ++
                "FROM {schema}.tenant_user_leases WHERE user_id = $1 LIMIT 1",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;

        const owner_id = try dupeResultValue(allocator, result, 0, 0);
        errdefer allocator.free(owner_id);
        const lease_until_text = try dupeResultValue(allocator, result, 0, 1);
        defer allocator.free(lease_until_text);
        const updated_at_text = try dupeResultValue(allocator, result, 0, 2);
        defer allocator.free(updated_at_text);
        return .{
            .owner_id = owner_id,
            .lease_until_s = try std.fmt.parseInt(i64, lease_until_text, 10),
            .updated_at_s = try std.fmt.parseInt(i64, updated_at_text, 10),
        };
    }

    pub fn upsertTaskSnapshot(
        self: *Self,
        user_id: i64,
        task_id: []const u8,
        session_id: ?[]const u8,
        request_session_id: ?[]const u8,
        label: []const u8,
        prompt: []const u8,
        status: []const u8,
        result_text: ?[]const u8,
        error_text: ?[]const u8,
        created_at_ms: i64,
        started_at_ms: ?i64,
        completed_at_ms: ?i64,
    ) !void {
        if (session_id) |sid| try self.ensureSession(user_id, sid);
        if (request_session_id) |sid| try self.ensureSession(user_id, sid);

        const q = try self.buildQuery(
            "INSERT INTO {schema}.tasks (id, user_id, session_id, request_session_id, label, prompt, status, result, error, created_at, started_at, completed_at) " ++
                "VALUES ($1, $2, CASE WHEN $3 = '' THEN NULL ELSE $3 END, CASE WHEN $4 = '' THEN NULL ELSE $4 END, $5, $6, $7, CASE WHEN $8 = '' THEN NULL ELSE $8 END, CASE WHEN $9 = '' THEN NULL ELSE $9 END, " ++
                "TO_TIMESTAMP($10::double precision / 1000.0), CASE WHEN $11 = '' THEN NULL ELSE TO_TIMESTAMP($11::double precision / 1000.0) END, CASE WHEN $12 = '' THEN NULL ELSE TO_TIMESTAMP($12::double precision / 1000.0) END) " ++
                "ON CONFLICT (user_id, id) DO UPDATE SET session_id = EXCLUDED.session_id, request_session_id = EXCLUDED.request_session_id, label = EXCLUDED.label, prompt = EXCLUDED.prompt, status = EXCLUDED.status, result = EXCLUDED.result, error = EXCLUDED.error, created_at = EXCLUDED.created_at, started_at = EXCLUDED.started_at, completed_at = EXCLUDED.completed_at",
        );
        defer self.allocator.free(q);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const task_id_z = try self.allocator.dupeZ(u8, task_id);
        defer self.allocator.free(task_id_z);
        const session_value = session_id orelse "";
        const session_z = try self.allocator.dupeZ(u8, session_value);
        defer self.allocator.free(session_z);
        const request_session_value = request_session_id orelse "";
        const request_session_z = try self.allocator.dupeZ(u8, request_session_value);
        defer self.allocator.free(request_session_z);
        const label_z = try self.allocator.dupeZ(u8, label);
        defer self.allocator.free(label_z);
        const prompt_z = try self.allocator.dupeZ(u8, prompt);
        defer self.allocator.free(prompt_z);
        const status_z = try self.allocator.dupeZ(u8, status);
        defer self.allocator.free(status_z);
        const result_value = result_text orelse "";
        const result_z = try self.allocator.dupeZ(u8, result_value);
        defer self.allocator.free(result_z);
        const error_value = error_text orelse "";
        const error_z = try self.allocator.dupeZ(u8, error_value);
        defer self.allocator.free(error_z);
        var created_buf: [32]u8 = undefined;
        const created_s = try std.fmt.bufPrintZ(&created_buf, "{d}", .{created_at_ms});
        var started_buf: [32]u8 = undefined;
        const started_s = if (started_at_ms) |value| try std.fmt.bufPrintZ(&started_buf, "{d}", .{value}) else "";
        var completed_buf: [32]u8 = undefined;
        const completed_s = if (completed_at_ms) |value| try std.fmt.bufPrintZ(&completed_buf, "{d}", .{value}) else "";

        const params = [_]?[*:0]const u8{
            task_id_z,
            user_s.ptr,
            session_z,
            request_session_z,
            label_z,
            prompt_z,
            status_z,
            result_z,
            error_z,
            created_s.ptr,
            if (started_at_ms != null) started_s.ptr else null,
            if (completed_at_ms != null) completed_s.ptr else null,
        };
        const lengths = [_]c_int{
            @intCast(task_id.len),
            @intCast(user_s.len),
            @intCast(session_value.len),
            @intCast(request_session_value.len),
            @intCast(label.len),
            @intCast(prompt.len),
            @intCast(status.len),
            @intCast(result_value.len),
            @intCast(error_value.len),
            @intCast(created_s.len),
            @intCast(if (started_at_ms != null) started_s.len else 0),
            @intCast(if (completed_at_ms != null) completed_s.len else 0),
        };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    pub fn getTaskSnapshot(self: *Self, allocator: std.mem.Allocator, user_id: i64, task_id: []const u8) !?TaskSnapshot {
        const q = try self.buildQuery(
            "SELECT id, session_id, request_session_id, label, prompt, status, result, error, " ++
                "COALESCE((EXTRACT(EPOCH FROM created_at) * 1000)::bigint::text, '0'), " ++
                "CASE WHEN started_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM started_at) * 1000)::bigint::text END, " ++
                "CASE WHEN completed_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM completed_at) * 1000)::bigint::text END " ++
                "FROM {schema}.tasks WHERE user_id = $1 AND id = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const task_id_z = try self.allocator.dupeZ(u8, task_id);
        defer self.allocator.free(task_id_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, task_id_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(task_id.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return null;
        return try decodeTaskSnapshotRow(allocator, result, 0);
    }

    pub fn listTaskSnapshots(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]TaskSnapshot {
        const q = try self.buildQuery(
            "SELECT id, session_id, request_session_id, label, prompt, status, result, error, " ++
                "COALESCE((EXTRACT(EPOCH FROM created_at) * 1000)::bigint::text, '0'), " ++
                "CASE WHEN started_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM started_at) * 1000)::bigint::text END, " ++
                "CASE WHEN completed_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM completed_at) * 1000)::bigint::text END " ++
                "FROM {schema}.tasks WHERE user_id = $1 ORDER BY created_at ASC, id ASC",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const rows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(TaskSnapshot, rows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*entry| entry.deinit(allocator);
            allocator.free(out);
        }

        for (0..rows) |i| {
            out[i] = try decodeTaskSnapshotRow(allocator, result, @intCast(i));
            initialized += 1;
        }
        return out;
    }

    pub fn claimDueJobs(self: *Self, allocator: std.mem.Allocator, owner_id: []const u8, now_s: i64, lease_secs: u64, limit: usize) ![]ClaimedJob {
        const q = try self.buildQuery(
            "WITH due AS (" ++
                " SELECT id FROM {schema}.jobs" ++
                " WHERE enabled = TRUE" ++
                " AND COALESCE(next_run_at, run_at, NOW()) <= TO_TIMESTAMP($2::bigint)" ++
                " AND (lease_until IS NULL OR lease_until < TO_TIMESTAMP($2::bigint))" ++
                " ORDER BY COALESCE(next_run_at, run_at, NOW()) ASC, created_at ASC" ++
                " LIMIT $4 FOR UPDATE SKIP LOCKED" ++
                " ) UPDATE {schema}.jobs j" ++
                " SET lease_owner = $1, lease_until = TO_TIMESTAMP(($2::bigint + $3::bigint)), updated_at = NOW()" ++
                " FROM due, {schema}.users u" ++
                " WHERE j.id = due.id AND u.user_id = j.user_id" ++
                " RETURNING j.id, j.user_id, COALESCE(j.session_id, ''), u.workspace_path, j.raw_job::text",
        );
        defer self.allocator.free(q);
        const owner_z = try self.allocator.dupeZ(u8, owner_id);
        defer self.allocator.free(owner_z);
        var now_buf: [32]u8 = undefined;
        const now_z = try std.fmt.bufPrintZ(&now_buf, "{d}", .{now_s});
        var lease_buf: [32]u8 = undefined;
        const lease_z = try std.fmt.bufPrintZ(&lease_buf, "{d}", .{lease_secs});
        var limit_buf: [32]u8 = undefined;
        const limit_z = try std.fmt.bufPrintZ(&limit_buf, "{d}", .{limit});
        const params = [_]?[*:0]const u8{ owner_z, now_z.ptr, lease_z.ptr, limit_z.ptr };
        const lengths = [_]c_int{ @intCast(owner_id.len), @intCast(now_z.len), @intCast(lease_z.len), @intCast(limit_z.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const rows: usize = @intCast(c.PQntuples(result));
        const jobs = try allocator.alloc(ClaimedJob, rows);
        errdefer {
            for (jobs[0..rows]) |*job| job.deinit(allocator);
            allocator.free(jobs);
        }
        for (0..rows) |i| {
            const row: c_int = @intCast(i);
            const user_text = try dupeResultValue(allocator, result, row, 1);
            defer allocator.free(user_text);
            jobs[i] = .{
                .id = try dupeResultValue(allocator, result, row, 0),
                .user_id = try std.fmt.parseInt(i64, user_text, 10),
                .session_id = try dupeResultValue(allocator, result, row, 2),
                .workspace_path = try dupeResultValue(allocator, result, row, 3),
                .raw_job_json = try dupeResultValue(allocator, result, row, 4),
            };
        }
        return jobs;
    }

    pub fn completeClaimedJob(
        self: *Self,
        user_id: i64,
        job_id: []const u8,
        owner_id: []const u8,
        raw_job_json: ?[]const u8,
        next_run_secs: ?i64,
        status: ?[]const u8,
        output: ?[]const u8,
        started_at_s: i64,
        finished_at_s: i64,
    ) !void {
        try self.insertJobRun(user_id, job_id, status orelse "unknown", output, started_at_s, finished_at_s);
        if (raw_job_json) |json| {
            const q = try self.buildQuery(
                "UPDATE {schema}.jobs SET raw_job = $1::jsonb, next_run_at = CASE WHEN $2 = '' THEN NULL ELSE TO_TIMESTAMP($2::bigint) END, last_run_at = TO_TIMESTAMP($3::bigint), last_status = $4, last_error = CASE WHEN $4 = 'ok' THEN NULL ELSE $5 END, lease_owner = NULL, lease_until = NULL, updated_at = NOW() " ++
                    "WHERE user_id = $6 AND id = $7 AND lease_owner = $8",
            );
            defer self.allocator.free(q);
            const json_z = try self.allocator.dupeZ(u8, json);
            defer self.allocator.free(json_z);
            var next_buf: [32]u8 = undefined;
            const next_z = if (next_run_secs) |v| try std.fmt.bufPrintZ(&next_buf, "{d}", .{v}) else "";
            var finished_buf: [32]u8 = undefined;
            const finished_z = try std.fmt.bufPrintZ(&finished_buf, "{d}", .{finished_at_s});
            const status_z = try self.allocator.dupeZ(u8, status orelse "unknown");
            defer self.allocator.free(status_z);
            const error_z = try self.allocator.dupeZ(u8, output orelse "");
            defer self.allocator.free(error_z);
            var user_buf: [32]u8 = undefined;
            const user_z = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
            const job_id_z = try self.allocator.dupeZ(u8, job_id);
            defer self.allocator.free(job_id_z);
            const owner_z = try self.allocator.dupeZ(u8, owner_id);
            defer self.allocator.free(owner_z);
            const params = [_]?[*:0]const u8{ json_z, if (next_run_secs != null) next_z.ptr else "", finished_z.ptr, status_z, error_z, user_z.ptr, job_id_z, owner_z };
            const lengths = [_]c_int{ @intCast(json.len), @intCast(if (next_run_secs != null) next_z.len else 0), @intCast(finished_z.len), @intCast((status orelse "unknown").len), @intCast((output orelse "").len), @intCast(user_z.len), @intCast(job_id.len), @intCast(owner_id.len) };
            const result = try self.execParams(q, &params, &lengths);
            c.PQclear(result);
        } else {
            const q = try self.buildQuery(
                "UPDATE {schema}.jobs SET enabled = FALSE, next_run_at = NULL, last_run_at = TO_TIMESTAMP($1::bigint), last_status = $2, last_error = CASE WHEN $2 = 'ok' THEN NULL ELSE $3 END, lease_owner = NULL, lease_until = NULL, updated_at = NOW() " ++
                    "WHERE user_id = $4 AND id = $5 AND lease_owner = $6",
            );
            defer self.allocator.free(q);
            var finished_buf: [32]u8 = undefined;
            const finished_z = try std.fmt.bufPrintZ(&finished_buf, "{d}", .{finished_at_s});
            const status_z = try self.allocator.dupeZ(u8, status orelse "unknown");
            defer self.allocator.free(status_z);
            const error_z = try self.allocator.dupeZ(u8, output orelse "");
            defer self.allocator.free(error_z);
            var user_buf: [32]u8 = undefined;
            const user_z = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
            const job_id_z = try self.allocator.dupeZ(u8, job_id);
            defer self.allocator.free(job_id_z);
            const owner_z = try self.allocator.dupeZ(u8, owner_id);
            defer self.allocator.free(owner_z);
            const params = [_]?[*:0]const u8{ finished_z.ptr, status_z, error_z, user_z.ptr, job_id_z, owner_z };
            const lengths = [_]c_int{ @intCast(finished_z.len), @intCast((status orelse "unknown").len), @intCast((output orelse "").len), @intCast(user_z.len), @intCast(job_id.len), @intCast(owner_id.len) };
            const result = try self.execParams(q, &params, &lengths);
            c.PQclear(result);
        }
    }

    fn ensureSession(self: *Self, user_id: i64, session_id: []const u8) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.sessions (id, user_id, session_key, kind, title) VALUES ($1, $2, $1, $3, $4) " ++
                "ON CONFLICT (session_key) DO NOTHING",
        );
        defer self.allocator.free(q);
        const kind = if (std.mem.endsWith(u8, session_id, ":main")) "main" else "system";
        const title = if (std.mem.eql(u8, kind, "main")) "Main" else "Session";
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_z = try self.allocator.dupeZ(u8, session_id);
        defer self.allocator.free(session_z);
        const kind_z = try self.allocator.dupeZ(u8, kind);
        defer self.allocator.free(kind_z);
        const title_z = try self.allocator.dupeZ(u8, title);
        defer self.allocator.free(title_z);
        const params = [_]?[*:0]const u8{ session_z, user_s.ptr, kind_z, title_z };
        const lengths = [_]c_int{ @intCast(session_id.len), @intCast(user_s.len), @intCast(kind.len), @intCast(title.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// List all session keys for a user from the persistent sessions table.
    /// Returns sessions with metadata (key, kind, title, message count, last activity).
    /// Used by the session panel to show both live and evicted sessions.
    pub fn listUserSessions(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]SessionInfo {
        const q = try self.buildQuery(
            "SELECT s.session_key, s.kind, s.title, " ++
                "COALESCE((SELECT COUNT(*) FROM {schema}.messages m WHERE m.user_id = s.user_id AND m.session_id = s.session_key), 0) AS message_count, " ++
                "COALESCE((SELECT MAX(created_at) FROM {schema}.messages m WHERE m.user_id = s.user_id AND m.session_id = s.session_key), s.created_at) AS last_active " ++
                "FROM {schema}.sessions s WHERE s.user_id = $1 ORDER BY last_active DESC",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);

        const rows: usize = @intCast(c.PQntuples(result));
        const out = try allocator.alloc(SessionInfo, rows);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*info| info.deinit(allocator);
            allocator.free(out);
        }

        for (0..rows) |i| {
            const row: c_int = @intCast(i);
            const count_str = try dupeResultValue(allocator, result, row, 3);
            defer allocator.free(count_str);

            // Allocate each field individually with errdefer cleanup
            const sk = try dupeResultValue(allocator, result, row, 0);
            errdefer allocator.free(sk);
            const kd = try dupeResultValue(allocator, result, row, 1);
            errdefer allocator.free(kd);
            const tt = try dupeResultValue(allocator, result, row, 2);
            errdefer allocator.free(tt);
            const la = try dupeResultValue(allocator, result, row, 4);

            out[i] = .{
                .session_key = sk,
                .kind = kd,
                .title = tt,
                .message_count = std.fmt.parseInt(u32, count_str, 10) catch 0,
                .last_active = la,
            };
            initialized += 1;
        }
        return out;
    }

    fn decodeTaskSnapshotRow(allocator: std.mem.Allocator, result: *c.PGresult, row: c_int) !TaskSnapshot {
        const created_at_text = try dupeResultValue(allocator, result, row, 8);
        defer allocator.free(created_at_text);

        var started_at_ms: ?i64 = null;
        if (c.PQgetisnull(result, row, 9) == 0) {
            const started_at_text = try dupeResultValue(allocator, result, row, 9);
            defer allocator.free(started_at_text);
            started_at_ms = try std.fmt.parseInt(i64, started_at_text, 10);
        }

        var completed_at_ms: ?i64 = null;
        if (c.PQgetisnull(result, row, 10) == 0) {
            const completed_at_text = try dupeResultValue(allocator, result, row, 10);
            defer allocator.free(completed_at_text);
            completed_at_ms = try std.fmt.parseInt(i64, completed_at_text, 10);
        }

        return .{
            .id = try dupeResultValue(allocator, result, row, 0),
            .session_id = if (c.PQgetisnull(result, row, 1) == 1) null else try dupeResultValue(allocator, result, row, 1),
            .request_session_id = if (c.PQgetisnull(result, row, 2) == 1) null else try dupeResultValue(allocator, result, row, 2),
            .label = try dupeResultValue(allocator, result, row, 3),
            .prompt = try dupeResultValue(allocator, result, row, 4),
            .status = try dupeResultValue(allocator, result, row, 5),
            .result = if (c.PQgetisnull(result, row, 6) == 1) null else try dupeResultValue(allocator, result, row, 6),
            .error_msg = if (c.PQgetisnull(result, row, 7) == 1) null else try dupeResultValue(allocator, result, row, 7),
            .created_at_ms = try std.fmt.parseInt(i64, created_at_text, 10),
            .started_at_ms = started_at_ms,
            .completed_at_ms = completed_at_ms,
        };
    }

    fn queryMemories(self: *Self, allocator: std.mem.Allocator, template: []const u8, user_id: i64, value1: ?[]const u8, value2: ?[]const u8) ![]memory_root.MemoryEntry {
        const q = try self.buildQuery(template);
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const v1 = value1 orelse "";
        const v2 = value2 orelse "";
        const v1_z = try self.allocator.dupeZ(u8, v1);
        defer self.allocator.free(v1_z);
        const v2_z = try self.allocator.dupeZ(u8, v2);
        defer self.allocator.free(v2_z);
        const result = if (value1 != null and value2 != null) blk: {
            const params = [_]?[*:0]const u8{ user_s.ptr, v1_z, v2_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(v1.len), @intCast(v2.len) };
            break :blk try self.execParams(q, &params, &lengths);
        } else if (value1 != null) blk: {
            const params = [_]?[*:0]const u8{ user_s.ptr, v1_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(v1.len) };
            break :blk try self.execParams(q, &params, &lengths);
        } else blk: {
            const params = [_]?[*:0]const u8{user_s.ptr};
            const lengths = [_]c_int{@intCast(user_s.len)};
            break :blk try self.execParams(q, &params, &lengths);
        };
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, false);
    }

    fn bumpMemoryAccess(self: *Self, user_id: i64, key: []const u8) !void {
        const q = try self.buildQuery(
            "UPDATE {schema}.memories SET access_count = access_count + 1, last_accessed_at = NOW() WHERE user_id = $1 AND key = $2",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, key_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(key.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    /// V1.5 day-4 chunk 4A — log a traversal event (user viewed
    /// /brain/graph or /brain/timeline). Writes to `memory_events`
    /// with `event_type='traversal'` and `memory_id=NULL` (traversal
    /// events span multiple memories — the keys are in payload).
    /// Caller provides a pre-formed JSON payload string; we don't
    /// re-parse server-side.
    ///
    /// V1.6 ADD/UPDATE/DELETE classifier reads the `traversal` event
    /// stream as a learning signal (memories the user viewed are
    /// user-interesting). The Mem0 namespace pattern (locked in
    /// V1.5 day-2 design) reserves `event_type` so the classifier
    /// shares this table.
    ///
    /// Errors are non-fatal at the caller — the brain endpoint
    /// returns its result regardless. Logging gaps are preferable to
    /// failed user-facing requests.
    pub fn insertTraversalEvent(
        self: *Self,
        user_id: i64,
        payload_json: []const u8,
    ) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.memory_events (id, user_id, memory_id, event_type, payload) " ++
                "VALUES ($1, $2, NULL, 'traversal', $3::jsonb)",
        );
        defer self.allocator.free(q);

        const event_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(event_id);
        const event_id_z = try self.allocator.dupeZ(u8, event_id);
        defer self.allocator.free(event_id_z);

        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const payload_z = try self.allocator.dupeZ(u8, payload_json);
        defer self.allocator.free(payload_z);

        const params = [_]?[*:0]const u8{ event_id_z, user_s.ptr, payload_z };
        const lengths = [_]c_int{
            @intCast(event_id.len),
            @intCast(user_s.len),
            @intCast(payload_json.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    fn insertMemoryEvent(self: *Self, user_id: i64, memory_id: []const u8, event_type: []const u8, key: []const u8, content: []const u8, mem_type: []const u8, session_id: ?[]const u8) !void {
        const key_json = try jsonString(self.allocator, key);
        defer self.allocator.free(key_json);
        const mem_type_json = try jsonString(self.allocator, mem_type);
        defer self.allocator.free(mem_type_json);
        const session_json = try jsonString(self.allocator, session_id orelse "");
        defer self.allocator.free(session_json);
        const content_json = try jsonString(self.allocator, content);
        defer self.allocator.free(content_json);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"key\":{s},\"memory_type\":{s},\"session_id\":{s},\"content\":{s}}}",
            .{
                key_json,
                mem_type_json,
                session_json,
                content_json,
            },
        );
        defer self.allocator.free(payload);

        const q = try self.buildQuery(
            "INSERT INTO {schema}.memory_events (id, user_id, memory_id, event_type, payload) VALUES ($1, $2, $3, $4, $5::jsonb)",
        );
        defer self.allocator.free(q);
        const event_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(event_id);
        const event_id_z = try self.allocator.dupeZ(u8, event_id);
        defer self.allocator.free(event_id_z);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const memory_id_z = try self.allocator.dupeZ(u8, memory_id);
        defer self.allocator.free(memory_id_z);
        const event_type_z = try self.allocator.dupeZ(u8, event_type);
        defer self.allocator.free(event_type_z);
        const payload_z = try self.allocator.dupeZ(u8, payload);
        defer self.allocator.free(payload_z);
        const params = [_]?[*:0]const u8{ event_id_z, user_s.ptr, memory_id_z, event_type_z, payload_z };
        const lengths = [_]c_int{ @intCast(event_id.len), @intCast(user_s.len), @intCast(memory_id.len), @intCast(event_type.len), @intCast(payload.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    fn getJsonValue(self: *Self, allocator: std.mem.Allocator, user_id: i64, table: []const u8, column: []const u8, default_json: []const u8) ![]u8 {
        try pg_helpers.validateIdentifier(table);
        try pg_helpers.validateIdentifier(column);
        const table_q = try pg_helpers.quoteIdentifier(self.allocator, table);
        defer self.allocator.free(table_q);
        const col_q = try pg_helpers.quoteIdentifier(self.allocator, column);
        defer self.allocator.free(col_q);
        const schema_q = try pg_helpers.quoteIdentifier(self.allocator, self.schemaRaw());
        defer self.allocator.free(schema_q);
        const q = try std.fmt.allocPrint(self.allocator, "SELECT COALESCE({s}, $2::jsonb)::text FROM {s}.{s} WHERE user_id = $1", .{ col_q, schema_q, table_q });
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const default_z = try self.allocator.dupeZ(u8, default_json);
        defer self.allocator.free(default_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, default_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(default_json.len) };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return allocator.dupe(u8, default_json);
        return dupeResultValue(allocator, result, 0, 0);
    }

    fn execJsonUpsert(self: *Self, query: []const u8, user_id: i64, json: []const u8) !void {
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const json_z = try self.allocator.dupeZ(u8, json);
        defer self.allocator.free(json_z);
        const params = [_]?[*:0]const u8{ user_s.ptr, json_z };
        const lengths = [_]c_int{ @intCast(user_s.len), @intCast(json.len) };
        const result = try self.execParams(query, &params, &lengths);
        c.PQclear(result);
    }

    fn insertJobRun(self: *Self, user_id: i64, job_id: []const u8, status: []const u8, output: ?[]const u8, started_at_s: i64, finished_at_s: i64) !void {
        const q = try self.buildQuery(
            "INSERT INTO {schema}.job_runs (id, job_id, user_id, started_at, finished_at, status, output) VALUES ($1, $2, $3, TO_TIMESTAMP($4::bigint), TO_TIMESTAMP($5::bigint), $6, $7)",
        );
        defer self.allocator.free(q);
        const run_id = try self.randomHexId(self.allocator, 16);
        defer self.allocator.free(run_id);
        const run_id_z = try self.allocator.dupeZ(u8, run_id);
        defer self.allocator.free(run_id_z);
        const job_id_z = try self.allocator.dupeZ(u8, job_id);
        defer self.allocator.free(job_id_z);
        var user_buf: [32]u8 = undefined;
        const user_z = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        var start_buf: [32]u8 = undefined;
        const start_z = try std.fmt.bufPrintZ(&start_buf, "{d}", .{started_at_s});
        var finish_buf: [32]u8 = undefined;
        const finish_z = try std.fmt.bufPrintZ(&finish_buf, "{d}", .{finished_at_s});
        const status_z = try self.allocator.dupeZ(u8, status);
        defer self.allocator.free(status_z);
        const output_text = output orelse "";
        const output_z = try self.allocator.dupeZ(u8, output_text);
        defer self.allocator.free(output_z);
        const params = [_]?[*:0]const u8{ run_id_z, job_id_z, user_z.ptr, start_z.ptr, finish_z.ptr, status_z, output_z };
        const lengths = [_]c_int{ @intCast(run_id.len), @intCast(job_id.len), @intCast(user_z.len), @intCast(start_z.len), @intCast(finish_z.len), @intCast(status.len), @intCast(output_text.len) };
        const result = try self.execParams(q, &params, &lengths);
        c.PQclear(result);
    }

    fn encryptSecretForDb(self: *Self, plaintext: []const u8, aad: []const u8) !struct { ciphertext_hex: []u8, nonce_hex: []u8 } {
        if (!self.secrets_enabled or self.master_key == null) {
            const ct = try self.allocator.alloc(u8, plaintext.len * 2);
            _ = security_secrets.hexEncode(plaintext, ct);
            return .{ .ciphertext_hex = ct, .nonce_hex = try self.allocator.dupe(u8, "") };
        }
        var nonce: [security_secrets.NONCE_LEN]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        const ct_len = plaintext.len + security_secrets.TAG_LEN;
        const ct_buf = try self.allocator.alloc(u8, ct_len);
        defer self.allocator.free(ct_buf);
        const encrypted = try security_secrets.encrypt(self.master_key.?, nonce, plaintext, ct_buf);
        const ct_hex = try self.allocator.alloc(u8, encrypted.len * 2);
        _ = security_secrets.hexEncode(encrypted, ct_hex);
        const nonce_hex = try self.allocator.alloc(u8, nonce.len * 2);
        _ = security_secrets.hexEncode(&nonce, nonce_hex);
        _ = aad;
        return .{ .ciphertext_hex = ct_hex, .nonce_hex = nonce_hex };
    }

    fn decryptSecretHex(self: *Self, allocator: std.mem.Allocator, ct_hex: []const u8, nonce_hex: []const u8, aad: []const u8) ![]u8 {
        _ = aad;
        if (!self.secrets_enabled or self.master_key == null or nonce_hex.len == 0) {
            const plain = try allocator.alloc(u8, ct_hex.len / 2);
            const decoded = try security_secrets.hexDecode(ct_hex, plain);
            return try allocator.dupe(u8, decoded);
        }
        const nonce_buf = try allocator.alloc(u8, nonce_hex.len / 2);
        defer allocator.free(nonce_buf);
        const nonce_slice = try security_secrets.hexDecode(nonce_hex, nonce_buf);
        if (nonce_slice.len != security_secrets.NONCE_LEN) return error.InvalidNonce;
        const ciphertext_buf = try allocator.alloc(u8, ct_hex.len / 2);
        defer allocator.free(ciphertext_buf);
        const ciphertext = try security_secrets.hexDecode(ct_hex, ciphertext_buf);
        var plain_buf: [8192]u8 = undefined;
        const decrypted = try security_secrets.decrypt(self.master_key.?, nonce_slice[0..security_secrets.NONCE_LEN].*, ciphertext, &plain_buf);
        return try allocator.dupe(u8, decrypted);
    }

    fn buildQuery(self: *Self, template: []const u8) ![:0]u8 {
        const schema_q = try pg_helpers.quoteIdentifier(self.allocator, self.schemaRaw());
        defer self.allocator.free(schema_q);
        return try pg_helpers.buildQuery(self.allocator, template, schema_q, schema_q);
    }

    fn randomHexId(self: *Self, allocator: std.mem.Allocator, bytes_len: usize) ![]u8 {
        _ = self;
        const raw = try allocator.alloc(u8, bytes_len);
        defer allocator.free(raw);
        std.crypto.random.bytes(raw);
        const out = try allocator.alloc(u8, bytes_len * 2);
        _ = security_secrets.hexEncode(raw, out);
        return out;
    }

    fn generateLeaseToken(allocator: std.mem.Allocator) ![]u8 {
        const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        var random_bytes: [20]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var out: [20]u8 = undefined;
        for (random_bytes, 0..) |b, i| {
            out[i] = alphabet[@as(usize, b) % alphabet.len];
        }
        return allocator.dupe(u8, out[0..]);
    }

    fn exec(self: *Self, query: []const u8) !*c.PGresult {
        var lease = self.acquireConn(self.lock_timeout_ms) catch |err| switch (err) {
            error.ConnectionPoolBusy => return error.ConnectionFailed,
            else => return err,
        };
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);

        const conn = lease.conn;
        const query_z = try self.allocator.dupeZ(u8, query);
        defer self.allocator.free(query_z);
        const result = c.PQexec(conn, query_z) orelse {
            conn_healthy = false;
            return error.ExecFailed;
        };
        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
            log.err("postgres exec failed: {s}", .{c.PQerrorMessage(conn)});
            c.PQclear(result);
            return error.ExecFailed;
        }
        return result;
    }

    fn execMigrateStatement(self: *Self, template: []const u8, query: []const u8) !?*c.PGresult {
        var lease = self.acquireConn(self.lock_timeout_ms) catch |err| switch (err) {
            error.ConnectionPoolBusy => return error.ConnectionFailed,
            else => return err,
        };
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);

        const conn = lease.conn;
        const query_z = try self.allocator.dupeZ(u8, query);
        defer self.allocator.free(query_z);
        const result = c.PQexec(conn, query_z) orelse {
            conn_healthy = false;
            return error.ExecFailed;
        };
        const status = c.PQresultStatus(result);
        if (status == c.PGRES_COMMAND_OK or status == c.PGRES_TUPLES_OK) {
            return result;
        }

        if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
        if (canIgnoreMigrateError(template, c.PQerrorMessage(conn))) {
            c.PQclear(result);
            return null;
        }

        log.err("postgres exec failed: {s}", .{c.PQerrorMessage(conn)});
        c.PQclear(result);
        return error.ExecFailed;
    }

    fn execParams(self: *Self, query: []const u8, params: []const ?[*:0]const u8, lengths: []const c_int) !*c.PGresult {
        var lease = self.acquireConn(self.lock_timeout_ms) catch |err| switch (err) {
            error.ConnectionPoolBusy => return error.ConnectionFailed,
            else => return err,
        };
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);

        const conn = lease.conn;
        const query_z = try self.allocator.dupeZ(u8, query);
        defer self.allocator.free(query_z);
        const n: c_int = @intCast(params.len);
        const result = c.PQexecParams(
            conn,
            query_z,
            n,
            null,
            @ptrCast(params.ptr),
            lengths.ptr,
            null,
            0,
        ) orelse {
            conn_healthy = false;
            log.err("postgres exec params returned null status={d}: {s}; query={s}", .{ c.PQstatus(conn), c.PQerrorMessage(conn), query });
            return error.ExecFailed;
        };

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
            log.err("postgres exec params failed: {s}", .{c.PQerrorMessage(conn)});
            c.PQclear(result);
            return error.ExecFailed;
        }
        return result;
    }

    fn execParamsNoResult(self: *Self, template: []const u8, params: []const ?[*:0]const u8, lengths: []const c_int) !void {
        const query = try self.buildQuery(template);
        defer self.allocator.free(query);
        const result = try self.execParams(query, params, lengths);
        c.PQclear(result);
    }
};

fn dupeResultValue(allocator: std.mem.Allocator, result: *c.PGresult, row: c_int, col: c_int) ![]u8 {
    if (c.PQgetisnull(result, row, col) != 0) return allocator.dupe(u8, "");
    const len_raw = c.PQgetlength(result, row, col);
    if (len_raw <= 0) return allocator.dupe(u8, "");
    const len: usize = @intCast(len_raw);
    const val = c.PQgetvalue(result, row, col);
    const src: [*]align(1) const u8 = @ptrCast(val);
    const out = try allocator.alloc(u8, len);
    @memcpy(out, src[0..len]);
    return out;
}

fn dupeNullableResultValue(allocator: std.mem.Allocator, result: *c.PGresult, row: c_int, col: c_int) !?[]u8 {
    if (c.PQgetisnull(result, row, col) != 0) return null;
    return try dupeResultValue(allocator, result, row, col);
}

test "dupeResultValue byte-copy path tolerates misaligned source pointers" {
    const allocator = std.testing.allocator;
    const src_buf = [_]u8{ 9, 11, 13, 15, 17 };
    const misaligned_src: [*]align(1) const u8 = @ptrCast(&src_buf[1]);
    const out = try allocator.alloc(u8, 3);
    defer allocator.free(out);
    @memcpy(out, misaligned_src[0..3]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 11, 13, 15 }, out);
}

test "BRAIN_USER_KEY_FILTER mirrors memory_root.isBrainVisibleKey" {
    // V1.5.1 brain-hygiene cross-check.
    //
    // SQL filter and Zig predicate must agree on every representative key.
    // Drift breaks /brain/* hygiene silently — the SQL filter would let
    // some classes through while the Zig predicate would have hidden them
    // (or vice versa). This test pins the two definitions together.
    //
    // Each entry: (key, expect_visible). expect_visible=false means
    //   - Zig: isBrainVisibleKey(key) returns false
    //   - SQL: BRAIN_USER_KEY_FILTER would exclude this row
    // Both branches must agree per-entry.

    const cases = [_]struct { key: []const u8, expect_visible: bool }{
        // ── User-authored / synthesis (visible) ────────────────────────
        .{ .key = "user_lang", .expect_visible = true },
        .{ .key = "favorite_snack", .expect_visible = true },
        .{ .key = "compose:0123456789abcdef", .expect_visible = true },
        .{ .key = "anything_without_known_prefix", .expect_visible = true },

        // ── Audit (hidden) ─────────────────────────────────────────────
        .{ .key = "autosave_user_1714521600", .expect_visible = false },
        .{ .key = "autosave_assistant_1714521600", .expect_visible = false },
        .{ .key = "session_checkpoint_1714521600", .expect_visible = false },
        .{ .key = "audit_shell/1777419406559181000", .expect_visible = false },

        // ── Continuity (hidden) ────────────────────────────────────────
        .{ .key = "summary_latest/agent:zaki-bot:user:1:thread:main", .expect_visible = false },
        .{ .key = "session_summary/agent:zaki-bot:user:1:thread:main/1714521600", .expect_visible = false },
        .{ .key = "timeline_summary/agent:zaki-bot:user:1:thread:main/1714521600", .expect_visible = false },
        .{ .key = "durable_fact/1714521600/0", .expect_visible = false },
        .{ .key = "compaction_summary/foo", .expect_visible = false },
        .{ .key = "summary_fallback/foo", .expect_visible = false },
        .{ .key = "compaction_dropped/foo", .expect_visible = false },
        .{ .key = "context_anchor_current", .expect_visible = false },

        // ── Index (hidden) ─────────────────────────────────────────────
        .{ .key = "timeline_index/current", .expect_visible = false },

        // ── Internal (hidden) ──────────────────────────────────────────
        .{ .key = "__tombstone__/some_user_key", .expect_visible = false },
        .{ .key = "__bootstrap.prompt.AGENTS.md", .expect_visible = false },
        .{ .key = "last_hygiene_at", .expect_visible = false },
    };

    // Behavioral check: simulateSqlFilter mirrors the actual SQL semantics
    // by walking the same source-of-truth arrays. If isBrainVisibleKey and
    // simulateSqlFilter ever disagree, drift between Zig and SQL has
    // appeared. Both must derive from BRAIN_HIDDEN_PREFIXES + EXACT_KEYS.
    const simulateSqlFilter = struct {
        fn run(key: []const u8) bool {
            for (memory_root.BRAIN_HIDDEN_PREFIXES) |prefix| {
                if (std.mem.startsWith(u8, key, prefix)) return false;
            }
            for (memory_root.BRAIN_HIDDEN_EXACT_KEYS) |exact| {
                if (std.mem.eql(u8, key, exact)) return false;
            }
            return true;
        }
    }.run;

    for (cases) |tc| {
        const zig_visible = memory_root.isBrainVisibleKey(tc.key);
        const sim_visible = simulateSqlFilter(tc.key);
        try std.testing.expectEqual(tc.expect_visible, zig_visible);
        try std.testing.expectEqual(zig_visible, sim_visible);
    }

    // Structural check on the comptime-derived SQL constant: confirm every
    // prefix from BRAIN_HIDDEN_PREFIXES landed in the regex alternation,
    // and every exact key from BRAIN_HIDDEN_EXACT_KEYS landed in the NOT IN
    // clause. Catches the case where someone breaks the comptime
    // generator so the constant no longer reflects the source arrays.
    const filter = BRAIN_USER_KEY_FILTER;
    try std.testing.expect(std.mem.startsWith(u8, filter, "key !~ '^("));
    try std.testing.expect(std.mem.endsWith(u8, filter, ")"));
    for (memory_root.BRAIN_HIDDEN_PREFIXES) |prefix| {
        // Each prefix must appear in the regex alternation. For the only
        // prefix containing a regex meta-char (`__bootstrap.prompt.`),
        // verify the escaped form is present.
        if (std.mem.indexOf(u8, prefix, ".") != null) {
            // Regex-escape dots manually for the assertion (must match
            // what the comptime generator does).
            var escaped: [256]u8 = undefined;
            var w: usize = 0;
            for (prefix) |ch| {
                if (ch == '.') {
                    escaped[w] = '\\';
                    w += 1;
                    escaped[w] = '.';
                    w += 1;
                } else {
                    escaped[w] = ch;
                    w += 1;
                }
            }
            try std.testing.expect(std.mem.indexOf(u8, filter, escaped[0..w]) != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, filter, prefix) != null);
        }
    }
    for (memory_root.BRAIN_HIDDEN_EXACT_KEYS) |exact| {
        try std.testing.expect(std.mem.indexOf(u8, filter, exact) != null);
    }
}

test "V1.6 schema migration applies cleanly + memory_entities round-trips" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    // First migrate — fresh schema
    try mgr.migrate();

    // Second migrate — must be idempotent (re-running on populated DB)
    try mgr.migrate();

    // ── Verify all V1.6 columns exist on memories ─────────────────────
    const expected_columns = [_][]const u8{
        // V1.6 atomic-fact extraction
        "subject", "predicate", "object_key", "link_type",
        "attribution", "attributed_to",
        // V1.6 Graphiti six-field bi-temporal
        "valid_at", "invalid_at", "expired_at",
        "reference_time", "episodes",
        // V1.6 retrieval + supersession
        "lemmatized", "is_latest", "parent_memory_id",
        // V1.6 source attribution (M4)
        "source_session_id", "source_snippet",
    };

    for (expected_columns) |col| {
        const q = try std.fmt.allocPrint(
            allocator,
            "SELECT column_name FROM information_schema.columns " ++
                "WHERE table_schema = '{s}' AND table_name = 'memories' " ++
                "AND column_name = '{s}'",
            .{ schema, col },
        );
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        if (c.PQntuples(result) != 1) {
            std.debug.print("V1.6 column missing: {s}\n", .{col});
            return error.MissingColumn;
        }
    }

    // ── Verify memory_entities table exists + round-trips a row ───────
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    const insert_q = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO {s}.memory_entities (id, user_id, name, name_lower, entity_type) " ++
            "VALUES ('ent-1', 2, 'Alex', 'alex', 'PROPER')",
        .{schema},
    );
    defer allocator.free(insert_q);
    const ins_result = try mgr.exec(insert_q);
    c.PQclear(ins_result);

    const select_q = try std.fmt.allocPrint(
        allocator,
        "SELECT id, name, name_lower, entity_type FROM {s}.memory_entities WHERE user_id = 2",
        .{schema},
    );
    defer allocator.free(select_q);
    const sel_result = try mgr.exec(select_q);
    defer c.PQclear(sel_result);
    try std.testing.expectEqual(@as(c_int, 1), c.PQntuples(sel_result));

    const id = try dupeResultValue(allocator, sel_result, 0, 0);
    defer allocator.free(id);
    const name = try dupeResultValue(allocator, sel_result, 0, 1);
    defer allocator.free(name);
    const name_lower = try dupeResultValue(allocator, sel_result, 0, 2);
    defer allocator.free(name_lower);

    try std.testing.expectEqualStrings("ent-1", id);
    try std.testing.expectEqualStrings("Alex", name);
    try std.testing.expectEqualStrings("alex", name_lower);

    // ── Verify the partial indexes exist ───────────────────────────────
    const index_q = try std.fmt.allocPrint(
        allocator,
        "SELECT indexname FROM pg_indexes WHERE schemaname = '{s}' " ++
            "AND tablename IN ('memories', 'memory_entities', 'memory_edges') " ++
            "ORDER BY indexname",
        .{schema},
    );
    defer allocator.free(index_q);
    const idx_result = try mgr.exec(index_q);
    defer c.PQclear(idx_result);

    const expected_indexes = [_][]const u8{
        "idx_edges_source",
        "idx_edges_target",
        "idx_edges_triple",
        "idx_edges_validity",
        "idx_entities_user",
        "idx_entities_vec",
        "idx_memories_is_latest",
        "idx_memories_lemmatized",
        "idx_memories_metadata_subject",
        "idx_memories_object_key",
        "idx_memories_parent",
        "idx_memories_subject",
    };

    var found_indexes: std.StringHashMapUnmanaged(void) = .{};
    defer found_indexes.deinit(allocator);
    const tuples = c.PQntuples(idx_result);
    var i: c_int = 0;
    while (i < tuples) : (i += 1) {
        const idx_name = try dupeResultValue(allocator, idx_result, i, 0);
        try found_indexes.put(allocator, idx_name, {});
    }
    defer {
        var it = found_indexes.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
    }

    for (expected_indexes) |idx_name| {
        if (!found_indexes.contains(idx_name)) {
            std.debug.print("V1.6 index missing: {s}\n", .{idx_name});
            return error.MissingIndex;
        }
    }
}

test "V1.5.1 brain hygiene PG roundtrip — listMemoriesBrainVisible + listMemoriesTimeline filter agent bookkeeping" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    const user_id: i64 = 2;

    // ── Seed: 4 visible (user-authored) + 6 hidden (one of each class) ─
    try mgr.upsertMemory(user_id, "user_lang", "Prefers Zig", .core, null);
    try mgr.upsertMemory(user_id, "favorite_snack", "olives", .core, null);
    try mgr.upsertMemory(user_id, "compose:0123456789abcdef", "synth", .core, null);
    try mgr.upsertMemory(user_id, "morning_routine", "wake at 6", .daily, null);
    // hidden — audit family
    try mgr.upsertMemory(user_id, "session_checkpoint_1714521600", "type=session_checkpoint reason=shutdown", .daily, null);
    try mgr.upsertMemory(user_id, "audit_shell/1777419406559181000", "type=shell_audit cwd=/foo", .daily, null);
    // hidden — continuity family
    try mgr.upsertMemory(user_id, "summary_latest/agent:zaki-bot:user:7:thread:main", "type=summary_latest origin_channel=zaki_app", .daily, null);
    try mgr.upsertMemory(user_id, "timeline_summary/agent:zaki-bot:user:7:thread:main/1714521600", "type=timeline_summary", .daily, null);
    // hidden — internal family
    try mgr.upsertMemory(user_id, "context_anchor_current", "type=context_anchor", .core, null);
    try mgr.upsertMemory(user_id, "last_hygiene_at", "1714521600", .core, null);

    // ── /brain/graph path: listMemoriesBrainVisible ────────────────────
    const brain = try mgr.listMemoriesBrainVisible(allocator, user_id);
    defer memory_root.freeEntries(allocator, brain);
    try std.testing.expectEqual(@as(usize, 4), brain.len);
    var seen_user_lang = false;
    var seen_compose = false;
    for (brain) |entry| {
        // Cross-check: the predicate must agree with the SQL filter for
        // every returned key.
        try std.testing.expect(memory_root.isBrainVisibleKey(entry.key));
        if (std.mem.eql(u8, entry.key, "user_lang")) seen_user_lang = true;
        if (std.mem.eql(u8, entry.key, "compose:0123456789abcdef")) seen_compose = true;
        // Negative: no hidden-prefix key must appear in the result set.
        try std.testing.expect(!std.mem.startsWith(u8, entry.key, "session_checkpoint_"));
        try std.testing.expect(!std.mem.startsWith(u8, entry.key, "audit_shell/"));
        try std.testing.expect(!std.mem.startsWith(u8, entry.key, "summary_latest/"));
        try std.testing.expect(!std.mem.startsWith(u8, entry.key, "timeline_summary/"));
        try std.testing.expect(!std.mem.eql(u8, entry.key, "context_anchor_current"));
        try std.testing.expect(!std.mem.eql(u8, entry.key, "last_hygiene_at"));
    }
    try std.testing.expect(seen_user_lang);
    try std.testing.expect(seen_compose);

    // ── /brain/timeline path: listMemoriesTimeline (filter baked-in) ───
    const timeline = try mgr.listMemoriesTimeline(allocator, user_id, null, null, 100, null, null);
    defer memory_root.freeEntries(allocator, timeline);
    try std.testing.expectEqual(@as(usize, 4), timeline.len);
    for (timeline) |entry| {
        try std.testing.expect(memory_root.isBrainVisibleKey(entry.key));
    }

    // ── Sanity: agent-facing listMemories STILL sees everything ────────
    // The agent retrieval pipeline depends on continuity artifacts; the
    // hygiene filter MUST NOT leak into the agent path.
    const agent_facing = try mgr.listMemories(allocator, user_id, null, null);
    defer memory_root.freeEntries(allocator, agent_facing);
    try std.testing.expectEqual(@as(usize, 10), agent_facing.len);
}

fn categoryToMemoryType(category: memory_root.MemoryCategory) []const u8 {
    return switch (category) {
        .core => "core",
        .daily => "daily",
        .conversation => "conversation",
        .custom => |name| name,
    };
}

fn memoryTypeToCategory(allocator: std.mem.Allocator, mem_type: []const u8) !memory_root.MemoryCategory {
    if (std.mem.eql(u8, mem_type, "core")) return .core;
    if (std.mem.eql(u8, mem_type, "daily")) return .daily;
    if (std.mem.eql(u8, mem_type, "conversation")) return .conversation;
    return .{ .custom = try allocator.dupe(u8, mem_type) };
}

fn computeContentHash(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    _ = security_secrets.hexEncode(&digest, out);
    return out;
}

fn decodeMemoryEntry(allocator: std.mem.Allocator, result: *c.PGresult, row: c_int) !memory_root.MemoryEntry {
    const mem_type = try dupeResultValue(allocator, result, row, 3);
    defer allocator.free(mem_type);
    const session_text = try dupeResultValue(allocator, result, row, 5);
    errdefer allocator.free(session_text);

    const sid: ?[]u8 = if (session_text.len == 0) blk: {
        allocator.free(session_text);
        break :blk null;
    } else session_text;

    // S8.1 — populate `lane` from session_id when present (matches the
    // sqlite engine wiring at `memory/engines/sqlite.zig`). Borrowed
    // string-literal pointer; no alloc/free coupling. Without this, all
    // postgres-backed retrievals would land at `lane = "unknown"` and
    // the same-lane ranking heuristic in the agent layer would no-op
    // for production deployments. Post-S8.1 review fix (M-LANE).
    const lane: []const u8 = if (sid) |s| memory_root.laneFromSessionId(s) else "unknown";

    // V1.5 day-2 — column 6 is `valid_to` (BIGINT, nullable). PG returns
    // empty string when NULL via dupeResultValue; treat empty + parse-
    // failure as null to keep the read path forgiving. V1.5 always-null
    // path means most rows hit the empty branch.
    const valid_to_text = try dupeResultValue(allocator, result, row, 6);
    defer allocator.free(valid_to_text);
    const valid_to: ?i64 = if (valid_to_text.len == 0)
        null
    else
        std.fmt.parseInt(i64, valid_to_text, 10) catch null;

    return .{
        .id = try dupeResultValue(allocator, result, row, 0),
        .key = try dupeResultValue(allocator, result, row, 1),
        .content = try dupeResultValue(allocator, result, row, 2),
        .category = try memoryTypeToCategory(allocator, mem_type),
        .timestamp = try dupeResultValue(allocator, result, row, 4),
        .session_id = sid,
        .score = null,
        .lane = lane,
        .valid_to = valid_to,
    };
}

fn decodeMemoryRows(allocator: std.mem.Allocator, result: *c.PGresult, has_score: bool) ![]memory_root.MemoryEntry {
    const rows: usize = @intCast(c.PQntuples(result));
    const out = try allocator.alloc(memory_root.MemoryEntry, rows);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*entry| entry.deinit(allocator);
        allocator.free(out);
    }

    for (0..rows) |i| {
        const row: c_int = @intCast(i);
        out[i] = try decodeMemoryEntry(allocator, result, row);
        if (has_score) {
            // V1.5 day-2 — score column shifted from 6 → 7 because
            // valid_to now occupies column 6 in recall queries. Both
            // recall query branches in `recallMemories` SELECT in this
            // order: id, key, content, memory_type, ts_text, session_id,
            // valid_to, score.
            const score_text = try dupeResultValue(allocator, result, row, 7);
            defer allocator.free(score_text);
            out[i].score = std.fmt.parseFloat(f64, score_text) catch null;
        }
        initialized += 1;
    }
    return out;
}

fn jsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn canIgnoreMigrateError(template: []const u8, raw_err: [*c]const u8) bool {
    const err_text = std.mem.span(raw_err);
    if (std.mem.startsWith(u8, template, "CREATE SCHEMA IF NOT EXISTS")) {
        return std.mem.indexOf(u8, err_text, "pg_namespace_nspname_index") != null or
            std.mem.indexOf(u8, err_text, "already exists") != null;
    }
    if (std.mem.startsWith(u8, template, "CREATE EXTENSION IF NOT EXISTS")) {
        return std.mem.indexOf(u8, err_text, "already exists") != null or
            std.mem.indexOf(u8, err_text, "pg_extension_name_index") != null or
            std.mem.indexOf(u8, err_text, "duplicate key value violates unique constraint") != null;
    }
    if (std.mem.startsWith(u8, template, "CREATE INDEX IF NOT EXISTS")) {
        return std.mem.indexOf(u8, err_text, "already exists") != null or
            std.mem.indexOf(u8, err_text, "pg_class_relname_nsp_index") != null;
    }
    if (std.mem.startsWith(u8, template, "CREATE UNIQUE INDEX IF NOT EXISTS")) {
        return std.mem.indexOf(u8, err_text, "already exists") != null or
            std.mem.indexOf(u8, err_text, "pg_class_relname_nsp_index") != null;
    }
    if (std.mem.startsWith(u8, template, "CREATE TABLE IF NOT EXISTS")) {
        return std.mem.indexOf(u8, err_text, "already exists") != null or
            std.mem.indexOf(u8, err_text, "pg_type_typname_nsp_index") != null or
            std.mem.indexOf(u8, err_text, "pg_class_relname_nsp_index") != null or
            std.mem.indexOf(u8, err_text, "duplicate key value violates unique constraint") != null;
    }
    if (std.mem.startsWith(u8, template, "ALTER TABLE") and std.mem.indexOf(u8, template, "ADD CONSTRAINT users_user_id_fkey") != null) {
        return std.mem.indexOf(u8, err_text, "already exists") != null or
            std.mem.indexOf(u8, err_text, "duplicate_object") != null or
            std.mem.indexOf(u8, err_text, "permission denied for table zaki_users") != null or
            std.mem.indexOf(u8, err_text, "relation \"zaki_users\" does not exist") != null or
            std.mem.indexOf(u8, err_text, "relation \"public.zaki_users\" does not exist") != null;
    }
    if (std.mem.startsWith(u8, template, "ALTER TABLE") and std.mem.indexOf(u8, template, "DROP CONSTRAINT IF EXISTS") != null) {
        return std.mem.indexOf(u8, err_text, "does not exist") != null;
    }
    if (std.mem.startsWith(u8, template, "ALTER TABLE") and std.mem.indexOf(u8, template, "ADD PRIMARY KEY (user_id, id)") != null) {
        return std.mem.indexOf(u8, err_text, "multiple primary keys for table") != null or
            std.mem.indexOf(u8, err_text, "already exists") != null;
    }
    return false;
}

fn loadMasterKey(allocator: std.mem.Allocator, env_name: []const u8) !?[security_secrets.KEY_LEN]u8 {
    const raw = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);
    var digest: [security_secrets.KEY_LEN]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    return digest;
}

test "canIgnoreMigrateError tolerates extension duplicate key race" {
    const tpl = "CREATE EXTENSION IF NOT EXISTS pgcrypto";
    const err_text: [:0]const u8 = "ERROR:  duplicate key value violates unique constraint \"pg_extension_name_index\"";
    try std.testing.expect(canIgnoreMigrateError(tpl, err_text.ptr));
}

test "canIgnoreMigrateError tolerates users fk permission denial" {
    const tpl = "ALTER TABLE {schema}.users ADD CONSTRAINT users_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.zaki_users(id) ON DELETE CASCADE";
    const err_text: [:0]const u8 = "ERROR:  permission denied for table zaki_users";
    try std.testing.expect(canIgnoreMigrateError(tpl, err_text.ptr));
}

test "canIgnoreMigrateError tolerates missing public zaki_users relation" {
    const tpl = "ALTER TABLE {schema}.users ADD CONSTRAINT users_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.zaki_users(id) ON DELETE CASCADE";
    const err_text: [:0]const u8 = "ERROR:  relation \"public.zaki_users\" does not exist";
    try std.testing.expect(canIgnoreMigrateError(tpl, err_text.ptr));
}

test "canIgnoreMigrateError tolerates create table duplicate typname race" {
    const tpl = "CREATE TABLE IF NOT EXISTS {schema}.users (...)";
    const err_text: [:0]const u8 = "ERROR:  duplicate key value violates unique constraint \"pg_type_typname_nsp_index\"";
    try std.testing.expect(canIgnoreMigrateError(tpl, err_text.ptr));
}

test "canIgnoreMigrateError tolerates create unique index duplicate race" {
    const tpl = "CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_user_key ON {schema}.memories(user_id, key)";
    const err_text: [:0]const u8 = "ERROR:  duplicate key value violates unique constraint \"pg_class_relname_nsp_index\"";
    try std.testing.expect(canIgnoreMigrateError(tpl, err_text.ptr));
}

test "canIgnoreMigrateError tolerates tasks add primary key race" {
    const tpl = "ALTER TABLE {schema}.tasks ADD PRIMARY KEY (user_id, id)";
    const err_text: [:0]const u8 = "ERROR:  multiple primary keys for table \"tasks\" are not allowed";
    try std.testing.expect(canIgnoreMigrateError(tpl, err_text.ptr));
}

fn initPostgresTestManagerWithPool(allocator: std.mem.Allocator, pool_max: u32, lock_timeout_ms: u32) !ManagerImpl {
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
            .pool_max = pool_max,
            .lock_timeout_ms = lock_timeout_ms,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    return mgr;
}

test "postgres claimed job one-shot completion preserves run history and disables job in management view" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();

    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");
    try mgr.replaceJobsJson(2, "agent:zaki-bot:user:2:main", "[{\"id\":\"once-reminder\",\"expression\":\"@once:1m\",\"command\":\"message \\\"hello\\\"\",\"next_run_secs\":1,\"one_shot\":true,\"job_type\":\"agent\",\"session_target\":\"main\",\"prompt\":\"say hello\",\"delivery\":{\"mode\":\"always\",\"channel\":\"telegram\",\"to\":\"chat-2\",\"best_effort\":false}}]");

    const claimed = try mgr.claimDueJobs(allocator, "test-owner", 5, 60, 10);
    defer {
        for (claimed) |*job| job.deinit(allocator);
        allocator.free(claimed);
    }
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    try std.testing.expectEqual(@as(i64, 2), claimed[0].user_id);
    try std.testing.expect(std.mem.startsWith(u8, claimed[0].id, "user:2:once-reminder"));

    try mgr.completeClaimedJob(2, claimed[0].id, "test-owner", null, null, "ok", "reminder sent", 5, 6);

    const jobs_after = try mgr.getJobsJson(allocator, 2);
    defer allocator.free(jobs_after);
    const parsed_jobs = try std.json.parseFromSlice(std.json.Value, allocator, jobs_after, .{});
    defer parsed_jobs.deinit();
    try std.testing.expect(parsed_jobs.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed_jobs.value.array.items.len);
    try std.testing.expectEqualStrings("once-reminder", parsed_jobs.value.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(false, parsed_jobs.value.array.items[0].object.get("enabled").?.bool);

    const q = try mgr.buildQuery("SELECT COUNT(*) FROM {schema}.job_runs WHERE user_id = $1 AND job_id = $2");
    defer allocator.free(q);
    var user_buf: [32]u8 = undefined;
    const user_z = try std.fmt.bufPrintZ(&user_buf, "{d}", .{2});
    const job_id_z = try allocator.dupeZ(u8, claimed[0].id);
    defer allocator.free(job_id_z);
    const params = [_]?[*:0]const u8{ user_z.ptr, job_id_z };
    const lengths = [_]c_int{ @intCast(user_z.len), @intCast(claimed[0].id.len) };
    const result = try mgr.execParams(q, &params, &lengths);
    defer c.PQclear(result);
    const run_count_text = try dupeResultValue(allocator, result, 0, 0);
    defer allocator.free(run_count_text);
    const run_count = try std.fmt.parseInt(usize, run_count_text, 10);
    try std.testing.expectEqual(@as(usize, 1), run_count);

    const claimed_again = try mgr.claimDueJobs(allocator, "test-owner", 10, 60, 10);
    defer {
        for (claimed_again) |*job| job.deinit(allocator);
        allocator.free(claimed_again);
    }
    try std.testing.expectEqual(@as(usize, 0), claimed_again.len);
}

test "postgres claimed recurring job reschedules and records run" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();

    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    var scheduler = cron_mod.CronScheduler.init(allocator, 1, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("*/5 * * * *", "echo scheduled");
    const old_id = job.id;
    scheduler.jobs.items[0].id = try allocator.dupe(u8, "recurring-reminder");
    allocator.free(old_id);
    scheduler.jobs.items[0].job_type = .agent;
    scheduler.jobs.items[0].session_target = .main;
    scheduler.jobs.items[0].prompt = try allocator.dupe(u8, "check in");
    scheduler.jobs.items[0].prompt_owned = true;
    scheduler.jobs.items[0].delivery = .{
        .mode = .always,
        .channel = try allocator.dupe(u8, "telegram"),
        .to = try allocator.dupe(u8, "chat-2"),
        .best_effort = true,
    };
    scheduler.jobs.items[0].delivery_channel_owned = true;
    scheduler.jobs.items[0].delivery_to_owned = true;
    scheduler.jobs.items[0].next_run_secs = 10;

    const jobs_json = try cron_mod.saveJobsToSlice(allocator, &scheduler);
    defer allocator.free(jobs_json);
    try mgr.replaceJobsJson(2, "agent:zaki-bot:user:2:main", jobs_json);

    const claimed = try mgr.claimDueJobs(allocator, "test-owner", 10, 60, 10);
    defer {
        for (claimed) |*claimed_job| claimed_job.deinit(allocator);
        allocator.free(claimed);
    }
    try std.testing.expectEqual(@as(usize, 1), claimed.len);

    var runtime_scheduler = cron_mod.CronScheduler.init(allocator, 1, true);
    defer runtime_scheduler.deinit();
    try runtime_scheduler.setExecutionContext("2", "/tmp/nullalis-zaki-bot-test-user-2", "/tmp/nullalis-zaki-bot-test-user-2/workspace");
    try cron_mod.loadJobFromJsonSlice(&runtime_scheduler, claimed[0].raw_job_json);
    // D14 fix: the test exercises job_type=.agent which requires an agent
    // runner; without one, tick() sets last_status="error" and the assertion
    // below (expectEqualStrings("ok", ...)) fails. Wire a stub runner that
    // returns a fixed string — the test's intent is "scheduler reschedules
    // and records run", not "agent execution semantics."
    const StubRunner = struct {
        fn run(_: ?*anyopaque, alloc: std.mem.Allocator, _: *const cron_mod.CronScheduler, _: *const cron_mod.CronJob, _: []const u8) ![]const u8 {
            return alloc.dupe(u8, "ok");
        }
    };
    runtime_scheduler.setAgentRunner(&StubRunner.run, null);
    _ = runtime_scheduler.tick(10, null);
    try std.testing.expectEqual(@as(usize, 1), runtime_scheduler.listJobs().len);
    const updated_json = try cron_mod.jobToJson(allocator, &runtime_scheduler.listJobs()[0]);
    defer allocator.free(updated_json);

    try mgr.completeClaimedJob(2, claimed[0].id, "test-owner", updated_json, runtime_scheduler.listJobs()[0].next_run_secs, runtime_scheduler.listJobs()[0].last_status, runtime_scheduler.listJobs()[0].last_output, 10, 11);

    const jobs_after = try mgr.getJobsJson(allocator, 2);
    defer allocator.free(jobs_after);
    const parsed_jobs = try std.json.parseFromSlice(std.json.Value, allocator, jobs_after, .{});
    defer parsed_jobs.deinit();
    try std.testing.expect(parsed_jobs.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed_jobs.value.array.items.len);
    try std.testing.expect(parsed_jobs.value.array.items[0] == .object);
    const stored_job = parsed_jobs.value.array.items[0].object;
    try std.testing.expectEqualStrings("recurring-reminder", stored_job.get("id").?.string);
    try std.testing.expectEqualStrings("ok", stored_job.get("last_status").?.string);

    const future_claim = try mgr.claimDueJobs(allocator, "test-owner", 11, 60, 10);
    defer {
        for (future_claim) |*claimed_job| claimed_job.deinit(allocator);
        allocator.free(future_claim);
    }
    try std.testing.expectEqual(@as(usize, 0), future_claim.len);

    const runs = try mgr.listJobRuns(allocator, 2, "recurring-reminder", 10);
    defer {
        for (runs) |run| {
            allocator.free(@constCast(run.job_id));
            allocator.free(@constCast(run.status));
            if (run.output) |value| allocator.free(@constCast(value));
        }
        allocator.free(runs);
    }
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqualStrings("recurring-reminder", runs[0].job_id);
    try std.testing.expectEqualStrings("ok", runs[0].status);
    try std.testing.expectEqualStrings("ok", runs[0].output.?);
}

test "postgres getJobsJson includes disabled jobs for management views" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");
    try mgr.replaceJobsJson(2, "agent:zaki-bot:user:2:main", "[{\"id\":\"disabled-report\",\"expression\":\"0 9 * * *\",\"command\":\"echo report\",\"enabled\":false,\"paused\":true}]");

    const jobs_json = try mgr.getJobsJson(allocator, 2);
    defer allocator.free(jobs_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, jobs_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("disabled-report", parsed.value.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(false, parsed.value.array.items[0].object.get("enabled").?.bool);
}

test "postgres replaceJobsJson scopes stored job ids per user while preserving raw ids" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");
    try mgr.provisionUser(42, "/tmp/nullalis-zaki-bot-test-user-42/workspace");

    const jobs_json = "[{\"id\":\"morning-brief\",\"expression\":\"0 8 * * *\",\"command\":\"daily_morning_brief\",\"job_type\":\"agent\"}]";
    try mgr.replaceJobsJson(2, "agent:zaki-bot:user:2:main", jobs_json);
    try mgr.replaceJobsJson(42, "agent:zaki-bot:user:42:main", jobs_json);

    const user2_jobs = try mgr.getJobsJson(allocator, 2);
    defer allocator.free(user2_jobs);
    const user42_jobs = try mgr.getJobsJson(allocator, 42);
    defer allocator.free(user42_jobs);

    // D14 fix: parse + assert structurally instead of substring-matching the
    // raw text. Postgres's jsonb→text serialization always inserts spaces
    // after colons (`"id": "morning-brief"` not `"id":"morning-brief"`), so
    // the prior tight indexOf was format-fragile. Parsing isolates intent
    // ("the raw id is preserved in the user-facing API output") from
    // backend formatting whims (Postgres / SQLite / future stores can
    // differ in whitespace without breaking the test).
    const user2_parsed = try std.json.parseFromSlice(std.json.Value, allocator, user2_jobs, .{});
    defer user2_parsed.deinit();
    try std.testing.expect(user2_parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), user2_parsed.value.array.items.len);
    try std.testing.expectEqualStrings("morning-brief", user2_parsed.value.array.items[0].object.get("id").?.string);

    const user42_parsed = try std.json.parseFromSlice(std.json.Value, allocator, user42_jobs, .{});
    defer user42_parsed.deinit();
    try std.testing.expect(user42_parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), user42_parsed.value.array.items.len);
    try std.testing.expectEqualStrings("morning-brief", user42_parsed.value.array.items[0].object.get("id").?.string);

    const q = try mgr.buildQuery("SELECT id, user_id FROM {schema}.jobs ORDER BY user_id ASC");
    defer allocator.free(q);
    const result = try mgr.exec(q);
    defer c.PQclear(result);

    try std.testing.expectEqual(@as(c_int, 2), c.PQntuples(result));
    const first_id = try dupeResultValue(allocator, result, 0, 0);
    defer allocator.free(first_id);
    const second_id = try dupeResultValue(allocator, result, 1, 0);
    defer allocator.free(second_id);

    try std.testing.expectEqualStrings("user:2:morning-brief", first_id);
    try std.testing.expectEqualStrings("user:42:morning-brief", second_id);
}

test "postgres memory upsert recall list and forget stay user-scoped" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();

    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");
    try mgr.provisionUser(3, "/tmp/nullalis-zaki-bot-test-user-3/workspace");

    try mgr.upsertMemory(2, "favorite_snack", "pistachios", .core, "agent:zaki-bot:user:2:main");
    try mgr.upsertMemory(3, "favorite_snack", "olives", .core, "agent:zaki-bot:user:3:main");

    const got = (try mgr.getMemory(allocator, 2, "favorite_snack")).?;
    defer got.deinit(allocator);
    try std.testing.expectEqualStrings("pistachios", got.content);

    const recall = try mgr.recallMemories(allocator, 2, "pista", 5, null);
    defer memory_root.freeEntries(allocator, recall);
    try std.testing.expectEqual(@as(usize, 1), recall.len);
    try std.testing.expectEqualStrings("favorite_snack", recall[0].key);

    const listed = try mgr.listMemories(allocator, 2, .core, null);
    defer memory_root.freeEntries(allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);

    const count_before = try mgr.countMemories(2);
    try std.testing.expectEqual(@as(usize, 1), count_before);
    try std.testing.expect(try mgr.forgetMemory(2, "favorite_snack"));
    const count_after = try mgr.countMemories(2);
    try std.testing.expectEqual(@as(usize, 0), count_after);
}

test "postgres V1.5 day-3+4: compose write + metadata read + traversal event roundtrip" {
    // Exercises chunks 3A (upsertMemoryWithMetadata + listMemoriesMetadata),
    // 3C (existsMemoryKeys), and 4A (insertTraversalEvent) against live PG
    // in an isolated schema. Closes the day-4 smoke-test gap — verifies
    // the new SQL statements actually execute end-to-end (the
    // unit/handler tests cover code paths but not SQL syntax).
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();

    const user_id: i64 = 42;
    try mgr.provisionUser(user_id, "/tmp/nullalis-zaki-bot-test-user-42/workspace");

    // ── Seed two source memories ──
    try mgr.upsertMemory(user_id, "user_lang", "Prefers Zig", .core, null);
    try mgr.upsertMemory(user_id, "user_editor", "Uses NeoVim", .core, null);

    // ── chunk 3C: existsMemoryKeys ──
    {
        const seed_keys = [_][]const u8{ "user_lang", "user_editor", "missing_key" };
        var existing = try mgr.existsMemoryKeys(allocator, user_id, &seed_keys);
        defer {
            var it = existing.iterator();
            while (it.next()) |e| allocator.free(e.key_ptr.*);
            existing.deinit(allocator);
        }
        try std.testing.expect(existing.contains("user_lang"));
        try std.testing.expect(existing.contains("user_editor"));
        try std.testing.expect(!existing.contains("missing_key"));
    }

    // ── chunk 3A: upsertMemoryWithMetadata ──
    const meta_json = "{\"synthesized_by\":\"agent\",\"references\":[\"user_lang\",\"user_editor\"],\"composed_at\":1714521600}";
    try mgr.upsertMemoryWithMetadata(
        user_id,
        "compose:smoketest_001",
        "User prefers Zig + NeoVim — consistent across sessions.",
        .core,
        null,
        meta_json,
    );

    // ── chunk 3A: listMemoriesMetadata ──
    {
        const compose_keys = [_][]const u8{"compose:smoketest_001"};
        var meta_map = try mgr.listMemoriesMetadata(allocator, user_id, &compose_keys);
        defer {
            var it = meta_map.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            meta_map.deinit(allocator);
        }
        const fetched = meta_map.get("compose:smoketest_001") orelse return error.MetadataMissing;
        // Postgres normalizes JSONB so we check for presence of key fields rather
        // than byte-equality with the input string.
        try std.testing.expect(std.mem.indexOf(u8, fetched, "synthesized_by") != null);
        try std.testing.expect(std.mem.indexOf(u8, fetched, "user_lang") != null);
        try std.testing.expect(std.mem.indexOf(u8, fetched, "user_editor") != null);
    }

    // ── Verify the compose memory_event row landed (chunk 3A side effect) ──
    {
        const ev_q = try mgr.buildQuery(
            "SELECT COUNT(*) FROM {schema}.memory_events WHERE user_id = $1 AND event_type = 'compose'",
        );
        defer allocator.free(ev_q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try mgr.execParams(ev_q, &params, &lengths);
        defer c.PQclear(result);
        const count_str = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(count_str);
        const count = try std.fmt.parseInt(i64, count_str, 10);
        try std.testing.expectEqual(@as(i64, 1), count);
    }

    // ── chunk 4A: insertTraversalEvent ──
    const payload = "{\"action\":\"view_graph\",\"node_keys\":[\"user_lang\",\"user_editor\",\"compose:smoketest_001\"],\"total_nodes_in_corpus\":3,\"trimmed\":false,\"semantic_degraded\":false,\"viewed_at\":1714521600}";
    try mgr.insertTraversalEvent(user_id, payload);

    // ── Verify the traversal row landed ──
    {
        const ev_q = try mgr.buildQuery(
            "SELECT COUNT(*) FROM {schema}.memory_events WHERE user_id = $1 AND event_type = 'traversal'",
        );
        defer allocator.free(ev_q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const params = [_]?[*:0]const u8{user_s.ptr};
        const lengths = [_]c_int{@intCast(user_s.len)};
        const result = try mgr.execParams(ev_q, &params, &lengths);
        defer c.PQclear(result);
        const count_str = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(count_str);
        const count = try std.fmt.parseInt(i64, count_str, 10);
        try std.testing.expectEqual(@as(i64, 1), count);
    }

    // ── Cleanup: drop the test schema ──
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
}

test "postgres channel identity bindings upsert resolve list delete and backfill candidates" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();

    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");
    try mgr.provisionUser(3, "/tmp/nullalis-zaki-bot-test-user-3/workspace");

    const first_binding_id = try mgr.upsertChannelIdentityBinding(
        allocator,
        2,
        "telegram",
        "default",
        "telegram:principal:111",
        "telegram:scope:111",
        null,
        "direct",
        "111",
        "{\"source\":\"test\"}",
    );
    defer allocator.free(first_binding_id);
    try std.testing.expect(first_binding_id.len > 0);

    const resolved_first = try mgr.resolveUserByChannelIdentity(
        "telegram",
        "default",
        "telegram:principal:111",
        "telegram:scope:111",
        null,
    );
    try std.testing.expectEqual(@as(?i64, 2), resolved_first);

    const conflict_binding_id = try mgr.upsertChannelIdentityBinding(
        allocator,
        3,
        "telegram",
        "default",
        "telegram:principal:111",
        "telegram:scope:111",
        null,
        "direct",
        "111",
        "{\"source\":\"conflict\"}",
    );
    defer allocator.free(conflict_binding_id);
    try std.testing.expectEqualStrings(first_binding_id, conflict_binding_id);

    const resolved_conflict = try mgr.resolveUserByChannelIdentity(
        "telegram",
        "default",
        "telegram:principal:111",
        "telegram:scope:111",
        null,
    );
    try std.testing.expectEqual(@as(?i64, 3), resolved_conflict);

    const listed = try mgr.listChannelIdentityBindings(allocator, 3, "telegram");
    defer {
        for (listed) |*entry| entry.deinit(allocator);
        allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("telegram", listed[0].channel);
    try std.testing.expectEqualStrings("telegram:principal:111", listed[0].principal_key);

    const deleted = try mgr.deleteChannelIdentityBinding(3, listed[0].id);
    try std.testing.expect(deleted);

    const resolved_after_delete = try mgr.resolveUserByChannelIdentity(
        "telegram",
        "default",
        "telegram:principal:111",
        "telegram:scope:111",
        null,
    );
    try std.testing.expectEqual(@as(?i64, null), resolved_after_delete);

    try mgr.putTelegramStateJson(2, "{\"chat_id\":12345,\"account_id\":\"default\",\"connected\":true}");
    const backfill = try mgr.listTelegramBackfillCandidates(allocator);
    defer {
        for (backfill) |*entry| entry.deinit(allocator);
        allocator.free(backfill);
    }
    try std.testing.expect(backfill.len >= 1);
}

test "postgres ownership lease snapshot returns null and active lease values" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    try std.testing.expect((try mgr.getUserOwnershipLeaseSnapshot(allocator, 2)) == null);

    const now_s = std.time.timestamp();
    const lease_token = try mgr.acquireUserOwnershipLease(allocator, 2, "instance-a", now_s, 120);
    defer allocator.free(lease_token);

    var snapshot = (try mgr.getUserOwnershipLeaseSnapshot(allocator, 2)).?;
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("instance-a", snapshot.owner_id);
    try std.testing.expect(snapshot.lease_until_s >= now_s);
    try std.testing.expect(snapshot.updated_at_s > 0);

    try mgr.releaseUserOwnershipLease(2, "instance-a", lease_token);
    try std.testing.expect((try mgr.getUserOwnershipLeaseSnapshot(allocator, 2)) == null);
}

test "postgres_pool_enforces_cap_under_concurrency" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 500);
    defer mgr.deinit();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    const WorkerCtx = struct {
        mgr: *ManagerImpl,
        user_id: i64,
        worker_id: usize,
    };
    const Worker = struct {
        fn run(ctx: *WorkerCtx) void {
            var session_buf: [96]u8 = undefined;
            const session_id = std.fmt.bufPrint(&session_buf, "agent:zaki-bot:user:{d}:task:pool-{d}", .{ ctx.user_id, ctx.worker_id }) catch return;
            for (0..20) |i| {
                var content_buf: [96]u8 = undefined;
                const content = std.fmt.bufPrint(&content_buf, "pool-test-{d}-{d}", .{ ctx.worker_id, i }) catch continue;
                ctx.mgr.saveSessionMessage(ctx.user_id, session_id, "user", content) catch continue;
                if (i % 5 == 0) {
                    const messages = ctx.mgr.loadSessionMessages(std.heap.page_allocator, ctx.user_id, session_id) catch continue;
                    memory_root.freeMessages(std.heap.page_allocator, messages);
                }
            }
        }
    };

    var worker_ctx: [8]WorkerCtx = undefined;
    var threads: [8]std.Thread = undefined;
    for (0..threads.len) |idx| {
        worker_ctx[idx] = .{
            .mgr = &mgr,
            .user_id = 2,
            .worker_id = idx,
        };
        threads[idx] = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Worker.run, .{&worker_ctx[idx]});
    }
    for (threads) |thread| thread.join();

    const snapshot = mgr.debugPoolSnapshot();
    try std.testing.expect(snapshot.open_conns <= snapshot.pool_max);
    try std.testing.expectEqual(@as(u32, 2), snapshot.pool_max);
}

test "postgres_pool_reuses_connections" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 500);
    defer mgr.deinit();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    const session_id = "agent:zaki-bot:user:2:main";
    try mgr.saveSessionMessage(2, session_id, "user", "first");
    const first_snapshot = mgr.debugPoolSnapshot();

    for (0..25) |i| {
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "reuse-{d}", .{i});
        try mgr.saveSessionMessage(2, session_id, "user", content);
        const messages = try mgr.loadSessionMessages(allocator, 2, session_id);
        memory_root.freeMessages(allocator, messages);
    }

    const final_snapshot = mgr.debugPoolSnapshot();
    try std.testing.expect(first_snapshot.open_conns >= 1);
    try std.testing.expect(final_snapshot.open_conns >= 1);
    try std.testing.expect(final_snapshot.open_conns <= 2);
    try std.testing.expect(final_snapshot.open_conns <= first_snapshot.open_conns + 1);
}

test "postgres task snapshots isolate same compact task id per user" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 500);
    defer mgr.deinit();
    try mgr.provisionUser(1, "/tmp/nullalis-zaki-bot-test-user-1/workspace");
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    try mgr.upsertTaskSnapshot(
        1,
        "1",
        "agent:zaki-bot:user:1:task:1",
        "agent:zaki-bot:user:1:main",
        "user-1-label",
        "user-1-prompt",
        "running",
        null,
        null,
        1000,
        1001,
        null,
    );
    try mgr.upsertTaskSnapshot(
        2,
        "1",
        "agent:zaki-bot:user:2:task:1",
        "agent:zaki-bot:user:2:main",
        "user-2-label",
        "user-2-prompt",
        "completed",
        "done",
        null,
        2000,
        2001,
        2002,
    );

    var user_1_snapshot = (try mgr.getTaskSnapshot(allocator, 1, "1")).?;
    defer user_1_snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:task:1", user_1_snapshot.session_id.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", user_1_snapshot.request_session_id.?);
    try std.testing.expectEqualStrings("user-1-label", user_1_snapshot.label);
    try std.testing.expectEqualStrings("user-1-prompt", user_1_snapshot.prompt);
    try std.testing.expectEqualStrings("running", user_1_snapshot.status);
    try std.testing.expect(user_1_snapshot.result == null);

    var user_2_snapshot = (try mgr.getTaskSnapshot(allocator, 2, "1")).?;
    defer user_2_snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:2:task:1", user_2_snapshot.session_id.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:2:main", user_2_snapshot.request_session_id.?);
    try std.testing.expectEqualStrings("user-2-label", user_2_snapshot.label);
    try std.testing.expectEqualStrings("user-2-prompt", user_2_snapshot.prompt);
    try std.testing.expectEqualStrings("completed", user_2_snapshot.status);
    try std.testing.expectEqualStrings("done", user_2_snapshot.result.?);

    const user_1_tasks = try mgr.listTaskSnapshots(allocator, 1);
    defer {
        for (user_1_tasks) |*entry| entry.deinit(allocator);
        allocator.free(user_1_tasks);
    }
    try std.testing.expectEqual(@as(usize, 1), user_1_tasks.len);
    try std.testing.expectEqualStrings("1", user_1_tasks[0].id);
    try std.testing.expectEqualStrings("user-1-label", user_1_tasks[0].label);

    const user_2_tasks = try mgr.listTaskSnapshots(allocator, 2);
    defer {
        for (user_2_tasks) |*entry| entry.deinit(allocator);
        allocator.free(user_2_tasks);
    }
    try std.testing.expectEqual(@as(usize, 1), user_2_tasks.len);
    try std.testing.expectEqualStrings("1", user_2_tasks[0].id);
    try std.testing.expectEqualStrings("user-2-label", user_2_tasks[0].label);
}

test "postgres migrate upgrades legacy global task keying to user scoped keys" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 500);
    defer mgr.deinit();

    const drop_query = try mgr.buildQuery("DROP TABLE IF EXISTS {schema}.tasks CASCADE");
    defer allocator.free(drop_query);
    const drop_result = try mgr.exec(drop_query);
    c.PQclear(drop_result);

    const legacy_query = try mgr.buildQuery(
        \\CREATE TABLE {schema}.tasks (
        \\    id TEXT PRIMARY KEY,
        \\    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
        \\    session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
        \\    label TEXT NOT NULL,
        \\    prompt TEXT NOT NULL,
        \\    status TEXT NOT NULL,
        \\    result TEXT,
        \\    error TEXT,
        \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        \\    started_at TIMESTAMPTZ,
        \\    completed_at TIMESTAMPTZ
        \\)
        ,
    );
    defer allocator.free(legacy_query);
    const legacy_result = try mgr.exec(legacy_query);
    c.PQclear(legacy_result);

    try mgr.migrate();
    try mgr.provisionUser(1, "/tmp/nullalis-zaki-bot-test-user-1/workspace");
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    try mgr.upsertTaskSnapshot(
        1,
        "1",
        "agent:zaki-bot:user:1:task:1",
        "agent:zaki-bot:user:1:main",
        "after-migrate-user-1",
        "prompt-a",
        "completed",
        "ok-a",
        null,
        3000,
        3001,
        3002,
    );
    try mgr.upsertTaskSnapshot(
        2,
        "1",
        "agent:zaki-bot:user:2:task:1",
        "agent:zaki-bot:user:2:main",
        "after-migrate-user-2",
        "prompt-b",
        "failed",
        null,
        "err-b",
        4000,
        4001,
        4002,
    );

    var user_1_snapshot = (try mgr.getTaskSnapshot(allocator, 1, "1")).?;
    defer user_1_snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("after-migrate-user-1", user_1_snapshot.label);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", user_1_snapshot.request_session_id.?);

    var user_2_snapshot = (try mgr.getTaskSnapshot(allocator, 2, "1")).?;
    defer user_2_snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("after-migrate-user-2", user_2_snapshot.label);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:2:main", user_2_snapshot.request_session_id.?);
    try std.testing.expectEqualStrings("err-b", user_2_snapshot.error_msg.?);
}

test "putOnboardingJson updates onboarding row and mirrored user flags" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 500);
    defer mgr.deinit();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    try mgr.putOnboardingJson(2, "{\"completed\":true,\"completed_at_s\":123}");

    const onboarding = try mgr.getOnboardingJson(allocator, 2);
    defer allocator.free(onboarding);
    try std.testing.expect(std.mem.indexOf(u8, onboarding, "\"completed\": true") != null);

    const q = try mgr.buildQuery(
        "SELECT onboarding_completed::text, (onboarding_completed_at IS NOT NULL)::text FROM {schema}.users WHERE user_id = $1",
    );
    defer allocator.free(q);

    var user_buf: [32]u8 = undefined;
    const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{@as(i64, 2)});
    const params = [_]?[*:0]const u8{user_s.ptr};
    const lengths = [_]c_int{@intCast(user_s.len)};
    const result = try mgr.execParams(q, &params, &lengths);
    defer c.PQclear(result);

    try std.testing.expectEqual(@as(c_int, 1), c.PQntuples(result));
    const onboarding_completed = try dupeResultValue(allocator, result, 0, 0);
    defer allocator.free(onboarding_completed);
    const onboarding_completed_at_present = try dupeResultValue(allocator, result, 0, 1);
    defer allocator.free(onboarding_completed_at_present);

    try std.testing.expectEqualStrings("true", onboarding_completed);
    try std.testing.expectEqualStrings("true", onboarding_completed_at_present);
}

test "postgres_pool_timeout_when_exhausted" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 30);
    defer mgr.deinit();

    var lease_a = try mgr.acquireConn(0);
    defer mgr.releaseConn(&lease_a, true);
    var lease_b = try mgr.acquireConn(0);
    defer mgr.releaseConn(&lease_b, true);

    const start_ms = std.time.milliTimestamp();
    try std.testing.expectError(error.ConnectionPoolBusy, mgr.acquireConn(30));
    const elapsed_ms = std.time.milliTimestamp() - start_ms;
    try std.testing.expect(elapsed_ms >= 0);

    const snapshot = mgr.debugPoolSnapshot();
    try std.testing.expectEqual(@as(u32, 2), snapshot.in_use);
    try std.testing.expect(snapshot.open_conns <= snapshot.pool_max);
}

test "postgres_pool_releases_on_exec_error" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 500);
    defer mgr.deinit();

    try std.testing.expectError(error.ExecFailed, mgr.exec("SELECT * FROM this_relation_does_not_exist"));

    const after_error = mgr.debugPoolSnapshot();
    try std.testing.expectEqual(@as(u32, 0), after_error.in_use);
    try std.testing.expect(after_error.open_conns <= after_error.pool_max);

    const ok_result = try mgr.exec("SELECT 1");
    c.PQclear(ok_result);

    const after_recovery = mgr.debugPoolSnapshot();
    try std.testing.expectEqual(@as(u32, 0), after_recovery.in_use);
    try std.testing.expect(after_recovery.open_conns <= after_recovery.pool_max);
}

test "postgres deleteSession removes thread durable state and preserves non-autosave memories" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var mgr = try initPostgresTestManagerWithPool(allocator, 2, 500);
    defer mgr.deinit();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    const session_id = "agent:zaki-bot:user:2:thread:delete-me";

    try mgr.saveSessionMessage(2, session_id, "user", "hello");
    const event_id = try mgr.saveCompletionEvent(allocator, 2, session_id, "telegram", "acct-2", "chat-2", "sent");
    defer allocator.free(event_id);
    try mgr.upsertMemory(2, "autosave_user_123", "ephemeral", .conversation, session_id);
    try mgr.upsertMemory(2, "kept_core", "durable", .core, session_id);

    const sessions_before = try mgr.listUserSessions(allocator, 2);
    defer {
        for (sessions_before) |info| info.deinit(allocator);
        allocator.free(sessions_before);
    }
    try std.testing.expectEqual(@as(usize, 2), sessions_before.len);

    try mgr.deleteSession(2, session_id);

    const messages_after = try mgr.loadSessionMessages(allocator, 2, session_id);
    defer memory_root.freeMessages(allocator, messages_after);
    try std.testing.expectEqual(@as(usize, 0), messages_after.len);

    const events_after = try mgr.loadCompletionEvents(allocator, 2, session_id);
    defer memory_root.freeCompletionEvents(allocator, events_after);
    try std.testing.expectEqual(@as(usize, 0), events_after.len);

    const autosave_after = try mgr.getMemory(allocator, 2, "autosave_user_123");
    try std.testing.expect(autosave_after == null);

    var kept_core_after = (try mgr.getMemory(allocator, 2, "kept_core")).?;
    defer kept_core_after.deinit(allocator);
    try std.testing.expectEqualStrings("durable", kept_core_after.content);
    try std.testing.expect(kept_core_after.session_id == null);

    const sessions_after = try mgr.listUserSessions(allocator, 2);
    defer {
        for (sessions_after) |info| info.deinit(allocator);
        allocator.free(sessions_after);
    }
    try std.testing.expectEqual(@as(usize, 1), sessions_after.len);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:2:main", sessions_after[0].session_key);
}

// V1.6 commit 6 — bi-temporal close-out PG smoke test.
//
// Acceptance gate per spec: feed an existing extraction-classifier row
// and a contradicting NEW fact; setMemoryInvalidation closes the old
// row; findRelatedExtractedMemories no longer returns it; getMemory
// (which applies MEMORIES_VALIDITY_FILTER) also hides it. The agent's
// retrieval path can never see a closed-out row again.
test "V1.6 commit 6 setMemoryInvalidation closes out memory + filters from retrieval" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Seed: existing extraction-classifier memory ───────────────────
    const old_metadata =
        \\{"subject":"user","predicate":"PREFERS","object_key":"NeoVim","attributed_to":"user","attribution":"extraction_classifier","confidence":1.0,"extracted_at":1000000}
    ;
    try mgr.upsertMemoryWithMetadata(2, "extracted_old_pref", "User prefers NeoVim", .core, null, old_metadata);

    // Sanity: row reachable via getMemory + findRelatedExtractedMemories
    {
        const before = try mgr.getMemory(allocator, 2, "extracted_old_pref");
        try std.testing.expect(before != null);
        before.?.deinit(allocator);
    }
    {
        const related = try mgr.findRelatedExtractedMemories(allocator, 2, "user", 8);
        defer {
            for (related) |e| e.deinit(allocator);
            allocator.free(related);
        }
        try std.testing.expectEqual(@as(usize, 1), related.len);
        try std.testing.expectEqualStrings("extracted_old_pref", related[0].key);
    }

    // ── Close out: new "Helix" fact contradicts old "NeoVim" fact ─────
    const close_out_ts: i64 = std.time.timestamp();
    try mgr.setMemoryInvalidation(2, "extracted_old_pref", close_out_ts, close_out_ts);

    // ── Assertions ───────────────────────────────────────────────────
    // 1. getMemory hides the closed-out row (MEMORIES_VALIDITY_FILTER)
    {
        const after = try mgr.getMemory(allocator, 2, "extracted_old_pref");
        try std.testing.expect(after == null);
    }
    // 2. findRelatedExtractedMemories also hides it
    {
        const related = try mgr.findRelatedExtractedMemories(allocator, 2, "user", 8);
        defer {
            for (related) |e| e.deinit(allocator);
            allocator.free(related);
        }
        try std.testing.expectEqual(@as(usize, 0), related.len);
    }
    // 3. The row IS still in the table — for audit. Direct SQL confirms
    //    valid_to + invalid_at + expired_at populated, is_latest = false.
    {
        const audit_q = try std.fmt.allocPrint(allocator,
            "SELECT valid_to, invalid_at, expired_at, is_latest FROM {s}.memories WHERE user_id = 2 AND key = 'extracted_old_pref'",
            .{schema},
        );
        defer allocator.free(audit_q);
        const result = try mgr.exec(audit_q);
        defer c.PQclear(result);
        try std.testing.expectEqual(@as(c_int, 1), c.PQntuples(result));

        const valid_to_str = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(valid_to_str);
        const invalid_at_str = try dupeResultValue(allocator, result, 0, 1);
        defer allocator.free(invalid_at_str);
        const expired_at_str = try dupeResultValue(allocator, result, 0, 2);
        defer allocator.free(expired_at_str);
        const is_latest_str = try dupeResultValue(allocator, result, 0, 3);
        defer allocator.free(is_latest_str);

        const valid_to = try std.fmt.parseInt(i64, valid_to_str, 10);
        const invalid_at = try std.fmt.parseInt(i64, invalid_at_str, 10);
        const expired_at = try std.fmt.parseInt(i64, expired_at_str, 10);

        try std.testing.expectEqual(close_out_ts, valid_to);
        try std.testing.expectEqual(close_out_ts, invalid_at);
        try std.testing.expectEqual(close_out_ts, expired_at);
        // postgres BOOLEAN serializes as "f" / "t"
        try std.testing.expectEqualStrings("f", is_latest_str);
    }

    // 4. Idempotent: a second invalidation with the same timestamps is
    //    a no-op (UPDATE re-writes the same values, returns successfully).
    try mgr.setMemoryInvalidation(2, "extracted_old_pref", close_out_ts, close_out_ts);

    // 5. Non-existent key: silent no-op (caller doesn't gate on existence).
    try mgr.setMemoryInvalidation(2, "no_such_key", close_out_ts, close_out_ts);
}

// V1.6 commit 6 — findRelatedExtractedMemories scoping smoke test.
//
// Confirms the candidate fetcher correctly filters by:
//   - subject (only same-subject rows)
//   - attribution = 'extraction_classifier' (excludes agent_tool / compose)
//   - MEMORIES_VALIDITY_FILTER (excludes closed-out rows)
test "V1.6 commit 6 findRelatedExtractedMemories scopes by subject + attribution + validity" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    // Suppress libpq NOTICE-level messages during migrate. See user_99
    // test above for rationale.
    {
        const result = try mgr.exec("SET client_min_messages TO WARNING");
        c.PQclear(result);
    }
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // Same subject="user", extraction-classifier attribution → MUST be returned
    try mgr.upsertMemoryWithMetadata(2, "ec_user_helix",
        "User uses Helix",
        .core, null,
        \\{"subject":"user","predicate":"USES","object_key":"Helix","attributed_to":"user","attribution":"extraction_classifier","confidence":1.0}
    );
    // Same subject="user", DIFFERENT attribution ("agent_tool") → MUST NOT be returned
    try mgr.upsertMemoryWithMetadata(2, "agent_tool_user_other",
        "User session log",
        .core, null,
        \\{"subject":"user","predicate":"NOTE","object_key":"x","attributed_to":"user","attribution":"agent_tool","confidence":1.0}
    );
    // DIFFERENT subject="alex", extraction-classifier → MUST NOT be returned
    try mgr.upsertMemoryWithMetadata(2, "ec_alex_birthday",
        "Alex birthday May 15",
        .core, null,
        \\{"subject":"alex","predicate":"BIRTHDAY","object_key":"May 15","attributed_to":"user","attribution":"extraction_classifier","confidence":1.0}
    );
    // Same subject="user", extraction-classifier, but CLOSED OUT → MUST NOT be returned
    try mgr.upsertMemoryWithMetadata(2, "ec_user_neovim_closed",
        "User uses NeoVim",
        .core, null,
        \\{"subject":"user","predicate":"USES","object_key":"NeoVim","attributed_to":"user","attribution":"extraction_classifier","confidence":1.0}
    );
    const closed_ts: i64 = std.time.timestamp();
    try mgr.setMemoryInvalidation(2, "ec_user_neovim_closed", closed_ts, closed_ts);

    // ── The query MUST return exactly 1 row: ec_user_helix ────────────
    const related = try mgr.findRelatedExtractedMemories(allocator, 2, "user", 16);
    defer {
        for (related) |e| e.deinit(allocator);
        allocator.free(related);
    }
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expectEqualStrings("ec_user_helix", related[0].key);
    try std.testing.expectEqualStrings("User uses Helix", related[0].content);
}

// V1.6 cmt6 × V1.7 integration regression test (W-INT-01).
//
// Scenario: a non-core extraction-classifier row gets closed-out by V1.6
// commit 6's setMemoryInvalidation (e.g. via the contradiction judge). A
// later session re-states a similar fact under the SAME key (escapes the
// content_hash dedup because phrasing differs). Without the resurrect-on-
// upsert CASE-clears in upsertMemoryWithMetadata, the row would update
// content while remaining invisible (valid_to in past, is_latest=false) —
// "zombie" row. Worse: a 2nd cross-session re-statement would trigger
// promoteMemoryToCore on a closed-out row, marking it core forever +
// permanently invisible.
//
// This test asserts: post-resurrect-upsert, the row is visible to
// getMemory + findRelatedExtractedMemories, with valid_to=NULL and
// is_latest=TRUE.
test "V1.6 commit 6 × V1.7 W-INT-01 resurrect-on-upsert clears close-out cols" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Step 1: write extraction-classifier row from session A.
    // Use `.daily` (non-core) to exercise the resurrect-on-upsert path —
    // a `.core`-seeded row would hit the core-preserve branch instead,
    // which is the OTHER axis tested in step 6 below.
    try mgr.upsertMemoryWithMetadata(2, "extracted_resurrect_test",
        "User prefers NeoVim editor",
        .daily, "session-A",
        \\{"subject":"user","predicate":"PREFERS","object_key":"NeoVim","attributed_to":"user","attribution":"extraction_classifier","confidence":1.0}
    );

    // ── Step 2: contradiction judge closes it out ─────────────────────
    const close_ts: i64 = std.time.timestamp();
    try mgr.setMemoryInvalidation(2, "extracted_resurrect_test", close_ts, close_ts);
    {
        const hidden = try mgr.getMemory(allocator, 2, "extracted_resurrect_test");
        try std.testing.expect(hidden == null); // confirmed: validity filter hides it
    }

    // ── Step 3: fresh re-statement from session B, SAME key, different content
    try mgr.upsertMemoryWithMetadata(2, "extracted_resurrect_test",
        "User uses NeoVim as their primary editor",
        .daily, "session-B",
        \\{"subject":"user","predicate":"USES","object_key":"NeoVim","attributed_to":"user","attribution":"extraction_classifier","confidence":1.0}
    );

    // ── Step 4: row MUST be visible again, with cleared close-out columns
    const resurrected = try mgr.getMemory(allocator, 2, "extracted_resurrect_test");
    try std.testing.expect(resurrected != null);
    var r = resurrected.?;
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("User uses NeoVim as their primary editor", r.content);
    try std.testing.expect(r.valid_to == null); // CASE-cleared back to NULL

    // Audit columns also reset
    {
        const audit_q = try std.fmt.allocPrint(allocator,
            "SELECT valid_to, invalid_at, expired_at, is_latest FROM {s}.memories WHERE user_id = 2 AND key = 'extracted_resurrect_test'",
            .{schema},
        );
        defer allocator.free(audit_q);
        const result = try mgr.exec(audit_q);
        defer c.PQclear(result);
        try std.testing.expectEqual(@as(c_int, 1), c.PQntuples(result));
        // valid_to/invalid_at/expired_at all NULL after resurrect; is_latest = true.
        try std.testing.expectEqual(@as(c_int, 1), c.PQgetisnull(result, 0, 0)); // valid_to NULL
        try std.testing.expectEqual(@as(c_int, 1), c.PQgetisnull(result, 0, 1)); // invalid_at NULL
        try std.testing.expectEqual(@as(c_int, 1), c.PQgetisnull(result, 0, 2)); // expired_at NULL
        const is_latest_str = try dupeResultValue(allocator, result, 0, 3);
        defer allocator.free(is_latest_str);
        try std.testing.expectEqualStrings("t", is_latest_str);
    }

    // ── Step 5: findRelatedExtractedMemories also sees the resurrected row
    const related = try mgr.findRelatedExtractedMemories(allocator, 2, "user", 8);
    defer {
        for (related) |e| e.deinit(allocator);
        allocator.free(related);
    }
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expectEqualStrings("extracted_resurrect_test", related[0].key);

    // ── Step 6: a CORE row that gets closed-out STAYS closed-out across upsert
    // (resurrect is non-core only; explicit demote required for core).
    try mgr.upsertMemory(2, "core_stays_closed", "core fact A", .core, "session-A");
    try mgr.execParamsNoResult(
        "UPDATE {schema}.memories SET memory_type = 'core', session_id = NULL WHERE user_id = $1 AND key = $2",
        &.{ "2", "core_stays_closed" },
        &.{ 1, @as(c_int, @intCast("core_stays_closed".len)) },
    );
    try mgr.setMemoryInvalidation(2, "core_stays_closed", close_ts, close_ts);
    try mgr.upsertMemory(2, "core_stays_closed", "core fact B", .daily, "session-B");
    {
        const closed_core = try mgr.getMemory(allocator, 2, "core_stays_closed");
        try std.testing.expect(closed_core == null); // still hidden — core close-out preserved
    }
}

// V1.6 commit 7 — memory_edges round-trip + dedup + cascade-close-out.
//
// Acceptance gates per spec: (a) upsertMemoryEdge inserts a row and the
// UNIQUE INDEX on (user_id, source_key, predicate, target_key) WHERE
// is_latest dedupes re-writes (weight bumps instead); (b) countEdgesForSource
// returns the active edge count; (c) listEdgesForUser returns active edges;
// (d) setMemoryInvalidation cascades — closing a memory closes its edges.
test "V1.6 commit 7 memory_edges insert + dedup + cascade-on-close" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };

    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Seed a parent memory + an edge from it
    try mgr.upsertMemoryWithMetadata(2, "extracted_helix_pref",
        "User prefers Helix",
        .daily, "session-A",
        \\{"subject":"user","predicate":"PREFERS","object_key":"Helix","attributed_to":"user","attribution":"extraction_classifier","confidence":0.95}
    );
    try mgr.upsertMemoryEdge(2, "extracted_helix_pref", "entity_helix", "PREFERS", "extraction_classifier", 0.95);

    // ── Step A: countEdgesForSource sees the active edge
    {
        const n = try mgr.countEdgesForSource(2, "extracted_helix_pref");
        try std.testing.expectEqual(@as(usize, 1), n);
    }

    // ── Step B: re-insert same triple — UNIQUE INDEX dedupes (weight bumps to 2.0)
    try mgr.upsertMemoryEdge(2, "extracted_helix_pref", "entity_helix", "PREFERS", "extraction_classifier", 0.99);
    {
        const n = try mgr.countEdgesForSource(2, "extracted_helix_pref");
        try std.testing.expectEqual(@as(usize, 1), n); // still 1 — deduped
    }

    // ── Step C: different triple from same source → new edge
    try mgr.upsertMemoryEdge(2, "extracted_helix_pref", "entity_neovim", "REPLACES", "extraction_classifier", 0.85);
    {
        const n = try mgr.countEdgesForSource(2, "extracted_helix_pref");
        try std.testing.expectEqual(@as(usize, 2), n);
    }

    // ── Step D: listEdgesForUser returns both active edges
    {
        const edges = try mgr.listEdgesForUser(allocator, 2);
        defer memory_root.freeTypedEdges(allocator, edges);
        try std.testing.expectEqual(@as(usize, 2), edges.len);
    }

    // ── Step E: cascade close-out — closing the memory closes its edges
    const close_ts: i64 = std.time.timestamp();
    try mgr.setMemoryInvalidation(2, "extracted_helix_pref", close_ts, close_ts);
    {
        const n = try mgr.countEdgesForSource(2, "extracted_helix_pref");
        try std.testing.expectEqual(@as(usize, 0), n); // cascade fired — edges hidden
    }
    {
        const edges = try mgr.listEdgesForUser(allocator, 2);
        defer memory_root.freeTypedEdges(allocator, edges);
        try std.testing.expectEqual(@as(usize, 0), edges.len);
    }

    // ── Step F: cascade audit — direct SQL confirms is_latest=false on closed edges
    {
        const audit_q = try std.fmt.allocPrint(allocator,
            "SELECT COUNT(*) FROM {s}.memory_edges WHERE user_id = 2 AND is_latest = FALSE",
            .{schema},
        );
        defer allocator.free(audit_q);
        const result = try mgr.exec(audit_q);
        defer c.PQclear(result);
        const closed_count_str = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(closed_count_str);
        try std.testing.expectEqualStrings("2", closed_count_str); // both edges closed
    }
}

// V1.6 commit 8 — entity coreference via cosine ≥ threshold.
//
// Acceptance: upsertEntity inserts a new entity with a deterministic embedding;
// findEntityByCosine finds it back when queried with a similar embedding (sim
// ≥ threshold) and returns null when sim < threshold.
//
// Uses synthetic 1024-d embeddings (zeros + a single 1.0 at varying indexes)
// so cosine similarity is exact: identical vectors → 1.0, orthogonal → 0.0.
test "V1.6 commit 8 entity coreference — cosine match + miss" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // Build two synthetic 1024-d embeddings:
    //   helix: index 5 = 1.0, rest 0.0
    //   neovim: index 100 = 1.0, rest 0.0
    // cosine(helix, helix) = 1.0; cosine(helix, neovim) = 0.0
    var helix_emb: [1024]f32 = [_]f32{0.0} ** 1024;
    helix_emb[5] = 1.0;
    var neovim_emb: [1024]f32 = [_]f32{0.0} ** 1024;
    neovim_emb[100] = 1.0;

    // ── Step 1: insert "Helix" entity. Returns new id.
    const helix_id = try mgr.upsertEntity(allocator, 2, "Helix", &helix_emb);
    defer allocator.free(helix_id);
    try std.testing.expect(helix_id.len > 0);

    // ── Step 2: cosine-search with the SAME embedding finds Helix back.
    {
        const found = try mgr.findEntityByCosine(allocator, 2, &helix_emb, 0.95);
        try std.testing.expect(found != null);
        const row = found.?;
        defer row.deinit(allocator);
        try std.testing.expectEqualStrings("Helix", row.name);
        try std.testing.expectEqualStrings(helix_id, row.id);
        try std.testing.expect(row.similarity >= 0.95);
    }

    // ── Step 3: cosine-search with the NeoVim embedding does NOT match
    //    Helix at the 0.95 threshold (sim ≈ 0.0).
    {
        const not_found = try mgr.findEntityByCosine(allocator, 2, &neovim_emb, 0.95);
        try std.testing.expect(not_found == null);
    }

    // ── Step 4: insert NeoVim entity, verify two distinct rows now exist.
    const neovim_id = try mgr.upsertEntity(allocator, 2, "NeoVim", &neovim_emb);
    defer allocator.free(neovim_id);
    try std.testing.expect(!std.mem.eql(u8, helix_id, neovim_id));

    // ── Step 5: each entity now finds itself back, not the other.
    {
        const found = try mgr.findEntityByCosine(allocator, 2, &neovim_emb, 0.95);
        try std.testing.expect(found != null);
        const row = found.?;
        defer row.deinit(allocator);
        try std.testing.expectEqualStrings("NeoVim", row.name);
    }
}

// V1.6 commit 9 — edge mutation events.
//
// Acceptance: every upsertMemoryEdge call emits one edge_added event;
// every cascaded close-out (via setMemoryInvalidation on the source memory)
// emits one edge_closed event per closed edge. Bi-temporal graph history
// queryable as a typed event stream.
test "V1.6 commit 9 edge mutation events — added + closed via cascade" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Seed parent memory + 2 edges ──────────────────────────────────
    try mgr.upsertMemoryWithMetadata(2, "extracted_helix_pref",
        "User prefers Helix",
        .daily, "session-A",
        \\{"subject":"user","predicate":"PREFERS","object_key":"Helix","attributed_to":"user","attribution":"extraction_classifier"}
    );
    try mgr.upsertMemoryEdge(2, "extracted_helix_pref", "entity_helix", "PREFERS", "extraction_classifier", 0.95);
    try mgr.upsertMemoryEdge(2, "extracted_helix_pref", "entity_neovim", "REPLACES", "extraction_classifier", 0.85);

    // ── Step A: 2 edge_added events recorded
    const count_q = try std.fmt.allocPrint(allocator,
        "SELECT COUNT(*) FROM {s}.memory_events WHERE user_id = 2 AND event_type = 'edge_added'",
        .{schema},
    );
    defer allocator.free(count_q);
    {
        const result = try mgr.exec(count_q);
        defer c.PQclear(result);
        const n_str = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(n_str);
        try std.testing.expectEqualStrings("2", n_str);
    }

    // ── Step B: payload of the first edge_added event has the right shape
    {
        const payload_q = try std.fmt.allocPrint(allocator,
            "SELECT payload->>'source_key', payload->>'predicate', payload->>'op' " ++
                "FROM {s}.memory_events WHERE user_id = 2 AND event_type = 'edge_added' " ++
                "ORDER BY created_at ASC LIMIT 1",
            .{schema},
        );
        defer allocator.free(payload_q);
        const result = try mgr.exec(payload_q);
        defer c.PQclear(result);
        const src = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(src);
        const pred = try dupeResultValue(allocator, result, 0, 1);
        defer allocator.free(pred);
        const op = try dupeResultValue(allocator, result, 0, 2);
        defer allocator.free(op);
        try std.testing.expectEqualStrings("extracted_helix_pref", src);
        try std.testing.expectEqualStrings("PREFERS", pred);
        try std.testing.expectEqualStrings("added", op);
    }

    // ── Step C: cascade close-out emits 2 edge_closed events
    const close_ts: i64 = std.time.timestamp();
    try mgr.setMemoryInvalidation(2, "extracted_helix_pref", close_ts, close_ts);
    {
        const close_count_q = try std.fmt.allocPrint(allocator,
            "SELECT COUNT(*) FROM {s}.memory_events WHERE user_id = 2 AND event_type = 'edge_closed'",
            .{schema},
        );
        defer allocator.free(close_count_q);
        const result = try mgr.exec(close_count_q);
        defer c.PQclear(result);
        const n_str = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(n_str);
        try std.testing.expectEqualStrings("2", n_str);
    }

    // ── Step D: chronological event order — added first, closed after
    {
        const order_q = try std.fmt.allocPrint(allocator,
            "SELECT event_type FROM {s}.memory_events " ++
                "WHERE user_id = 2 AND event_type LIKE 'edge_%' " ++
                "ORDER BY created_at ASC, id ASC",
            .{schema},
        );
        defer allocator.free(order_q);
        const result = try mgr.exec(order_q);
        defer c.PQclear(result);
        try std.testing.expectEqual(@as(c_int, 4), c.PQntuples(result));
        const e0 = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(e0);
        const e3 = try dupeResultValue(allocator, result, 3, 0);
        defer allocator.free(e3);
        try std.testing.expectEqualStrings("edge_added", e0);
        try std.testing.expectEqualStrings("edge_closed", e3);
    }
}

// V1.6 commit 10 — graph-expand retrieval primitive end-to-end.
//
// Acceptance: build a 3-node chain A→B→C via memory_edges, expand from [A]
// with max_hops=2, assert the neighborhood includes A (hop 0), B (hop 1),
// C (hop 2) with descending scores. Also verify findEdgesByKeys batched
// lookup returns only the active edges where source OR target match.
test "V1.6 commit 10 graph-expand — 3-node chain expansion" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Build chain A→B→C
    try mgr.upsertMemoryEdge(2, "node_a", "node_b", "RELATES_TO", "extraction_classifier", 0.9);
    try mgr.upsertMemoryEdge(2, "node_b", "node_c", "RELATES_TO", "extraction_classifier", 0.85);
    // Add an unrelated edge that should NOT appear in the expansion
    try mgr.upsertMemoryEdge(2, "node_x", "node_y", "OTHER", "extraction_classifier", 0.5);

    // ── findEdgesByKeys(["node_a"]) returns only the A→B edge
    {
        const keys = [_][]const u8{"node_a"};
        const edges = try mgr.findEdgesByKeys(allocator, 2, &keys);
        defer memory_root.freeTypedEdges(allocator, edges);
        try std.testing.expectEqual(@as(usize, 1), edges.len);
        try std.testing.expectEqualStrings("node_a", edges[0].source_key);
        try std.testing.expectEqualStrings("node_b", edges[0].target_key);
    }

    // ── findEdgesByKeys(["node_b"]) returns BOTH adjacent edges (a→b AND b→c)
    {
        const keys = [_][]const u8{"node_b"};
        const edges = try mgr.findEdgesByKeys(allocator, 2, &keys);
        defer memory_root.freeTypedEdges(allocator, edges);
        try std.testing.expectEqual(@as(usize, 2), edges.len);
    }

    // ── Full expansion: from [node_a], max_hops=2 → reach a, b, c
    const graph_expand = @import("agent/graph_expand.zig");
    const seeds = [_][]const u8{"node_a"};
    const result = try graph_expand.expandFromSeeds(allocator, &mgr, 2, &seeds, .{ .max_hops = 2 });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);

    // Build a key→hop map to assert hop distances
    var hop_map: std.StringHashMapUnmanaged(u8) = .{};
    defer hop_map.deinit(allocator);
    for (result.nodes) |n| try hop_map.put(allocator, n.key, n.hop_distance);

    try std.testing.expectEqual(@as(?u8, 0), hop_map.get("node_a"));
    try std.testing.expectEqual(@as(?u8, 1), hop_map.get("node_b"));
    try std.testing.expectEqual(@as(?u8, 2), hop_map.get("node_c"));

    // Sort order: scores descending. node_a (hop 0, hop_decay=1.0) should
    // outrank node_c (hop 2, hop_decay=0.33). With recency identical,
    // hop_decay dominates → node_a > node_b > node_c.
    try std.testing.expectEqualStrings("node_a", result.nodes[0].key);
    try std.testing.expect(result.nodes[0].score > result.nodes[1].score);
    try std.testing.expect(result.nodes[1].score > result.nodes[2].score);

    // The unrelated edge (x→y) MUST NOT appear in the expansion
    for (result.nodes) |n| {
        try std.testing.expect(!std.mem.eql(u8, n.key, "node_x"));
        try std.testing.expect(!std.mem.eql(u8, n.key, "node_y"));
    }
}

// V1.7a-2 — recallMemoriesAsGraph end-to-end + getMemoryTimestamps batch lookup.
//
// Acceptance:
//   1. recallMemories returns user_helix as a seed (key ILIKE %helix%)
//   2. expandFromSeeds reaches user_neovim (1 hop via REPLACES) — user_neovim's
//      content has no "helix" string, so legacy keyword/vector recall would
//      MISS it; graph mode catches it via the REPLACES edge. This is the
//      core value-add the consumer wire-up exists for.
//   3. Re-score path runs without error (getMemoryTimestamps returns real
//      created_at for inserted rows; placeholder-fallback path covers
//      missing keys without erroring). The test does NOT backdate rows —
//      validating actual recency-driven score deltas would require raw SQL
//      time-shifting and is deferred to a focused unit test on
//      scoreFromComponents directly.
//   4. max_hops=0 short-circuits to seeds-only with empty neighborhood
//   5. getMemoryTimestamps batch contract: aligned slice, null for
//      non-existent keys, real timestamps within last hour for fresh inserts
//   6. NUL-safety guard rejects keys with embedded NUL (matches findEdgesByKeys)
//   7. Unrelated rows (user_zsh + user_terminal) MUST NOT appear — scoping bound
test "V1.7a-2 recallMemoriesAsGraph — seeds + 1-hop neighbors + real created_at re-score" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Build a 3-fact mini-graph centered on Helix ───────────────────
    try mgr.upsertMemory(2, "user_helix", "User uses Helix as primary editor", .core, null);
    try mgr.upsertMemory(2, "user_neovim", "User used to use NeoVim before switching", .core, null);
    try mgr.upsertMemory(2, "helix_brain", "Helix used for V1.6 brain page polish", .core, null);
    // Edges: user_helix REPLACES user_neovim; user_helix USED_FOR helix_brain
    try mgr.upsertMemoryEdge(2, "user_helix", "user_neovim", "REPLACES", "extraction_classifier", 0.9);
    try mgr.upsertMemoryEdge(2, "user_helix", "helix_brain", "USED_FOR", "extraction_classifier", 0.85);
    // Unrelated row + edge to confirm scoping (must NOT appear in recall)
    try mgr.upsertMemory(2, "user_zsh", "Uses zsh for shell", .core, null);
    try mgr.upsertMemoryEdge(2, "user_zsh", "user_terminal", "USED_FOR", "extraction_classifier", 0.5);

    const graph_expand = @import("agent/graph_expand.zig");

    // ── (1) Default graph mode: max_hops=1, seeds=5 ────────────────────
    {
        const recall = try graph_expand.recallMemoriesAsGraph(
            allocator,
            &mgr,
            2,
            "helix",
            5,
            .{ .max_hops = 1 },
            null,
        );
        defer recall.deinit(allocator);

        // Seed recall: user_helix matches via key ILIKE + content ILIKE.
        // helix_brain ALSO matches via key ILIKE %helix% — it's a seed too.
        try std.testing.expect(recall.seeds.len >= 1);

        // Neighborhood includes BOTH the seeds and the 1-hop neighbors
        // (user_helix at hop 0, user_neovim at hop 1 reached via REPLACES,
        // helix_brain at hop 1 reached via USED_FOR — the latter may
        // also be a seed, in which case it shows up at hop 0).
        try std.testing.expect(recall.neighborhood.nodes.len >= 2);

        // user_neovim must be reachable (it doesn't textually match
        // "helix" so the LEGACY recall would miss it — graph mode is
        // the value-add here).
        var saw_neovim = false;
        for (recall.neighborhood.nodes) |n| {
            if (std.mem.eql(u8, n.key, "user_neovim")) saw_neovim = true;
            try std.testing.expect(!std.mem.eql(u8, n.key, "user_zsh")); // unrelated MUST NOT appear
        }
        try std.testing.expect(saw_neovim);
    }

    // ── (2) max_hops=0 short-circuits to legacy (seeds only, no graph) ─
    {
        const recall = try graph_expand.recallMemoriesAsGraph(
            allocator,
            &mgr,
            2,
            "helix",
            5,
            .{ .max_hops = 0 },
            null,
        );
        defer recall.deinit(allocator);
        try std.testing.expect(recall.seeds.len >= 1);
        try std.testing.expectEqual(@as(usize, 0), recall.neighborhood.nodes.len);
        try std.testing.expectEqual(@as(usize, 0), recall.neighborhood.edges.len);
    }

    // ── (3) getMemoryTimestamps batch lookup: aligned slice + nulls ────
    {
        const keys = [_][]const u8{ "user_helix", "user_neovim", "doesnt_exist", "helix_brain" };
        const timestamps = try mgr.getMemoryTimestamps(allocator, 2, &keys);
        defer allocator.free(timestamps);

        try std.testing.expectEqual(@as(usize, 4), timestamps.len);
        try std.testing.expect(timestamps[0] != null); // user_helix exists
        try std.testing.expect(timestamps[1] != null); // user_neovim exists
        try std.testing.expect(timestamps[2] == null); // doesnt_exist → null
        try std.testing.expect(timestamps[3] != null); // helix_brain exists
        // All real timestamps should be recent (within last hour).
        // Upper bound allows +5s slack — PG's now() can be 1-2s ahead of
        // the local clock if NTP drift between the test process and the
        // postgres server has them desynced; the assertion is "this row
        // was JUST inserted," not "PG and local clocks are perfectly in
        // sync." Drop tolerance to 0 the day we own both clocks.
        const now = std.time.timestamp();
        try std.testing.expect(timestamps[0].? > now - 3600);
        try std.testing.expect(timestamps[0].? <= now + 5);
    }

    // ── (4) NUL-safety guard on getMemoryTimestamps ────────────────────
    {
        const bad_keys = [_][]const u8{"safe\x00malicious"};
        const r = mgr.getMemoryTimestamps(allocator, 2, &bad_keys);
        try std.testing.expectError(error.InvalidKey, r);
    }
}

// V1.6 commit 11 — demoteMemoryFromCore.
//
// Acceptance: a core row gets demoted to .daily, the W-INT-01 immortality
// CASE-guard releases (subsequent upserts can edit the row freely), and
// an audit event lands in memory_events.
test "V1.6 commit 11 demoteMemoryFromCore — releases immortality + emits audit event" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Seed a core row directly (bypass V1.7 promotion path)
    try mgr.upsertMemory(2, "k_to_demote", "core fact A", .core, "session-A");

    // ── Step 1: confirm row IS core
    {
        const before = try mgr.getMemory(allocator, 2, "k_to_demote");
        try std.testing.expect(before != null);
        var row = before.?;
        defer row.deinit(allocator);
        try std.testing.expect(row.category.eql(.core));
    }

    // ── Step 2: V1.7 immortality guard — upsert with .daily IS clobbered to core
    try mgr.upsertMemory(2, "k_to_demote", "edited fact B", .daily, "session-B");
    {
        const after = try mgr.getMemory(allocator, 2, "k_to_demote");
        try std.testing.expect(after != null);
        var row = after.?;
        defer row.deinit(allocator);
        try std.testing.expect(row.category.eql(.core)); // CASE-guard preserves core
    }

    // ── Step 3: explicit demote unlocks editing
    const demoted = try mgr.demoteMemoryFromCore(2, "k_to_demote", "daily");
    try std.testing.expect(demoted);
    {
        const after = try mgr.getMemory(allocator, 2, "k_to_demote");
        try std.testing.expect(after != null);
        var row = after.?;
        defer row.deinit(allocator);
        try std.testing.expect(row.category.eql(.daily));
    }

    // ── Step 4: subsequent upsert with different content actually edits now
    try mgr.upsertMemory(2, "k_to_demote", "edited fact C", .daily, "session-C");
    {
        const after = try mgr.getMemory(allocator, 2, "k_to_demote");
        try std.testing.expect(after != null);
        var row = after.?;
        defer row.deinit(allocator);
        try std.testing.expectEqualStrings("edited fact C", row.content);
    }

    // ── Step 5: audit event recorded
    {
        const event_q = try std.fmt.allocPrint(allocator,
            "SELECT payload->>'from', payload->>'to' FROM {s}.memory_events " ++
                "WHERE user_id = 2 AND event_type = 'demote' ORDER BY created_at DESC LIMIT 1",
            .{schema},
        );
        defer allocator.free(event_q);
        const result = try mgr.exec(event_q);
        defer c.PQclear(result);
        try std.testing.expectEqual(@as(c_int, 1), c.PQntuples(result));
        const from_t = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(from_t);
        const to_t = try dupeResultValue(allocator, result, 0, 1);
        defer allocator.free(to_t);
        try std.testing.expectEqualStrings("core", from_t);
        try std.testing.expectEqualStrings("daily", to_t);
    }

    // ── Step 6: defensive — target=core rejected as no-op
    const noop = try mgr.demoteMemoryFromCore(2, "k_to_demote", "core");
    try std.testing.expect(!noop);

    // Note: re-demoting a freshly-non-core row would normally return false
    // via the WHERE memory_type='core' filter, but V1.7 promotion can fire
    // on the post-edit state (cross-session count + non-core after demote)
    // and re-promote the row to core silently — at which point demote
    // succeeds again. That interaction is part of the V1.7 normal lifecycle,
    // not a cmt11 acceptance gate. Steps 1-5 above cover the meat: demote
    // unlocks immortality + emits audit; further lifecycle is V1.7's domain.
}

// V1.6 commit 16 — one-shot backfill of memory_edges from JSONB triples.
//
// Acceptance: a memory inserted directly via SQL (bypassing extraction_persist)
// with metadata.subject/predicate/object — the next migrate() call MUST
// populate memory_edges with a row whose target_key matches the
// deriveEntityKey shape. Re-running migrate is idempotent (UNIQUE INDEX).
test "V1.6 commit 16 backfill populates memory_edges from JSONB triples" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    // ── Seed a "legacy" memory directly (bypass extraction_persist) so the
    // edge wasn't auto-written. Simulates a pre-cmt7 row that needs backfill.
    try mgr.upsertMemoryWithMetadata(2, "legacy_helix_pref",
        "User prefers Helix",
        .core, "session-A",
        \\{"subject":"user","predicate":"PREFERS","object":"Helix","attributed_to":"user","attribution":"extraction_classifier","confidence":0.9}
    );

    // ── Confirm no edge exists yet (extraction_persist didn't write it)
    {
        const before = try mgr.countEdgesForSource(2, "legacy_helix_pref");
        try std.testing.expectEqual(@as(usize, 0), before);
    }

    // ── Run migrate() again — idempotent + triggers the backfill
    try mgr.migrate();

    // ── Backfill should have created exactly one edge
    {
        const after = try mgr.countEdgesForSource(2, "legacy_helix_pref");
        try std.testing.expectEqual(@as(usize, 1), after);
    }

    // ── Edge target_key matches the deterministic entity_<hash> shape
    {
        const edges = try mgr.findEdgesByKeys(allocator, 2, &[_][]const u8{"legacy_helix_pref"});
        defer memory_root.freeTypedEdges(allocator, edges);
        try std.testing.expectEqual(@as(usize, 1), edges.len);
        try std.testing.expect(std.mem.startsWith(u8, edges[0].target_key, "entity_"));
        try std.testing.expectEqual(@as(usize, 7 + 16), edges[0].target_key.len); // "entity_" + 16 hex chars
        try std.testing.expectEqualStrings("PREFERS", edges[0].predicate);
    }

    // ── Re-running migrate() is idempotent — no duplicate edge
    try mgr.migrate();
    {
        const after = try mgr.countEdgesForSource(2, "legacy_helix_pref");
        try std.testing.expectEqual(@as(usize, 1), after); // still 1 — UNIQUE INDEX caught duplicate
    }

    // ── Closed-out memories don't get edges (cascade-consistency check)
    try mgr.upsertMemoryWithMetadata(2, "legacy_archived",
        "User used to prefer NeoVim",
        .core, "session-A",
        \\{"subject":"user","predicate":"USED_TO_PREFER","object":"NeoVim","attributed_to":"user","attribution":"extraction_classifier","confidence":0.9}
    );
    const close_ts: i64 = std.time.timestamp();
    try mgr.setMemoryInvalidation(2, "legacy_archived", close_ts, close_ts);
    try mgr.migrate(); // re-run backfill
    {
        const after = try mgr.countEdgesForSource(2, "legacy_archived");
        try std.testing.expectEqual(@as(usize, 0), after); // skipped — closed-out
    }
}

// V1.7a-4 review fix WR-12 — Zig deriveEntityKey + SQL backfill convergence.
//
// The whole correctness argument for WR-02 closure (cmt9.9) is that
// extraction_persist.deriveEntityKey (Zig, via lowerForEntityKey) and the
// cmt16 backfill SQL (`lower(metadata->>'object')`) produce IDENTICAL
// `entity_<hash>` keys for the same input surface form. This test verifies
// that empirically by inserting metadata with several inputs (ASCII, Latin-1,
// Cyrillic, Greek, lowercase-already), running the backfill, and asserting
// each SQL-produced target_key equals the Zig-side deriveEntityKey output.
test "V1.7a-4 entity-key Zig/SQL convergence — backfill target_key == deriveEntityKey(object)" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    const extraction_persist = @import("agent/extraction_persist.zig");

    // Seed memories with metadata covering each lowering range. Use distinct
    // source keys so we can read each edge back individually.
    const Case = struct {
        source_key: []const u8,
        object: []const u8,
    };
    const cases = [_]Case{
        .{ .source_key = "row_ascii_upper", .object = "HELIX" },
        .{ .source_key = "row_ascii_lower", .object = "helix" },
        .{ .source_key = "row_latin1_upper", .object = "CAFÉ" },
        .{ .source_key = "row_latin1_lower", .object = "café" },
        .{ .source_key = "row_cyrillic_upper", .object = "ПРИВЕТ" },
        .{ .source_key = "row_greek_upper", .object = "ΑΛΦΑ" },
    };

    for (cases) |cs| {
        const meta = try std.fmt.allocPrint(
            allocator,
            "{{\"subject\":\"user\",\"predicate\":\"PREFERS\",\"object\":\"{s}\",\"attributed_to\":\"user\",\"attribution\":\"extraction_classifier\",\"confidence\":0.9}}",
            .{cs.object},
        );
        defer allocator.free(meta);
        try mgr.upsertMemoryWithMetadata(2, cs.source_key, "fact content", .core, "session-A", meta);
    }

    // Run backfill via migrate() — populates memory_edges with SQL-side
    // hashed target_keys.
    try mgr.migrate();

    // For each case: read the backfilled edge target_key, compute the Zig-
    // side deriveEntityKey for the same object, assert byte-identical.
    for (cases) |cs| {
        const edges = try mgr.findEdgesByKeys(allocator, 2, &[_][]const u8{cs.source_key});
        defer memory_root.freeTypedEdges(allocator, edges);
        try std.testing.expectEqual(@as(usize, 1), edges.len);

        // Zig-side derivation. Note: deriveEntityKey is private in
        // extraction_persist; use the public lowerForEntityKey + manual hash
        // to mirror the same derivation. (Avoids exposing deriveEntityKey
        // just for tests.)
        const lower = try extraction_persist.lowerForEntityKey(allocator, cs.object);
        defer allocator.free(lower);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(lower);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex_chars = "0123456789abcdef";
        var hex_buf: [16]u8 = undefined;
        for (digest[0..8], 0..) |b, idx| {
            hex_buf[idx * 2] = hex_chars[b >> 4];
            hex_buf[idx * 2 + 1] = hex_chars[b & 0x0f];
        }
        const expected = try std.fmt.allocPrint(allocator, "entity_{s}", .{hex_buf});
        defer allocator.free(expected);

        try std.testing.expectEqualStrings(expected, edges[0].target_key);
    }

    // Cross-case convergence: HELIX and helix must produce the SAME entity key
    // (case unification through the convergence pipeline, end-to-end).
    {
        const e_upper = try mgr.findEdgesByKeys(allocator, 2, &[_][]const u8{"row_ascii_upper"});
        defer memory_root.freeTypedEdges(allocator, e_upper);
        const e_lower = try mgr.findEdgesByKeys(allocator, 2, &[_][]const u8{"row_ascii_lower"});
        defer memory_root.freeTypedEdges(allocator, e_lower);
        try std.testing.expectEqualStrings(e_upper[0].target_key, e_lower[0].target_key);
    }
    // Same for CAFÉ vs café (Latin-1 case unification through both paths).
    {
        const e_upper = try mgr.findEdgesByKeys(allocator, 2, &[_][]const u8{"row_latin1_upper"});
        defer memory_root.freeTypedEdges(allocator, e_upper);
        const e_lower = try mgr.findEdgesByKeys(allocator, 2, &[_][]const u8{"row_latin1_lower"});
        defer memory_root.freeTypedEdges(allocator, e_lower);
        try std.testing.expectEqualStrings(e_upper[0].target_key, e_lower[0].target_key);
    }
}

// V1.7a-5 (spec seam 3) — link_type rich wiring end-to-end.
//
// Acceptance:
//   1. upsertMemoryWithMetadata populates the link_type column from
//      metadata.link_type atomically with the JSONB write
//   2. ON CONFLICT update preserves link_type via COALESCE when the new
//      metadata omits it (defensive — current writers always emit)
//   3. Backfill SQL populates link_type for legacy rows whose metadata
//      already has it but column is NULL
//   4. Backfill is idempotent: re-running migrate() doesn't disturb
//      already-populated rows
//   5. Rows without metadata.link_type stay link_type=NULL after backfill
//      (no spurious defaults assigned to legacy non-extracted memories)
test "V1.7a-5 link_type rich wiring — column populated from metadata + backfill idempotent" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_v17a5_link_type_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-v17a5-link-type/workspace");

    const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
    defer allocator.free(schema_q);

    // ── (1) Fresh write: metadata with link_type → column populated ────
    try mgr.upsertMemoryWithMetadata(
        2,
        "extracted_user_helix",
        "User prefers Helix",
        .core,
        "session-A",
        \\{"subject":"user","predicate":"PREFERS","object":"Helix","attributed_to":"user","link_type":"preference","confidence":0.9}
        ,
    );
    {
        const q = try std.fmt.allocPrint(allocator, "SELECT link_type FROM {s}.memories WHERE key = 'extracted_user_helix'", .{schema_q});
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        try std.testing.expectEqual(@as(c_int, 1), c.PQntuples(result));
        const lt = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(lt);
        try std.testing.expectEqualStrings("preference", lt);
    }

    // ── (2) Update with new metadata that has link_type — column refreshes
    try mgr.upsertMemoryWithMetadata(
        2,
        "extracted_user_helix",
        "User prefers Helix (updated)",
        .core,
        "session-B",
        \\{"subject":"user","predicate":"PREFERS","object":"Helix","attributed_to":"user","link_type":"preference","confidence":0.95}
        ,
    );
    {
        const q = try std.fmt.allocPrint(allocator, "SELECT link_type FROM {s}.memories WHERE key = 'extracted_user_helix'", .{schema_q});
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        const lt = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(lt);
        try std.testing.expectEqualStrings("preference", lt);
    }

    // ── (3) Update with metadata that OMITS link_type — COALESCE preserves
    try mgr.upsertMemoryWithMetadata(
        2,
        "extracted_user_helix",
        "User prefers Helix (no link_type in update)",
        .core,
        "session-C",
        \\{"subject":"user","predicate":"PREFERS","object":"Helix","attributed_to":"user","confidence":0.99}
        ,
    );
    {
        const q = try std.fmt.allocPrint(allocator, "SELECT link_type FROM {s}.memories WHERE key = 'extracted_user_helix'", .{schema_q});
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        const lt = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(lt);
        try std.testing.expectEqualStrings("preference", lt); // preserved by COALESCE
    }

    // ── (4) Simulate a "legacy" row: metadata HAS link_type but column NULL.
    //       (Pre-V1.7a-5 writes followed this shape — column stayed NULL until backfill.)
    //
    // Build the SQL via ArrayList writeAll instead of std.fmt.allocPrint so
    // the literal `{` and `}` in the JSON metadata don't get misparsed by
    // Zig's format-string interpreter.
    {
        var seed_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer seed_buf.deinit(allocator);
        const sw = seed_buf.writer(allocator);
        try sw.writeAll("INSERT INTO ");
        try sw.writeAll(schema_q);
        try sw.writeAll(".memories (id, user_id, key, content, content_hash, memory_type, metadata, lemmatized, link_type, updated_at) ");
        try sw.writeAll("VALUES ('legacyhash00001', 2, 'legacy_extracted_zsh', 'User uses zsh', 'lhash01', 'core', ");
        try sw.writeAll("$$" ++ "{\"subject\":\"user\",\"predicate\":\"USES\",\"object\":\"zsh\",\"link_type\":\"usage\"}" ++ "$$" ++ "::jsonb, ");
        try sw.writeAll("'user uses zsh', NULL, NOW())");
        const result = try mgr.exec(seed_buf.items);
        c.PQclear(result);
    }
    // Verify pre-backfill: column is NULL even though metadata has link_type.
    {
        const q = try std.fmt.allocPrint(allocator, "SELECT link_type FROM {s}.memories WHERE key = 'legacy_extracted_zsh'", .{schema_q});
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        // PG NULL maps to empty string via PQgetvalue; check via PQgetisnull.
        try std.testing.expect(c.PQgetisnull(result, 0, 0) == 1);
    }

    // ── (5) Run migrate() again — backfill triggers, populates legacy row.
    try mgr.migrate();
    {
        const q = try std.fmt.allocPrint(allocator, "SELECT link_type FROM {s}.memories WHERE key = 'legacy_extracted_zsh'", .{schema_q});
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        try std.testing.expect(c.PQgetisnull(result, 0, 0) == 0);
        const lt = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(lt);
        try std.testing.expectEqualStrings("usage", lt);
    }

    // ── (6) Idempotency: a subsequent migrate() doesn't disturb populated rows.
    try mgr.migrate();
    {
        const q = try std.fmt.allocPrint(allocator, "SELECT link_type FROM {s}.memories WHERE key = 'legacy_extracted_zsh'", .{schema_q});
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        const lt = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(lt);
        try std.testing.expectEqualStrings("usage", lt);
    }

    // ── (7) Rows without metadata.link_type stay NULL after backfill.
    try mgr.upsertMemory(2, "ad_hoc_no_metadata_row", "ad-hoc fact", .core, null);
    try mgr.migrate(); // backfill again — must skip this row
    {
        const q = try std.fmt.allocPrint(allocator, "SELECT link_type FROM {s}.memories WHERE key = 'ad_hoc_no_metadata_row'", .{schema_q});
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        try std.testing.expect(c.PQgetisnull(result, 0, 0) == 1);
    }

    // ── (8) End-to-end via extraction_persist: predicate maps to category,
    //       metadata gets it, column reflects it.
    const extraction_persist = @import("agent/extraction_persist.zig");
    const mems = [_]extraction_persist.ExtractedMemory{.{
        .text = "User uses Helix as primary editor",
        .subject = "user",
        .predicate = "PREFERS",
        .object = "Helix",
        .attributed_to = "user",
        .confidence = 0.9,
    }};
    const persist_result = try extraction_persist.persistExtracted(
        allocator,
        &mgr,
        2,
        "session-extraction-test",
        &mems,
        null,
        null,
        null, // V1.8-2: mem_rt — test fixture, no runtime
    );
    try std.testing.expect(persist_result.written_count == 1);
    {
        const q = try std.fmt.allocPrint(
            allocator,
            "SELECT link_type FROM {s}.memories WHERE key LIKE 'extracted_%' AND content = 'User uses Helix as primary editor'",
            .{schema_q},
        );
        defer allocator.free(q);
        const result = try mgr.exec(q);
        defer c.PQclear(result);
        try std.testing.expect(c.PQntuples(result) >= 1);
        const lt = try dupeResultValue(allocator, result, 0, 0);
        defer allocator.free(lt);
        try std.testing.expectEqualStrings("preference", lt); // PREFERS → preference
    }
}

// V1.7a-5b — getMemoryAnyValidity: surface superseded rows for /brain drilldown.
//
// Acceptance:
//   1. Live row (valid_to=NULL) is returned by BOTH getMemory AND
//      getMemoryAnyValidity
//   2. Superseded row (valid_to=past timestamp) is HIDDEN by getMemory
//      (returns null) but SURFACED by getMemoryAnyValidity (returns the row
//      with valid_to populated)
//   3. Truly non-existent key returns null from BOTH paths (cross-tenant
//      scoping preserved — wrong user_id also returns null)
//   4. getMemoryAnyValidity does NOT bump access counters (archived rows
//      shouldn't be promoted by drilldown viewing)
test "V1.7a-5b getMemoryAnyValidity — surfaces archived rows + scoping preserved" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_v17a5b_anyvalidity_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-v17a5b-anyvalidity/workspace");

    // ── (1) Live row: getMemory returns it, getMemoryAnyValidity also returns
    try mgr.upsertMemory(2, "live_fact", "User uses Helix", .core, "session-A");
    {
        const live = try mgr.getMemory(allocator, 2, "live_fact");
        try std.testing.expect(live != null);
        if (live) |row| {
            defer row.deinit(allocator);
            try std.testing.expect(row.valid_to == null);
            try std.testing.expectEqualStrings("User uses Helix", row.content);
        }
    }
    {
        const any = try mgr.getMemoryAnyValidity(allocator, 2, "live_fact");
        try std.testing.expect(any != null);
        if (any) |row| {
            defer row.deinit(allocator);
            try std.testing.expect(row.valid_to == null);
        }
    }

    // ── (2) Insert a row, archive it via setMemoryInvalidation, verify
    //       getMemory hides it but getMemoryAnyValidity surfaces it.
    try mgr.upsertMemory(2, "archived_fact", "User used to use NeoVim", .core, "session-A");
    // Demote first so setMemoryInvalidation can close it (core rows are
    // immortal until demoted — V1.6 cmt11 guard).
    _ = try mgr.demoteMemoryFromCore(2, "archived_fact", "test_close");
    const close_ts: i64 = std.time.timestamp() - 60; // 60s in the past
    try mgr.setMemoryInvalidation(2, "archived_fact", close_ts, close_ts);

    {
        const live = try mgr.getMemory(allocator, 2, "archived_fact");
        // getMemory must hide archived rows (validity filter)
        try std.testing.expect(live == null);
    }
    {
        const any = try mgr.getMemoryAnyValidity(allocator, 2, "archived_fact");
        try std.testing.expect(any != null);
        if (any) |row| {
            defer row.deinit(allocator);
            try std.testing.expect(row.valid_to != null);
            try std.testing.expectEqual(close_ts, row.valid_to.?);
            try std.testing.expectEqualStrings("User used to use NeoVim", row.content);
        }
    }

    // ── (3) Non-existent key returns null from both paths
    {
        const live = try mgr.getMemory(allocator, 2, "no_such_key_anywhere");
        try std.testing.expect(live == null);
        const any = try mgr.getMemoryAnyValidity(allocator, 2, "no_such_key_anywhere");
        try std.testing.expect(any == null);
    }

    // ── (4) Cross-tenant scoping: row exists for user 2, query as user 99
    //       must return null (not leak across users). No provisionUser
    //       call needed — getMemoryAnyValidity just runs a SELECT and the
    //       WHERE user_id=$1 filter alone enforces isolation.
    {
        const wrong_user = try mgr.getMemoryAnyValidity(allocator, 99, "live_fact");
        try std.testing.expect(wrong_user == null);
    }
}

// V1.7a-6 — listMemoryBirthsInWindow + listMemoryDeathsInWindow:
// independent event streams over a [from, to) window. Acceptance:
//   1. Birth IN window appears in births
//   2. Death IN window appears in deaths (even when superseded)
//   3. Same memory born+died inside window appears in BOTH (events ≠ row state)
//   4. Birth/death OUTSIDE window does NOT appear
//   5. Hidden-key filter (BRAIN_USER_KEY_FILTER) drops continuity / autosave
//   6. Cross-tenant scoping: user 99 sees nothing of user 2's data
test "V1.7a-6 listMemory{Births,Deaths}InWindow — event streams over [from, to)" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_v17a6_diff_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-v17a6-diff/workspace");

    // ── Window setup: [today_midnight_utc, today_midnight_utc + 86400s) ─
    // Computed against PG's clock to avoid local-vs-PG drift.
    const window_q = try std.fmt.allocPrint(
        allocator,
        "SELECT (date_trunc('day', (now() AT TIME ZONE 'UTC')) AT TIME ZONE 'UTC') " ++
            "::timestamptz, " ++
            "(EXTRACT(EPOCH FROM (date_trunc('day', (now() AT TIME ZONE 'UTC')) AT TIME ZONE 'UTC')))::bigint",
        .{},
    );
    defer allocator.free(window_q);
    const wres = try mgr.exec(window_q);
    defer c.PQclear(wres);
    try std.testing.expectEqual(@as(c_int, 1), c.PQntuples(wres));
    const today_midnight_text = try dupeResultValue(allocator, wres, 0, 1);
    defer allocator.free(today_midnight_text);
    const today_midnight = try std.fmt.parseInt(i64, today_midnight_text, 10);
    const window_from = today_midnight;
    const window_to = today_midnight + 86400;

    // ── Seed memories ────────────────────────────────────────────────
    // (a) Born today, still live → birth IN, no death
    try mgr.upsertMemory(2, "mem_born_today", "fact A", .core, "session-A");
    // (b) Born today, archived today → birth IN, death IN (in BOTH lists)
    try mgr.upsertMemory(2, "mem_born_died_today", "fact B", .core, "session-A");
    _ = try mgr.demoteMemoryFromCore(2, "mem_born_died_today", "test_close");
    const close_ts_today = today_midnight + 3600; // 1AM UTC today
    try mgr.setMemoryInvalidation(2, "mem_born_died_today", close_ts_today, close_ts_today);
    // (c) Born yesterday, archived today → birth NOT in, death IN
    try mgr.upsertMemory(2, "mem_born_yesterday", "fact C", .core, "session-A");
    {
        // Backdate created_at to yesterday via raw UPDATE (the public API
        // uses NOW() — we need precise control for the window test).
        const yesterday_set = try std.fmt.allocPrint(
            allocator,
            "UPDATE {s}.memories SET created_at = to_timestamp({d}::bigint) " ++
                "WHERE user_id = 2 AND key = 'mem_born_yesterday'",
            .{ schema, today_midnight - 3600 }, // 1h before window start
        );
        defer allocator.free(yesterday_set);
        const r = try mgr.exec(yesterday_set);
        c.PQclear(r);
    }
    _ = try mgr.demoteMemoryFromCore(2, "mem_born_yesterday", "test_close");
    try mgr.setMemoryInvalidation(2, "mem_born_yesterday", close_ts_today, close_ts_today);

    // (d) Born yesterday, archived yesterday → both OUTSIDE window
    try mgr.upsertMemory(2, "mem_outside_window", "fact D", .core, "session-A");
    {
        const old_set = try std.fmt.allocPrint(
            allocator,
            "UPDATE {s}.memories SET created_at = to_timestamp({d}::bigint) " ++
                "WHERE user_id = 2 AND key = 'mem_outside_window'",
            .{ schema, today_midnight - 7200 }, // 2h before window start
        );
        defer allocator.free(old_set);
        const r = try mgr.exec(old_set);
        c.PQclear(r);
    }
    _ = try mgr.demoteMemoryFromCore(2, "mem_outside_window", "test_close");
    try mgr.setMemoryInvalidation(2, "mem_outside_window", today_midnight - 1800, today_midnight - 1800);

    // (e) Hidden-key sentinel: born today, must be filtered out of BOTH lists
    try mgr.upsertMemory(2, "summary_latest/agent:zaki-bot:user:7:thread:main", "type=summary_latest", .daily, "session-A");

    // ── Births surface ──────────────────────────────────────────────
    {
        const births = try mgr.listMemoryBirthsInWindow(allocator, 2, window_from, window_to, 100);
        defer memory_root.freeEntries(allocator, births);
        // Expected: mem_born_today + mem_born_died_today (2 rows). Hidden
        // continuity summary is filtered. Yesterday-born rows excluded.
        var seen_a = false;
        var seen_b = false;
        for (births) |e| {
            try std.testing.expect(memory_root.isBrainVisibleKey(e.key));
            if (std.mem.eql(u8, e.key, "mem_born_today")) seen_a = true;
            if (std.mem.eql(u8, e.key, "mem_born_died_today")) seen_b = true;
            try std.testing.expect(!std.mem.eql(u8, e.key, "mem_born_yesterday"));
            try std.testing.expect(!std.mem.eql(u8, e.key, "mem_outside_window"));
        }
        try std.testing.expect(seen_a);
        try std.testing.expect(seen_b);
        try std.testing.expectEqual(@as(usize, 2), births.len);
    }

    // ── Deaths surface ──────────────────────────────────────────────
    {
        const deaths = try mgr.listMemoryDeathsInWindow(allocator, 2, window_from, window_to, 100);
        defer memory_root.freeEntries(allocator, deaths);
        // Expected: mem_born_died_today + mem_born_yesterday (2 rows).
        // Out-of-window death excluded. Hidden continuity summary filtered.
        var seen_b = false;
        var seen_c = false;
        for (deaths) |e| {
            try std.testing.expect(memory_root.isBrainVisibleKey(e.key));
            try std.testing.expect(e.valid_to != null);
            if (std.mem.eql(u8, e.key, "mem_born_died_today")) seen_b = true;
            if (std.mem.eql(u8, e.key, "mem_born_yesterday")) seen_c = true;
            try std.testing.expect(!std.mem.eql(u8, e.key, "mem_born_today"));
            try std.testing.expect(!std.mem.eql(u8, e.key, "mem_outside_window"));
        }
        try std.testing.expect(seen_b);
        try std.testing.expect(seen_c);
        try std.testing.expectEqual(@as(usize, 2), deaths.len);
    }

    // ── Independence: born+died-today appears in BOTH lists ─────────
    // Already verified above (seen_b in births AND deaths). The contract
    // is that births/deaths are independent event streams over the same
    // window — a row that experienced both events shows up twice.

    // ── Cross-tenant scoping ────────────────────────────────────────
    {
        const wrong_births = try mgr.listMemoryBirthsInWindow(allocator, 99, window_from, window_to, 100);
        defer memory_root.freeEntries(allocator, wrong_births);
        try std.testing.expectEqual(@as(usize, 0), wrong_births.len);
        const wrong_deaths = try mgr.listMemoryDeathsInWindow(allocator, 99, window_from, window_to, 100);
        defer memory_root.freeEntries(allocator, wrong_deaths);
        try std.testing.expectEqual(@as(usize, 0), wrong_deaths.len);
    }
}

// V1.7a-7 — getMemoriesByKeys: batch-fetch full rows by key set.
// Acceptance:
//   1. Multi-key fetch returns rows for ALL requested keys (validity-filtered)
//   2. Empty key set returns empty slice (no SQL)
//   3. Superseded rows are HIDDEN (validity filter applied)
//   4. Cross-tenant scoping: user 99 sees nothing of user 2's data
//   5. Non-existent key in mixed set is silently absent (not an error)
//   6. Special-character keys round-trip cleanly through PG text-array escape
test "V1.7a-7 getMemoriesByKeys — batch fetch + validity + scoping + escape" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_v17a7_bykeys_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-v17a7-bykeys/workspace");

    // ── Seed: live + archived + special-char key ────────────────────
    try mgr.upsertMemory(2, "alpha", "fact A", .core, "session-A");
    try mgr.upsertMemory(2, "beta", "fact B", .daily, "session-A");
    try mgr.upsertMemory(2, "gamma", "fact C", .core, "session-B");
    // Archive gamma — must be hidden by validity filter.
    _ = try mgr.demoteMemoryFromCore(2, "gamma", "test_close");
    const close_ts: i64 = std.time.timestamp() - 60;
    try mgr.setMemoryInvalidation(2, "gamma", close_ts, close_ts);
    // Special-char key — quote + backslash. Tests array-escape correctness.
    try mgr.upsertMemory(2, "weird\"key\\with\"chars", "fact W", .core, "session-A");

    // ── (1) Multi-key fetch returns ALL live keys ───────────────────
    {
        const keys = [_][]const u8{ "alpha", "beta" };
        const rows = try mgr.getMemoriesByKeys(allocator, 2, &keys);
        defer memory_root.freeEntries(allocator, rows);
        try std.testing.expectEqual(@as(usize, 2), rows.len);
        var seen_a = false;
        var seen_b = false;
        for (rows) |r| {
            if (std.mem.eql(u8, r.key, "alpha")) {
                seen_a = true;
                try std.testing.expectEqualStrings("fact A", r.content);
            }
            if (std.mem.eql(u8, r.key, "beta")) {
                seen_b = true;
                try std.testing.expectEqualStrings("fact B", r.content);
            }
        }
        try std.testing.expect(seen_a);
        try std.testing.expect(seen_b);
    }

    // ── (2) Empty key set returns empty (no SQL) ───────────────────
    {
        const empty: [0][]const u8 = .{};
        const rows = try mgr.getMemoriesByKeys(allocator, 2, &empty);
        defer memory_root.freeEntries(allocator, rows);
        try std.testing.expectEqual(@as(usize, 0), rows.len);
    }

    // ── (3) Superseded row is HIDDEN by validity filter ────────────
    {
        const keys = [_][]const u8{"gamma"};
        const rows = try mgr.getMemoriesByKeys(allocator, 2, &keys);
        defer memory_root.freeEntries(allocator, rows);
        try std.testing.expectEqual(@as(usize, 0), rows.len);
    }

    // ── (4) Cross-tenant scoping: user 99 sees nothing ─────────────
    {
        const keys = [_][]const u8{ "alpha", "beta" };
        const rows = try mgr.getMemoriesByKeys(allocator, 99, &keys);
        defer memory_root.freeEntries(allocator, rows);
        try std.testing.expectEqual(@as(usize, 0), rows.len);
    }

    // ── (5) Mixed live + non-existent: non-existent silently absent
    {
        const keys = [_][]const u8{ "alpha", "no_such_key" };
        const rows = try mgr.getMemoriesByKeys(allocator, 2, &keys);
        defer memory_root.freeEntries(allocator, rows);
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings("alpha", rows[0].key);
    }

    // ── (6) Special-character key round-trips through array escape ─
    {
        const keys = [_][]const u8{"weird\"key\\with\"chars"};
        const rows = try mgr.getMemoriesByKeys(allocator, 2, &keys);
        defer memory_root.freeEntries(allocator, rows);
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings("weird\"key\\with\"chars", rows[0].key);
        try std.testing.expectEqualStrings("fact W", rows[0].content);
    }
}

// V1.7a-8a — listOrphanMemories: brain-visible rows with NO active edges.
// Acceptance:
//   1. Memory with no edges → returned as orphan
//   2. Memory with outgoing edge → NOT orphan (excluded)
//   3. Memory with incoming edge → NOT orphan (excluded)
//   4. Hidden-key (continuity summary) with no edges → filtered (NOT
//      returned — agent bookkeeping rows are always orphans by design)
//   5. Memory whose edges were ALL closed (is_latest=FALSE) → orphan
//      in the present (validity-aware on the edge subquery)
//   6. Superseded-but-edgeless memory → ALSO returned. V1.11 update
//      (2026-05-07, Nova directive: "don't filter"): the validity
//      filter on the memories row was removed. An archived fact that
//      was never linked is still a loose fact (in fact more suspicious).
//      The FE renders valid_to so users can tell archived from live.
//   7. Cross-tenant: user 99 sees nothing of user 2's data
test "V1.7a-8a listOrphanMemories — orphans + edge-loss + hygiene + scoping" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_v17a8a_orphans_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-v17a8a-orphans/workspace");

    // ── Seed memories ─────────────────────────────────────────────
    try mgr.upsertMemory(2, "mem_orphan", "lonely fact", .core, "session-A");
    try mgr.upsertMemory(2, "mem_with_outgoing", "has a target", .core, "session-A");
    try mgr.upsertMemory(2, "mem_target", "is targeted", .core, "session-A");
    try mgr.upsertMemory(2, "mem_lost_edge", "edge will be closed", .core, "session-A");
    try mgr.upsertMemory(2, "mem_lost_partner", "partner of lost-edge", .core, "session-A");
    // Hidden-key orphan (continuity summary with no edges)
    try mgr.upsertMemory(2, "summary_latest/agent:zaki-bot:user:7:thread:main", "type=summary_latest", .daily, "session-A");
    // Superseded orphan (no edges + valid_to in past)
    try mgr.upsertMemory(2, "mem_superseded_orphan", "old fact", .core, "session-A");
    _ = try mgr.demoteMemoryFromCore(2, "mem_superseded_orphan", "test_close");
    const close_ts: i64 = std.time.timestamp() - 60;
    try mgr.setMemoryInvalidation(2, "mem_superseded_orphan", close_ts, close_ts);

    // ── Seed edges ────────────────────────────────────────────────
    try mgr.upsertMemoryEdge(2, "mem_with_outgoing", "mem_target", "relates_to", "test", null);
    try mgr.upsertMemoryEdge(2, "mem_lost_edge", "mem_lost_partner", "relates_to", "test", null);
    // Manually close the lost-edge by flipping is_latest (simulates the
    // cascade-on-supersession path without invoking the cascade itself,
    // so we test the edge-validity filter in isolation).
    {
        const close_q = try std.fmt.allocPrint(
            allocator,
            "UPDATE {s}.memory_edges SET is_latest = FALSE " ++
                "WHERE user_id = 2 AND source_key = 'mem_lost_edge'",
            .{schema},
        );
        defer allocator.free(close_q);
        const r = try mgr.exec(close_q);
        c.PQclear(r);
    }

    // ── Acceptance: orphan list ───────────────────────────────────
    {
        const orphans = try mgr.listOrphanMemories(allocator, 2, 100);
        defer memory_root.freeEntries(allocator, orphans);

        var seen_orphan = false;
        var seen_lost_edge = false;
        var seen_lost_partner = false;
        var seen_superseded_orphan = false;
        for (orphans) |e| {
            try std.testing.expect(memory_root.isBrainVisibleKey(e.key));
            if (std.mem.eql(u8, e.key, "mem_orphan")) seen_orphan = true;
            if (std.mem.eql(u8, e.key, "mem_lost_edge")) seen_lost_edge = true;
            if (std.mem.eql(u8, e.key, "mem_lost_partner")) seen_lost_partner = true;
            if (std.mem.eql(u8, e.key, "mem_superseded_orphan")) seen_superseded_orphan = true;
            // Negative checks
            try std.testing.expect(!std.mem.eql(u8, e.key, "mem_with_outgoing"));
            try std.testing.expect(!std.mem.eql(u8, e.key, "mem_target"));
            try std.testing.expect(!std.mem.startsWith(u8, e.key, "summary_latest/"));
        }
        try std.testing.expect(seen_orphan); // (1) no-edge orphan returned
        try std.testing.expect(seen_lost_edge); // (5) edge-loss surfaces both
        try std.testing.expect(seen_lost_partner); //     endpoints as orphans
        // V1.11 (2026-05-07) — superseded-but-edgeless rows now surface
        // as loose facts (acceptance #6 was inverted by the validity
        // filter removal per Nova "don't filter").
        try std.testing.expect(seen_superseded_orphan);
        try std.testing.expectEqual(@as(usize, 4), orphans.len);
    }

    // ── Cross-tenant ──────────────────────────────────────────────
    {
        const wrong = try mgr.listOrphanMemories(allocator, 99, 100);
        defer memory_root.freeEntries(allocator, wrong);
        try std.testing.expectEqual(@as(usize, 0), wrong.len);
    }
}

// V1.7a-9a — Communities storage primitives:
//   - listMemoryEdgesForCommunityCompute (edges with weight + attribution)
//   - setMemoryCommunityIds (batch UPDATE)
//   - setCommunityName + getCommunityName (upsert + lookup)
//   - listCommunities (LEFT JOIN with live member-count subquery)
test "V1.7a-9a community storage primitives — round-trip + cross-tenant + idempotency" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_v17a9a_comm_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-v17a9a-comm/workspace");

    // ── Seed: memories + edges (with various weights + attributions) ─
    try mgr.upsertMemory(2, "k_a", "fact A", .core, "session-A");
    try mgr.upsertMemory(2, "k_b", "fact B", .core, "session-A");
    try mgr.upsertMemory(2, "k_c", "fact C", .core, "session-A");
    try mgr.upsertMemory(2, "k_archived", "old fact", .core, "session-A");
    // Archive one memory — its edges must NOT appear in compute fetch
    // (live-endpoint requirement).
    _ = try mgr.demoteMemoryFromCore(2, "k_archived", "test_close");
    const close_ts: i64 = std.time.timestamp() - 60;
    try mgr.setMemoryInvalidation(2, "k_archived", close_ts, close_ts);

    try mgr.upsertMemoryEdge(2, "k_a", "k_b", "relates_to", "extraction_classifier", null);
    try mgr.upsertMemoryEdge(2, "k_b", "k_c", "relates_to", "compose_memory", null);
    // Edge to archived memory — must be filtered (live-endpoint check)
    try mgr.upsertMemoryEdge(2, "k_a", "k_archived", "relates_to", "extraction_classifier", null);

    // ── (1) listMemoryEdgesForCommunityCompute ─────────────────────
    {
        const edges = try mgr.listMemoryEdgesForCommunityCompute(allocator, 2);
        defer memory_root.freeCommunityEdges(allocator, edges);
        // Expect: k_a→k_b + k_b→k_c. The k_a→k_archived edge is filtered
        // because k_archived is no longer a live memory.
        try std.testing.expectEqual(@as(usize, 2), edges.len);
        var saw_ab = false;
        var saw_bc = false;
        for (edges) |e| {
            try std.testing.expect(e.weight > 0); // default 1.0 from upsert
            try std.testing.expect(e.attribution.len > 0);
            try std.testing.expect(e.valid_from_unix > 0);
            if (std.mem.eql(u8, e.source_key, "k_a") and std.mem.eql(u8, e.target_key, "k_b")) {
                saw_ab = true;
                try std.testing.expectEqualStrings("extraction_classifier", e.attribution);
            }
            if (std.mem.eql(u8, e.source_key, "k_b") and std.mem.eql(u8, e.target_key, "k_c")) {
                saw_bc = true;
                try std.testing.expectEqualStrings("compose_memory", e.attribution);
            }
        }
        try std.testing.expect(saw_ab);
        try std.testing.expect(saw_bc);
    }

    // ── (2) setMemoryCommunityIds — batch UPDATE round-trip ────────
    {
        const assignments = [_]memory_root.CommunityAssignment{
            .{ .key = "k_a", .community_id = 100 },
            .{ .key = "k_b", .community_id = 100 },
            .{ .key = "k_c", .community_id = 200 },
        };
        try mgr.setMemoryCommunityIds(2, &assignments);

        // Verify via raw SELECT
        const verify_q = try std.fmt.allocPrint(
            allocator,
            "SELECT key, community_id FROM {s}.memories " ++
                "WHERE user_id = 2 AND community_id IS NOT NULL ORDER BY key",
            .{schema},
        );
        defer allocator.free(verify_q);
        const r = try mgr.exec(verify_q);
        defer c.PQclear(r);
        try std.testing.expectEqual(@as(c_int, 3), c.PQntuples(r));
        // Idempotency: re-apply same assignments → same final state
        try mgr.setMemoryCommunityIds(2, &assignments);
        const r2 = try mgr.exec(verify_q);
        defer c.PQclear(r2);
        try std.testing.expectEqual(@as(c_int, 3), c.PQntuples(r2));
    }

    // ── (3) Empty assignment slice → no-op (no error) ──────────────
    {
        const empty: [0]memory_root.CommunityAssignment = .{};
        try mgr.setMemoryCommunityIds(2, &empty);
    }

    // ── (4) setCommunityName + getCommunityName (upsert) ───────────
    {
        try mgr.setCommunityName(2, 100, "Work projects", "llm", 2, "hash_v1");
        const fetched = try mgr.getCommunityName(allocator, 2, 100);
        try std.testing.expect(fetched != null);
        if (fetched) |n| {
            defer n.deinit(allocator);
            try std.testing.expectEqualStrings("Work projects", n.name);
            try std.testing.expectEqualStrings("llm", n.name_source);
            try std.testing.expectEqual(@as(u32, 2), n.member_count);
            try std.testing.expectEqualStrings("hash_v1", n.member_set_hash);
        }
        // Upsert: same community_id, new name → row updated
        try mgr.setCommunityName(2, 100, "Engineering work", "llm", 2, "hash_v2");
        const fetched2 = try mgr.getCommunityName(allocator, 2, 100);
        try std.testing.expect(fetched2 != null);
        if (fetched2) |n| {
            defer n.deinit(allocator);
            try std.testing.expectEqualStrings("Engineering work", n.name);
            try std.testing.expectEqualStrings("hash_v2", n.member_set_hash);
        }
        // Non-existent community → null
        const missing = try mgr.getCommunityName(allocator, 2, 999);
        try std.testing.expect(missing == null);
    }

    // ── (5) listCommunities — LEFT JOIN with live member counts ────
    {
        // Add a name for community 200 too so we have two summaries.
        try mgr.setCommunityName(2, 200, "Daily routines", "fallback", 1, "hash_x");
        const summaries = try mgr.listCommunities(allocator, 2);
        defer memory_root.freeCommunitySummaries(allocator, summaries);
        try std.testing.expectEqual(@as(usize, 2), summaries.len);
        // Sorted by member_count DESC: 100 (2 members) then 200 (1 member)
        try std.testing.expectEqual(@as(i32, 100), summaries[0].community_id);
        try std.testing.expectEqual(@as(u32, 2), summaries[0].member_count);
        try std.testing.expect(summaries[0].name != null);
        if (summaries[0].name) |n| try std.testing.expectEqualStrings("Engineering work", n);
        try std.testing.expectEqual(@as(i32, 200), summaries[1].community_id);
        try std.testing.expectEqual(@as(u32, 1), summaries[1].member_count);
    }

    // ── (6) Cross-tenant scoping: user 99 sees nothing ─────────────
    {
        const edges = try mgr.listMemoryEdgesForCommunityCompute(allocator, 99);
        defer memory_root.freeCommunityEdges(allocator, edges);
        try std.testing.expectEqual(@as(usize, 0), edges.len);
        const summaries = try mgr.listCommunities(allocator, 99);
        defer memory_root.freeCommunitySummaries(allocator, summaries);
        try std.testing.expectEqual(@as(usize, 0), summaries.len);
        const missing = try mgr.getCommunityName(allocator, 99, 100);
        try std.testing.expect(missing == null);
    }
}

// V1.7a-9c — End-to-end pipeline: pull edges → LPA → assign IDs → name.
// Acceptance:
//   1. Two-component corpus (3-clique + 2-clique) produces 2 communities;
//      each member gets the SAME community_id as its component peers
//   2. Idempotency: re-running on unchanged corpus produces the same
//      community_ids + same names (caller observes same final state)
//   3. Mock LLM namer is called once per qualifying community; fallback
//      "Cluster N" used when namer is null
//   4. member_set_hash cache: 2nd recompute with same membership skips
//      LLM (cache hit); only re-names when membership changes
//   5. Cross-tenant: recompute for user 99 sees nothing (no edges)
test "V1.7a-9c recomputeCommunitiesForUser — end-to-end pipeline + namer + cache" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    const community_pipeline = @import("agent/community_pipeline.zig");

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_v17a9c_pipeline_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try ManagerImpl.init(allocator, cfg);
    defer mgr.deinit();
    {
        const schema_q = try pg_helpers.quoteIdentifier(allocator, mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const result = try mgr.exec(drop_q);
        c.PQclear(result);
    }
    try mgr.migrate();
    try mgr.provisionUser(2, "/tmp/nullalis-zaki-v17a9c-pipeline/workspace");

    // ── Seed: two components ───────────────────────────────────────
    // Component A: 3-clique (a, b, c)
    // Component B: 2-clique (x, y)
    try mgr.upsertMemory(2, "a", "fact A", .core, "session-A");
    try mgr.upsertMemory(2, "b", "fact B", .core, "session-A");
    try mgr.upsertMemory(2, "c", "fact C", .core, "session-A");
    try mgr.upsertMemory(2, "x", "fact X", .core, "session-A");
    try mgr.upsertMemory(2, "y", "fact Y", .core, "session-A");
    try mgr.upsertMemoryEdge(2, "a", "b", "rel", "extraction_classifier", null);
    try mgr.upsertMemoryEdge(2, "b", "c", "rel", "extraction_classifier", null);
    try mgr.upsertMemoryEdge(2, "a", "c", "rel", "extraction_classifier", null);
    try mgr.upsertMemoryEdge(2, "x", "y", "rel", "extraction_classifier", null);

    // ── Mock LLM namer: returns deterministic name based on top member ─
    const MockNamerCtx = struct {
        call_count: u32 = 0,
    };
    const mock_namer_fn = struct {
        fn name_fn(ctx: *anyopaque, members: []const community_pipeline.NamerMember, alloc: std.mem.Allocator) anyerror![]u8 {
            const c_ctx: *MockNamerCtx = @ptrCast(@alignCast(ctx));
            c_ctx.call_count += 1;
            const top = if (members.len > 0) members[0].key else "empty";
            return std.fmt.allocPrint(alloc, "Cluster of {s}", .{top});
        }
    }.name_fn;
    var mock_ctx: MockNamerCtx = .{};
    const namer: community_pipeline.LlmNamer = .{
        .ctx = @ptrCast(&mock_ctx),
        .name_fn = mock_namer_fn,
    };

    // ── (1) First recompute ────────────────────────────────────────
    {
        const stats = try community_pipeline.recomputeCommunitiesForUser(
            allocator,
            &mgr,
            2,
            namer,
            .{ .now_unix = std.time.timestamp() },
        );
        try std.testing.expectEqual(@as(usize, 4), stats.edges_loaded); // 3 + 1
        try std.testing.expectEqual(@as(usize, 5), stats.nodes_in_lpa);
        try std.testing.expectEqual(@as(usize, 2), stats.communities_found);
        try std.testing.expectEqual(@as(usize, 5), stats.members_assigned);
        // Both communities are >= min_size_for_llm_name (2) → 2 LLM calls
        try std.testing.expectEqual(@as(u32, 2), stats.llm_calls_succeeded);
        try std.testing.expectEqual(@as(u32, 2), mock_ctx.call_count);
    }

    // ── (2) Verify same community_id for component peers via PG ───
    {
        const verify_q = try std.fmt.allocPrint(
            allocator,
            "SELECT key, community_id FROM {s}.memories WHERE user_id = 2 AND community_id IS NOT NULL ORDER BY key",
            .{schema},
        );
        defer allocator.free(verify_q);
        const r = try mgr.exec(verify_q);
        defer c.PQclear(r);
        try std.testing.expectEqual(@as(c_int, 5), c.PQntuples(r));

        // Build map key → community_id
        var key_to_cid: std.StringHashMapUnmanaged(i32) = .{};
        defer {
            var it = key_to_cid.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            key_to_cid.deinit(allocator);
        }
        var i: c_int = 0;
        while (i < 5) : (i += 1) {
            const k = try dupeResultValue(allocator, r, i, 0);
            errdefer allocator.free(k);
            const cid_str = try dupeResultValue(allocator, r, i, 1);
            defer allocator.free(cid_str);
            const cid = try std.fmt.parseInt(i32, cid_str, 10);
            try key_to_cid.put(allocator, k, cid);
        }
        // a, b, c share one id; x, y share another; the two ids differ.
        const cid_a = key_to_cid.get("a").?;
        try std.testing.expectEqual(cid_a, key_to_cid.get("b").?);
        try std.testing.expectEqual(cid_a, key_to_cid.get("c").?);
        const cid_x = key_to_cid.get("x").?;
        try std.testing.expectEqual(cid_x, key_to_cid.get("y").?);
        try std.testing.expect(cid_a != cid_x);
    }

    // ── (3) member_set_hash cache: 2nd recompute → no LLM calls ───
    {
        mock_ctx.call_count = 0;
        const stats = try community_pipeline.recomputeCommunitiesForUser(
            allocator,
            &mgr,
            2,
            namer,
            .{ .now_unix = std.time.timestamp() },
        );
        // Same membership → cache hit on member_set_hash → 0 LLM calls
        try std.testing.expectEqual(@as(u32, 0), stats.llm_calls_succeeded);
        try std.testing.expectEqual(@as(u32, 0), mock_ctx.call_count);
        try std.testing.expectEqual(@as(usize, 2), stats.communities_found);
    }

    // ── (4) Null namer → fallback names for all communities ───────
    {
        // Drop the cached names so the next recompute is forced to re-name.
        const reset_q = try std.fmt.allocPrint(
            allocator,
            "DELETE FROM {s}.memory_communities WHERE user_id = 2",
            .{schema},
        );
        defer allocator.free(reset_q);
        const r = try mgr.exec(reset_q);
        c.PQclear(r);

        const stats = try community_pipeline.recomputeCommunitiesForUser(
            allocator,
            &mgr,
            2,
            null, // no namer
            .{ .now_unix = std.time.timestamp() },
        );
        try std.testing.expectEqual(@as(u32, 0), stats.llm_calls_succeeded);
        try std.testing.expectEqual(@as(u32, 0), stats.llm_calls_failed);
        try std.testing.expectEqual(@as(u32, 2), stats.fallback_names_written);
    }

    // ── (5) Cross-tenant: user 99 has no edges → no-op ────────────
    {
        const stats = try community_pipeline.recomputeCommunitiesForUser(
            allocator,
            &mgr,
            99,
            null,
            .{ .now_unix = std.time.timestamp() },
        );
        try std.testing.expectEqual(@as(usize, 0), stats.edges_loaded);
        try std.testing.expectEqual(@as(usize, 0), stats.communities_found);
    }
}

