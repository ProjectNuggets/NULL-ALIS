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
const memory_root = @import("memory/root.zig");
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
const log = std.log.scoped(.zaki_state);

const c = if (build_options.enable_postgres) @cImport({
    @cInclude("libpq-fe.h");
}) else struct {};

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
    pub fn listMemories(_: *@This(), allocator: std.mem.Allocator, _: i64, _: ?memory_root.MemoryCategory, _: ?[]const u8) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    pub fn recallMemories(_: *@This(), allocator: std.mem.Allocator, _: i64, _: []const u8, _: usize, _: ?[]const u8) ![]memory_root.MemoryEntry {
        return allocator.alloc(memory_root.MemoryEntry, 0);
    }
    pub fn forgetMemory(_: *@This(), _: i64, _: []const u8) !bool {
        return error.PostgresNotEnabled;
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
        const q = try self.buildQuery(
            "SELECT COALESCE(jsonb_agg(job_json ORDER BY created_at), '[]'::jsonb)::text FROM (" ++
                " SELECT created_at, " ++
                " jsonb_set(" ++
                "   jsonb_set(" ++
                "     jsonb_set(" ++
                "       jsonb_set(" ++
                "         jsonb_set(raw_job, '{enabled}', to_jsonb(enabled), true)," ++
                "         '{paused}', to_jsonb(CASE WHEN enabled THEN COALESCE((raw_job->>'paused')::boolean, false) ELSE TRUE END), true" ++
                "       )," ++
                "       '{last_status}', CASE WHEN last_status IS NULL THEN 'null'::jsonb ELSE to_jsonb(last_status) END, true" ++
                "     )," ++
                "     '{last_run_secs}', CASE WHEN last_run_at IS NULL THEN 'null'::jsonb ELSE to_jsonb(EXTRACT(EPOCH FROM last_run_at)::bigint) END, true" ++
                "   )," ++
                "   '{next_run_secs}', CASE WHEN next_run_at IS NULL THEN 'null'::jsonb ELSE to_jsonb(EXTRACT(EPOCH FROM next_run_at)::bigint) END, true" ++
                " ) AS job_json" ++
                " FROM {schema}.jobs WHERE user_id = $1" ++
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

    pub fn upsertMemory(self: *Self, user_id: i64, key: []const u8, content: []const u8, category: memory_root.MemoryCategory, session_id: ?[]const u8) !void {
        if (session_id) |sid| try self.ensureSession(user_id, sid);
        const q = try self.buildQuery(
            "INSERT INTO {schema}.memories (id, user_id, session_id, key, content, content_hash, memory_type, updated_at) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, $7, NOW()) " ++
                "ON CONFLICT (user_id, key) DO UPDATE SET session_id = EXCLUDED.session_id, content = EXCLUDED.content, content_hash = EXCLUDED.content_hash, memory_type = EXCLUDED.memory_type, updated_at = NOW() " ++
                "WHERE {schema}.memories.session_id IS DISTINCT FROM EXCLUDED.session_id OR {schema}.memories.content IS DISTINCT FROM EXCLUDED.content OR {schema}.memories.content_hash IS DISTINCT FROM EXCLUDED.content_hash OR {schema}.memories.memory_type IS DISTINCT FROM EXCLUDED.memory_type " ++
                "RETURNING id",
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

        const params = [_]?[*:0]const u8{ id_z, user_s.ptr, if (session_text.len == 0) null else session_z, key_z, content_z, content_hash_z, mem_type_z };
        const lengths = [_]c_int{
            @intCast(id.len),
            @intCast(user_s.len),
            @intCast(session_text.len),
            @intCast(key.len),
            @intCast(content.len),
            @intCast(content_hash.len),
            @intCast(mem_type.len),
        };
        const result = try self.execParams(q, &params, &lengths);
        defer c.PQclear(result);
        if (c.PQntuples(result) == 0) return;

        const stored_id = if (c.PQntuples(result) > 0)
            try dupeResultValue(self.allocator, result, 0, 0)
        else
            try self.allocator.dupe(u8, id);
        defer self.allocator.free(stored_id);
        try self.insertMemoryEvent(user_id, stored_id, "upsert", key, content, mem_type, session_id);
    }

    pub fn getMemory(self: *Self, allocator: std.mem.Allocator, user_id: i64, key: []const u8) !?memory_root.MemoryEntry {
        const q = try self.buildQuery(
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id FROM {schema}.memories WHERE user_id = $1 AND key = $2",
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

    pub fn listMemories(self: *Self, allocator: std.mem.Allocator, user_id: i64, category: ?memory_root.MemoryCategory, session_id: ?[]const u8) ![]memory_root.MemoryEntry {
        const cat = if (category) |value| categoryToMemoryType(value) else null;
        if (cat != null and session_id != null) {
            return self.queryMemories(
                allocator,
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id FROM {schema}.memories WHERE user_id = $1 AND memory_type = $2 AND session_id = $3 ORDER BY updated_at DESC",
                user_id,
                cat.?,
                session_id.?,
            );
        }
        if (cat != null) {
            return self.queryMemories(
                allocator,
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id FROM {schema}.memories WHERE user_id = $1 AND memory_type = $2 ORDER BY updated_at DESC",
                user_id,
                cat.?,
                null,
            );
        }
        if (session_id != null) {
            return self.queryMemories(
                allocator,
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id FROM {schema}.memories WHERE user_id = $1 AND session_id = $2 ORDER BY updated_at DESC",
                user_id,
                session_id.?,
                null,
            );
        }
        return self.queryMemories(
            allocator,
            "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id FROM {schema}.memories WHERE user_id = $1 ORDER BY updated_at DESC",
            user_id,
            null,
            null,
        );
    }

    pub fn recallMemories(self: *Self, allocator: std.mem.Allocator, user_id: i64, query: []const u8, limit: usize, session_id: ?[]const u8) ![]memory_root.MemoryEntry {
        const limit_text = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_text);
        const limit_z = try self.allocator.dupeZ(u8, limit_text);
        defer self.allocator.free(limit_z);
        const like = try std.fmt.allocPrint(self.allocator, "%{s}%", .{query});
        defer self.allocator.free(like);
        const like_z = try self.allocator.dupeZ(u8, like);
        defer self.allocator.free(like_z);
        const q = try self.buildQuery(
            if (session_id != null)
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, " ++
                    "(CASE WHEN key ILIKE $2 THEN 2.0 ELSE 0.0 END + CASE WHEN content ILIKE $2 THEN 1.0 ELSE 0.0 END) AS score " ++
                    "FROM {schema}.memories WHERE user_id = $1 AND session_id = $4 AND (key ILIKE $2 OR content ILIKE $2) ORDER BY score DESC, updated_at DESC LIMIT $3"
            else
                "SELECT id, key, content, memory_type, COALESCE((EXTRACT(EPOCH FROM updated_at))::bigint::text, '0'), session_id, " ++
                    "(CASE WHEN key ILIKE $2 THEN 2.0 ELSE 0.0 END + CASE WHEN content ILIKE $2 THEN 1.0 ELSE 0.0 END) AS score " ++
                    "FROM {schema}.memories WHERE user_id = $1 AND (key ILIKE $2 OR content ILIKE $2) ORDER BY score DESC, updated_at DESC LIMIT $3",
        );
        defer self.allocator.free(q);
        var user_buf: [32]u8 = undefined;
        const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
        const session_text = session_id orelse "";
        const session_z = try self.allocator.dupeZ(u8, session_text);
        defer self.allocator.free(session_z);
        const result = if (session_id != null) blk: {
            const params = [_]?[*:0]const u8{ user_s.ptr, like_z, limit_z, session_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(like.len), @intCast(limit_text.len), @intCast(session_text.len) };
            break :blk try self.execParams(q, &params, &lengths);
        } else blk: {
            const params = [_]?[*:0]const u8{ user_s.ptr, like_z, limit_z };
            const lengths = [_]c_int{ @intCast(user_s.len), @intCast(like.len), @intCast(limit_text.len) };
            break :blk try self.execParams(q, &params, &lengths);
        };
        defer c.PQclear(result);
        return try decodeMemoryRows(allocator, result, true);
    }

    pub fn forgetMemory(self: *Self, user_id: i64, key: []const u8) !bool {
        const q = try self.buildQuery(
            "DELETE FROM {schema}.memories WHERE user_id = $1 AND key = $2",
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

    return .{
        .id = try dupeResultValue(allocator, result, row, 0),
        .key = try dupeResultValue(allocator, result, row, 1),
        .content = try dupeResultValue(allocator, result, row, 2),
        .category = try memoryTypeToCategory(allocator, mem_type),
        .timestamp = try dupeResultValue(allocator, result, row, 4),
        .session_id = sid,
        .score = null,
        .lane = lane,
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
            const score_text = try dupeResultValue(allocator, result, row, 6);
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
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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

    try std.testing.expect(std.mem.indexOf(u8, user2_jobs, "\"id\":\"morning-brief\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, user42_jobs, "\"id\":\"morning-brief\"") != null);

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
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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

test "postgres channel identity bindings upsert resolve list delete and backfill candidates" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
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
