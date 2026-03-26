//! PgvectorVectorStore — VectorStore vtable adapter for PostgreSQL with pgvector.
//!
//! Implements the VectorStore interface using pgvector's cosine distance
//! operator (<=>) for similarity search. Feature-gated behind
//! build_options.enable_postgres.
//!
//! SQL schema:
//!   CREATE EXTENSION IF NOT EXISTS vector;
//!   CREATE TABLE IF NOT EXISTS memory_vectors (
//!     user_id   BIGINT NOT NULL,
//!     key       TEXT NOT NULL,
//!     embedding vector(N),
//!     updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
//!     PRIMARY KEY (user_id, key)
//!   );
//!   CREATE INDEX ON memory_vectors (user_id);
//!   CREATE INDEX ON memory_vectors USING ivfflat (embedding vector_cosine_ops);

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const store_mod = @import("store.zig");
const VectorStore = store_mod.VectorStore;
const VectorResult = store_mod.VectorResult;
const HealthStatus = store_mod.HealthStatus;
const log = std.log.scoped(.memory_pgvector);

const c = if (build_options.enable_postgres) @cImport({
    @cInclude("libpq-fe.h");
}) else struct {};

// ── Config ────────────────────────────────────────────────────────

pub const PgvectorConfig = struct {
    connection_url: []const u8,
    table_name: []const u8 = "memory_vectors",
    dimensions: u32,
    pool_max: u32 = 4,
    acquire_timeout_ms: u32 = 1_500,
};

/// Validate that a table name is a safe SQL identifier (alphanumeric + underscore, 1-63 chars).
/// Prevents SQL injection via user-controlled table names.
fn validateTableName(name: []const u8) !void {
    if (name.len == 0 or name.len > 63) return error.InvalidTableName;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidTableName;
    }
    if (std.ascii.isDigit(name[0])) return error.InvalidTableName;
}

// ── PgvectorVectorStore ───────────────────────────────────────────

const PoolEntry = if (build_options.enable_postgres) struct {
    conn: *c.PGconn,
    in_use: bool,
    last_used_s: i64,
} else struct {};

const ConnLease = if (build_options.enable_postgres) struct {
    conn: *c.PGconn,
    entry_index: usize,
    released: bool = false,
} else struct {};

pub const PoolDebugSnapshot = struct {
    pool_max: u32,
    open_conns: u32,
    in_use: u32,
    waiters: u32,
    acquire_timeouts: u64,
};

pub const PgvectorVectorStore = struct {
    allocator: Allocator,
    connection_url: []const u8,
    table_name: []const u8,
    dimensions: u32,
    owns_self: bool = false,

    pool_entries: if (build_options.enable_postgres) std.ArrayListUnmanaged(PoolEntry) else void,
    pool_mutex: if (build_options.enable_postgres) std.Thread.Mutex else void,
    pool_cond: if (build_options.enable_postgres) std.Thread.Condition else void,
    pool_max: u32,
    acquire_timeout_ms: u32,
    pool_opening: u32,
    pool_waiters: u32,
    pool_acquire_timeouts: u64,

    const Self = @This();

    pub fn init(allocator: Allocator, config: PgvectorConfig) !*Self {
        try validateTableName(config.table_name);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const owned_url = try allocator.dupe(u8, config.connection_url);
        errdefer allocator.free(owned_url);
        const owned_table = try allocator.dupe(u8, config.table_name);
        errdefer allocator.free(owned_table);

        self.* = .{
            .allocator = allocator,
            .connection_url = owned_url,
            .table_name = owned_table,
            .dimensions = config.dimensions,
            .owns_self = true,
            .pool_entries = if (build_options.enable_postgres) .empty else {},
            .pool_mutex = if (build_options.enable_postgres) .{} else {},
            .pool_cond = if (build_options.enable_postgres) .{} else {},
            .pool_max = std.math.clamp(config.pool_max, 1, 256),
            .acquire_timeout_ms = config.acquire_timeout_ms,
            .pool_opening = 0,
            .pool_waiters = 0,
            .pool_acquire_timeouts = 0,
        };

        if (build_options.enable_postgres) {
            errdefer self.closeAllPoolConns();
            try self.ensureSchema();
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        const alloc = self.allocator;
        if (build_options.enable_postgres) {
            self.closeAllPoolConns();
            self.pool_entries.deinit(self.allocator);
        }
        alloc.free(self.connection_url);
        alloc.free(self.table_name);
        if (self.owns_self) alloc.destroy(self);
    }

    pub fn store(self: *Self) VectorStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_instance,
        };
    }

    pub fn debugPoolSnapshot(self: *Self) PoolDebugSnapshot {
        if (!build_options.enable_postgres) {
            return .{
                .pool_max = self.pool_max,
                .open_conns = 0,
                .in_use = 0,
                .waiters = 0,
                .acquire_timeouts = 0,
            };
        }
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

    // ── Connection helpers ────────────────────────────────────────

    fn openConn(self: *Self) !*c.PGconn {
        if (!build_options.enable_postgres) return error.PgNotEnabled;
        const url_z = try self.allocator.dupeZ(u8, self.connection_url);
        defer self.allocator.free(url_z);

        const conn = c.PQconnectdb(url_z.ptr) orelse return error.PgConnectionFailed;
        errdefer c.PQfinish(conn);
        if (c.PQstatus(conn) != c.CONNECTION_OK) return error.PgConnectionFailed;
        return conn;
    }

    fn acquireConn(self: *Self, wait_ms: u32) !ConnLease {
        if (!build_options.enable_postgres) return error.PgNotEnabled;
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
        if (!build_options.enable_postgres) return;
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
        if (!build_options.enable_postgres) return;
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        for (self.pool_entries.items) |entry| {
            c.PQfinish(entry.conn);
        }
        self.pool_entries.clearRetainingCapacity();
    }

    fn acquireQueryLease(self: *Self) !ConnLease {
        return self.acquireConn(self.acquire_timeout_ms) catch |err| switch (err) {
            error.ConnectionPoolBusy => return error.PgConnectionFailed,
            else => return err,
        };
    }

    fn ensureSchema(self: *Self) !void {
        if (!build_options.enable_postgres) return;

        var lease = try self.acquireQueryLease();
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);
        const conn = lease.conn;

        {
            const sql = "CREATE EXTENSION IF NOT EXISTS vector";
            const result = c.PQexec(conn, sql) orelse {
                conn_healthy = false;
                return error.PgSchemaFailed;
            };
            defer c.PQclear(result);
            const status = c.PQresultStatus(result);
            if (status != c.PGRES_COMMAND_OK) {
                if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
                log.warn("pgvector extension ensure failed: {s}", .{pqErrorMessage(conn, result)});
                return error.PgSchemaFailed;
            }
        }

        if (try self.hasLegacySchema(conn)) {
            try self.resetLegacyTable(conn);
        }

        try self.createTable(conn);

        if (try self.readEmbeddingDimensions(conn)) |existing_dims| {
            if (existing_dims != self.dimensions) {
                log.warn(
                    "pgvector dimension mismatch for table '{s}': existing={d} expected={d}; rebuilding vector table",
                    .{ self.table_name, existing_dims, self.dimensions },
                );
                const drop_sql_plain = try std.fmt.allocPrint(self.allocator, "DROP TABLE IF EXISTS {s}", .{self.table_name});
                defer self.allocator.free(drop_sql_plain);
                const drop_sql = try self.allocator.dupeZ(u8, drop_sql_plain);
                defer self.allocator.free(drop_sql);
                const drop_result = c.PQexec(conn, drop_sql.ptr) orelse {
                    conn_healthy = false;
                    return error.PgSchemaFailed;
                };
                defer c.PQclear(drop_result);
                if (c.PQresultStatus(drop_result) != c.PGRES_COMMAND_OK) {
                    if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
                    log.warn("pgvector table drop failed: {s}", .{pqErrorMessage(conn, drop_result)});
                    return error.PgSchemaFailed;
                }
                try self.createTable(conn);
            }
        }
    }

    fn createTable(self: *Self, conn: *c.PGconn) !void {
        const create_sql_plain = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s} (
            \\  user_id BIGINT NOT NULL,
            \\  key TEXT NOT NULL,
            \\  embedding vector({d}),
            \\  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            \\  PRIMARY KEY (user_id, key)
            \\)
        , .{ self.table_name, self.dimensions });
        defer self.allocator.free(create_sql_plain);
        const create_sql = try self.allocator.dupeZ(u8, create_sql_plain);
        defer self.allocator.free(create_sql);

        const result = c.PQexec(conn, create_sql.ptr) orelse return error.PgSchemaFailed;
        defer c.PQclear(result);
        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK) {
            log.warn("pgvector table ensure failed: {s}", .{pqErrorMessage(conn, result)});
            return error.PgSchemaFailed;
        }

        const user_idx_plain = try std.fmt.allocPrint(self.allocator, "CREATE INDEX IF NOT EXISTS {s}_user_id_idx ON {s}(user_id)", .{ self.table_name, self.table_name });
        defer self.allocator.free(user_idx_plain);
        const user_idx = try self.allocator.dupeZ(u8, user_idx_plain);
        defer self.allocator.free(user_idx);
        const idx_result = c.PQexec(conn, user_idx.ptr) orelse return error.PgSchemaFailed;
        defer c.PQclear(idx_result);
        if (c.PQresultStatus(idx_result) != c.PGRES_COMMAND_OK) {
            log.warn("pgvector user index ensure failed: {s}", .{pqErrorMessage(conn, idx_result)});
            return error.PgSchemaFailed;
        }
    }

    fn hasLegacySchema(self: *Self, conn: *c.PGconn) !bool {
        const table_z = try self.allocator.dupeZ(u8, self.table_name);
        defer self.allocator.free(table_z);
        const sql =
            "SELECT 1 FROM information_schema.columns " ++
            "WHERE table_schema = current_schema() AND table_name = $1 AND column_name = 'user_id' LIMIT 1";
        const params = [_][*c]const u8{table_z.ptr};
        const result = c.PQexecParams(conn, sql, 1, null, &params, null, null, 0) orelse return error.PgQueryFailed;
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) return error.PgQueryFailed;
        return c.PQntuples(result) == 0 and try self.tableExists(conn);
    }

    fn tableExists(self: *Self, conn: *c.PGconn) !bool {
        const table_z = try self.allocator.dupeZ(u8, self.table_name);
        defer self.allocator.free(table_z);
        const sql =
            "SELECT 1 FROM information_schema.tables " ++
            "WHERE table_schema = current_schema() AND table_name = $1 LIMIT 1";
        const params = [_][*c]const u8{table_z.ptr};
        const result = c.PQexecParams(conn, sql, 1, null, &params, null, null, 0) orelse return error.PgQueryFailed;
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) return error.PgQueryFailed;
        return c.PQntuples(result) > 0;
    }

    fn resetLegacyTable(self: *Self, conn: *c.PGconn) !void {
        const drop_sql_plain = try std.fmt.allocPrint(self.allocator, "DROP TABLE IF EXISTS {s}", .{self.table_name});
        defer self.allocator.free(drop_sql_plain);
        const drop_sql = try self.allocator.dupeZ(u8, drop_sql_plain);
        defer self.allocator.free(drop_sql);
        const drop_result = c.PQexec(conn, drop_sql.ptr) orelse return error.PgSchemaFailed;
        defer c.PQclear(drop_result);
        if (c.PQresultStatus(drop_result) != c.PGRES_COMMAND_OK) {
            log.warn("pgvector legacy table reset failed: {s}", .{pqErrorMessage(conn, drop_result)});
            return error.PgSchemaFailed;
        }
    }

    fn readEmbeddingDimensions(self: *Self, conn: *c.PGconn) !?u32 {
        const table_z = try self.allocator.dupeZ(u8, self.table_name);
        defer self.allocator.free(table_z);
        const sql =
            "SELECT a.atttypmod FROM pg_attribute a " ++
            "JOIN pg_class c ON c.oid = a.attrelid " ++
            "JOIN pg_namespace n ON n.oid = c.relnamespace " ++
            "WHERE c.relname = $1 AND a.attname = 'embedding' " ++
            "AND a.attnum > 0 AND NOT a.attisdropped " ++
            "ORDER BY (n.nspname = current_schema()) DESC LIMIT 1";
        const params = [_][*c]const u8{table_z.ptr};
        const result = c.PQexecParams(conn, sql, 1, null, &params, null, null, 0) orelse return error.PgQueryFailed;
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            log.warn("pgvector dimension query failed: {s}", .{pqErrorMessage(conn, result)});
            return error.PgQueryFailed;
        }
        if (c.PQntuples(result) < 1) return null;
        const raw = c.PQgetvalue(result, 0, 0);
        if (raw == null) return null;
        const typmod_slice: []const u8 = std.mem.span(raw);
        const typmod = std.fmt.parseInt(i32, typmod_slice, 10) catch return null;
        if (typmod <= 0) return null;
        return @intCast(typmod);
    }

    fn pqErrorMessage(conn: *c.PGconn, result: ?*c.PGresult) []const u8 {
        if (result) |res| {
            const raw = c.PQresultErrorMessage(res);
            if (raw != null) {
                const msg = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
                if (msg.len > 0) return msg;
            }
        }
        const conn_raw = c.PQerrorMessage(conn);
        if (conn_raw != null) {
            const msg = std.mem.trim(u8, std.mem.span(conn_raw), " \t\r\n");
            if (msg.len > 0) return msg;
        }
        return "unknown postgres error";
    }

    // ── Vector formatting helpers ─────────────────────────────────

    pub fn formatVector(allocator: Allocator, embedding: []const f32) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.append(allocator, '[');
        for (embedding, 0..) |val, i| {
            if (i > 0) try buf.append(allocator, ',');
            if (std.math.isNan(val) or std.math.isInf(val)) return error.InvalidEmbeddingValue;
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return error.FormatError;
            try buf.appendSlice(allocator, s);
        }
        try buf.append(allocator, ']');

        return allocator.dupe(u8, buf.items);
    }

    // ── VTable implementations ────────────────────────────────────

    fn implUpsert(ptr: *anyopaque, scope_user_id: ?i64, key: []const u8, embedding: []const f32) anyerror!void {
        if (!build_options.enable_postgres) return error.PgNotEnabled;
        const self: *Self = @ptrCast(@alignCast(ptr));
        const alloc = self.allocator;
        const user_id = scope_user_id orelse 0;

        var lease = try self.acquireQueryLease();
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);
        const conn = lease.conn;

        const vec_str = try formatVector(alloc, embedding);
        defer alloc.free(vec_str);
        const vec_z = try alloc.dupeZ(u8, vec_str);
        defer alloc.free(vec_z);
        const key_z = try alloc.dupeZ(u8, key);
        defer alloc.free(key_z);
        var user_buf: [32]u8 = undefined;
        const user_str = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const sql_plain = try std.fmt.allocPrint(
            alloc,
            "INSERT INTO {s} (user_id, key, embedding, updated_at) VALUES ($1::bigint, $2, $3::vector, now()) " ++
                "ON CONFLICT (user_id, key) DO UPDATE SET embedding = $3::vector, updated_at = now()",
            .{self.table_name},
        );
        defer alloc.free(sql_plain);
        const sql = try alloc.dupeZ(u8, sql_plain);
        defer alloc.free(sql);

        const params = [_][*c]const u8{ user_str.ptr, key_z.ptr, vec_z.ptr };
        const result = c.PQexecParams(conn, sql.ptr, 3, null, &params, null, null, 0) orelse {
            conn_healthy = false;
            return error.PgQueryFailed;
        };
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK) {
            if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
            log.warn("pgvector upsert failed table={s} key={s}: {s}", .{ self.table_name, key, pqErrorMessage(conn, result) });
            return error.PgQueryFailed;
        }
    }

    fn implSearch(ptr: *anyopaque, alloc: Allocator, scope_user_id: ?i64, query_embedding: []const f32, limit: u32) anyerror![]VectorResult {
        if (!build_options.enable_postgres) return error.PgNotEnabled;
        const self: *Self = @ptrCast(@alignCast(ptr));
        const user_id = scope_user_id orelse 0;

        var lease = try self.acquireQueryLease();
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);
        const conn = lease.conn;

        const vec_str = try formatVector(alloc, query_embedding);
        defer alloc.free(vec_str);
        const vec_z = try alloc.dupeZ(u8, vec_str);
        defer alloc.free(vec_z);

        var limit_buf: [16]u8 = undefined;
        const limit_str = try std.fmt.bufPrintZ(&limit_buf, "{d}", .{limit});
        var user_buf: [32]u8 = undefined;
        const user_str = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const sql_plain = try std.fmt.allocPrint(
            alloc,
            "SELECT key, 1 - (embedding <=> $1::vector) AS similarity " ++
                "FROM {s} WHERE user_id = $2::bigint ORDER BY embedding <=> $1::vector LIMIT $3::int",
            .{self.table_name},
        );
        defer alloc.free(sql_plain);
        const sql = try alloc.dupeZ(u8, sql_plain);
        defer alloc.free(sql);

        const params = [_][*c]const u8{ vec_z.ptr, user_str.ptr, limit_str.ptr };
        const result = c.PQexecParams(conn, sql.ptr, 3, null, &params, null, null, 0) orelse {
            conn_healthy = false;
            return error.PgQueryFailed;
        };
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
            log.warn("pgvector search failed table={s}: {s}", .{ self.table_name, pqErrorMessage(conn, result) });
            return error.PgQueryFailed;
        }

        const nrows = c.PQntuples(result);
        var results: std.ArrayListUnmanaged(VectorResult) = .empty;
        errdefer {
            for (results.items) |*r| r.deinit(alloc);
            results.deinit(alloc);
        }

        var row: c_int = 0;
        while (row < nrows) : (row += 1) {
            const key_raw = c.PQgetvalue(result, row, 0);
            const sim_raw = c.PQgetvalue(result, row, 1);
            if (key_raw == null or sim_raw == null) continue;

            const key_slice: []const u8 = std.mem.span(key_raw);
            const sim_slice: []const u8 = std.mem.span(sim_raw);
            const score = std.fmt.parseFloat(f32, sim_slice) catch 0.0;
            const owned_key = try alloc.dupe(u8, key_slice);
            errdefer alloc.free(owned_key);
            try results.append(alloc, .{
                .key = owned_key,
                .score = score,
            });
        }

        const out = try alloc.dupe(VectorResult, results.items);
        results.deinit(alloc);
        return out;
    }

    fn implDelete(ptr: *anyopaque, scope_user_id: ?i64, key: []const u8) anyerror!void {
        if (!build_options.enable_postgres) return error.PgNotEnabled;
        const self: *Self = @ptrCast(@alignCast(ptr));
        const alloc = self.allocator;
        const user_id = scope_user_id orelse 0;

        var lease = try self.acquireQueryLease();
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);
        const conn = lease.conn;

        const key_z = try alloc.dupeZ(u8, key);
        defer alloc.free(key_z);
        var user_buf: [32]u8 = undefined;
        const user_str = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});

        const sql_plain = try std.fmt.allocPrint(alloc, "DELETE FROM {s} WHERE user_id = $1::bigint AND key = $2", .{self.table_name});
        defer alloc.free(sql_plain);
        const sql = try alloc.dupeZ(u8, sql_plain);
        defer alloc.free(sql);

        const params = [_][*c]const u8{ user_str.ptr, key_z.ptr };
        const result = c.PQexecParams(conn, sql.ptr, 2, null, &params, null, null, 0) orelse {
            conn_healthy = false;
            return error.PgQueryFailed;
        };
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK) {
            if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
            log.warn("pgvector delete failed table={s} key={s}: {s}", .{ self.table_name, key, pqErrorMessage(conn, result) });
            return error.PgQueryFailed;
        }
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        if (!build_options.enable_postgres) return error.PgNotEnabled;
        const self: *Self = @ptrCast(@alignCast(ptr));

        var lease = try self.acquireQueryLease();
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);
        const conn = lease.conn;

        const sql_plain = try std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s}", .{self.table_name});
        defer self.allocator.free(sql_plain);
        const sql = try self.allocator.dupeZ(u8, sql_plain);
        defer self.allocator.free(sql);

        const result = c.PQexec(conn, sql.ptr) orelse {
            conn_healthy = false;
            return error.PgQueryFailed;
        };
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
            log.warn("pgvector count failed table={s}: {s}", .{ self.table_name, pqErrorMessage(conn, result) });
            return error.PgQueryFailed;
        }
        if (c.PQntuples(result) < 1) return 0;

        const val_raw = c.PQgetvalue(result, 0, 0);
        if (val_raw == null) return 0;
        const val_slice: []const u8 = std.mem.span(val_raw);
        return std.fmt.parseInt(usize, val_slice, 10) catch 0;
    }

    fn implHealthCheck(ptr: *anyopaque, alloc: Allocator) anyerror!HealthStatus {
        if (!build_options.enable_postgres) {
            return HealthStatus{
                .ok = false,
                .latency_ns = 0,
                .entry_count = null,
                .error_msg = try alloc.dupe(u8, "pgvector not enabled"),
            };
        }

        const self: *Self = @ptrCast(@alignCast(ptr));
        const start = std.time.nanoTimestamp();

        var lease = self.acquireQueryLease() catch |err| {
            const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
            return HealthStatus{
                .ok = false,
                .latency_ns = elapsed,
                .entry_count = null,
                .error_msg = try alloc.dupe(u8, @errorName(err)),
            };
        };
        var conn_healthy = true;
        defer self.releaseConn(&lease, conn_healthy);
        const conn = lease.conn;

        const result = c.PQexec(conn, "SELECT 1") orelse {
            conn_healthy = false;
            const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
            return HealthStatus{
                .ok = false,
                .latency_ns = elapsed,
                .entry_count = null,
                .error_msg = try alloc.dupe(u8, "pgvector health check failed"),
            };
        };
        defer c.PQclear(result);

        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
            return HealthStatus{
                .ok = false,
                .latency_ns = elapsed,
                .entry_count = null,
                .error_msg = try alloc.dupe(u8, "pgvector health check failed"),
            };
        }

        const entry_count: ?usize = blk: {
            const count_sql_plain = try std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s}", .{self.table_name});
            defer self.allocator.free(count_sql_plain);
            const count_sql = try self.allocator.dupeZ(u8, count_sql_plain);
            defer self.allocator.free(count_sql);

            const count_result = c.PQexec(conn, count_sql.ptr) orelse {
                conn_healthy = false;
                break :blk null;
            };
            defer c.PQclear(count_result);
            if (c.PQresultStatus(count_result) != c.PGRES_TUPLES_OK) {
                if (c.PQstatus(conn) != c.CONNECTION_OK) conn_healthy = false;
                break :blk null;
            }
            if (c.PQntuples(count_result) < 1) break :blk null;
            const val_raw = c.PQgetvalue(count_result, 0, 0);
            if (val_raw == null) break :blk null;
            const val_slice: []const u8 = std.mem.span(val_raw);
            break :blk std.fmt.parseInt(usize, val_slice, 10) catch null;
        };

        return HealthStatus{
            .ok = true,
            .latency_ns = elapsed,
            .entry_count = entry_count,
            .error_msg = null,
        };
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable_instance = VectorStore.VTable{
        .upsert = &implUpsert,
        .search = &implSearch,
        .delete = &implDelete,
        .count = &implCount,
        .health_check = &implHealthCheck,
        .deinit = &implDeinit,
    };
};

// ── Tests ─────────────────────────────────────────────────────────

test "formatVector basic" {
    const embedding = [_]f32{ 0.1, 0.2, 0.3 };
    const result = try PgvectorVectorStore.formatVector(std.testing.allocator, &embedding);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[0.1,0.2,0.3]", result);
}

test "formatVector single element" {
    const embedding = [_]f32{1.5};
    const result = try PgvectorVectorStore.formatVector(std.testing.allocator, &embedding);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[1.5]", result);
}

test "formatVector empty" {
    const empty: []const f32 = &.{};
    const result = try PgvectorVectorStore.formatVector(std.testing.allocator, empty);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "formatVector negative values" {
    const embedding = [_]f32{ -0.5, 1.0, -3.14 };
    const result = try PgvectorVectorStore.formatVector(std.testing.allocator, &embedding);
    defer std.testing.allocator.free(result);
    try std.testing.expect(result[0] == '[');
    try std.testing.expect(result[result.len - 1] == ']');
    var comma_count: usize = 0;
    for (result) |ch| {
        if (ch == ',') comma_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), comma_count);
}

test "PgvectorVectorStore init and deinit without postgres" {
    if (build_options.enable_postgres) return;
    const self = try PgvectorVectorStore.init(std.testing.allocator, .{
        .connection_url = "postgresql://localhost/test",
        .dimensions = 768,
    });
    try std.testing.expectEqualStrings("postgresql://localhost/test", self.connection_url);
    try std.testing.expectEqualStrings("memory_vectors", self.table_name);
    try std.testing.expectEqual(@as(u32, 768), self.dimensions);
    try std.testing.expectEqual(@as(u32, 4), self.pool_max);
    self.deinit();
}

test "PgvectorVectorStore produces valid VectorStore vtable" {
    if (build_options.enable_postgres) return;
    var self = try PgvectorVectorStore.init(std.testing.allocator, .{
        .connection_url = "postgresql://localhost/test",
        .dimensions = 384,
    });
    const s = self.store();
    try std.testing.expect(s.vtable.upsert == &PgvectorVectorStore.implUpsert);
    try std.testing.expect(s.vtable.search == &PgvectorVectorStore.implSearch);
    try std.testing.expect(s.vtable.delete == &PgvectorVectorStore.implDelete);
    try std.testing.expect(s.vtable.count == &PgvectorVectorStore.implCount);
    try std.testing.expect(s.vtable.health_check == &PgvectorVectorStore.implHealthCheck);
    try std.testing.expect(s.vtable.deinit == &PgvectorVectorStore.implDeinit);
    s.deinitStore();
}

test "validateTableName rejects SQL injection" {
    try validateTableName("memory_vectors");
    try validateTableName("my_table_123");
    try std.testing.expectError(error.InvalidTableName, validateTableName("memory_vectors; DROP TABLE users;--"));
    try std.testing.expectError(error.InvalidTableName, validateTableName("table name"));
    try std.testing.expectError(error.InvalidTableName, validateTableName(""));
    try std.testing.expectError(error.InvalidTableName, validateTableName("123starts_with_digit"));
    try std.testing.expectError(error.InvalidTableName, validateTableName("has.dot"));
    try std.testing.expectError(error.InvalidTableName, validateTableName("has-hyphen"));
}

test "PgvectorVectorStore init rejects bad table name" {
    const result = PgvectorVectorStore.init(std.testing.allocator, .{
        .connection_url = "postgresql://localhost/test",
        .table_name = "bad; DROP TABLE users;--",
        .dimensions = 768,
    });
    try std.testing.expectError(error.InvalidTableName, result);
}

test "PgvectorVectorStore healthCheck disabled returns not-ok" {
    if (build_options.enable_postgres) return;
    var self = try PgvectorVectorStore.init(std.testing.allocator, .{
        .connection_url = "postgresql://localhost/test",
        .dimensions = 768,
    });
    const s = self.store();
    defer s.deinitStore();
    const status = try s.healthCheck(std.testing.allocator);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(!status.ok);
    try std.testing.expect(status.error_msg != null);
}

test "formatVector rejects NaN" {
    const embedding = [_]f32{ 0.1, std.math.nan(f32), 0.3 };
    const result = PgvectorVectorStore.formatVector(std.testing.allocator, &embedding);
    try std.testing.expectError(error.InvalidEmbeddingValue, result);
}

test "formatVector rejects positive Inf" {
    const embedding = [_]f32{ 0.1, std.math.inf(f32), 0.3 };
    const result = PgvectorVectorStore.formatVector(std.testing.allocator, &embedding);
    try std.testing.expectError(error.InvalidEmbeddingValue, result);
}

test "formatVector rejects negative Inf" {
    const embedding = [_]f32{ -std.math.inf(f32), 0.2, 0.3 };
    const result = PgvectorVectorStore.formatVector(std.testing.allocator, &embedding);
    try std.testing.expectError(error.InvalidEmbeddingValue, result);
}

fn initPostgresTestStoreWithPool(allocator: Allocator, pool_max: u32, acquire_timeout_ms: u32) !*PgvectorVectorStore {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const test_url = std.process.getEnvVarOwned(allocator, "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest;
    defer allocator.free(test_url);

    var table_buf: [64]u8 = undefined;
    const table_name = try std.fmt.bufPrint(&table_buf, "memory_vectors_test_{d}", .{std.time.microTimestamp()});

    return PgvectorVectorStore.init(allocator, .{
        .connection_url = test_url,
        .table_name = table_name,
        .dimensions = 8,
        .pool_max = pool_max,
        .acquire_timeout_ms = acquire_timeout_ms,
    });
}

fn dropPostgresTestTable(self: *PgvectorVectorStore) void {
    if (!build_options.enable_postgres) return;
    var lease = self.acquireConn(250) catch return;
    var conn_healthy = true;
    defer self.releaseConn(&lease, conn_healthy);

    const sql_plain = std.fmt.allocPrint(self.allocator, "DROP TABLE IF EXISTS {s}", .{self.table_name}) catch return;
    defer self.allocator.free(sql_plain);
    const sql = self.allocator.dupeZ(u8, sql_plain) catch return;
    defer self.allocator.free(sql);

    const result = c.PQexec(lease.conn, sql.ptr) orelse {
        conn_healthy = false;
        return;
    };
    defer c.PQclear(result);
    if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK and c.PQstatus(lease.conn) != c.CONNECTION_OK) {
        conn_healthy = false;
    }
}

test "pgvector_pool_enforces_cap_under_concurrency" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var self = try initPostgresTestStoreWithPool(allocator, 2, 500);
    defer {
        dropPostgresTestTable(self);
        self.deinit();
    }

    const WorkerCtx = struct {
        store: *PgvectorVectorStore,
        worker_id: usize,
    };
    const Worker = struct {
        fn run(ctx: *WorkerCtx) void {
            const iface = ctx.store.store();
            for (0..20) |i| {
                var key_buf: [96]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "pool-key-{d}-{d}", .{ ctx.worker_id, i }) catch continue;
                const embedding = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, @as(f32, @floatFromInt(ctx.worker_id)), @as(f32, @floatFromInt(i)) };
                iface.upsertScoped(@intCast(ctx.worker_id), key, &embedding) catch continue;
                if (i % 5 == 0) {
                    const results = iface.searchScoped(std.heap.page_allocator, @intCast(ctx.worker_id), &embedding, 3) catch continue;
                    store_mod.freeVectorResults(std.heap.page_allocator, results);
                }
            }
        }
    };

    var worker_ctx: [8]WorkerCtx = undefined;
    var threads: [8]std.Thread = undefined;
    for (0..threads.len) |idx| {
        worker_ctx[idx] = .{ .store = self, .worker_id = idx };
        threads[idx] = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Worker.run, .{&worker_ctx[idx]});
    }
    for (threads) |thread| thread.join();

    const snapshot = self.debugPoolSnapshot();
    try std.testing.expect(snapshot.open_conns <= snapshot.pool_max);
    try std.testing.expectEqual(@as(u32, 2), snapshot.pool_max);
}

test "pgvector_pool_reuses_connections" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var self = try initPostgresTestStoreWithPool(allocator, 2, 500);
    defer {
        dropPostgresTestTable(self);
        self.deinit();
    }
    const iface = self.store();
    const embedding = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 };

    try iface.upsertScoped(0, "reuse-key-0", &embedding);
    const first_snapshot = self.debugPoolSnapshot();

    for (0..25) |i| {
        var key_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "reuse-key-{d}", .{i});
        try iface.upsertScoped(0, key, &embedding);
        const results = try iface.searchScoped(allocator, 0, &embedding, 5);
        store_mod.freeVectorResults(allocator, results);
    }

    const final_snapshot = self.debugPoolSnapshot();
    try std.testing.expect(first_snapshot.open_conns >= 1);
    try std.testing.expect(final_snapshot.open_conns >= 1);
    try std.testing.expect(final_snapshot.open_conns <= 2);
    try std.testing.expect(final_snapshot.open_conns <= first_snapshot.open_conns + 1);
}

test "pgvector_pool_timeout_when_exhausted" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var self = try initPostgresTestStoreWithPool(allocator, 2, 30);
    defer {
        dropPostgresTestTable(self);
        self.deinit();
    }

    var lease_a = try self.acquireConn(0);
    defer self.releaseConn(&lease_a, true);
    var lease_b = try self.acquireConn(0);
    defer self.releaseConn(&lease_b, true);

    try std.testing.expectError(error.ConnectionPoolBusy, self.acquireConn(30));
    const snapshot = self.debugPoolSnapshot();
    try std.testing.expectEqual(@as(u32, 2), snapshot.in_use);
    try std.testing.expect(snapshot.open_conns <= snapshot.pool_max);
}

test "pgvector scoped keys can coexist across users" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var self = try initPostgresTestStoreWithPool(allocator, 2, 500);
    defer {
        dropPostgresTestTable(self);
        self.deinit();
    }

    const iface = self.store();
    try iface.upsertScoped(1, "shared-key", &[_]f32{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 });
    try iface.upsertScoped(2, "shared-key", &[_]f32{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 });

    const user_one_results = try iface.searchScoped(allocator, 1, &[_]f32{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, 5);
    defer store_mod.freeVectorResults(allocator, user_one_results);
    try std.testing.expectEqual(@as(usize, 1), user_one_results.len);
    try std.testing.expectEqualStrings("shared-key", user_one_results[0].key);

    const user_two_results = try iface.searchScoped(allocator, 2, &[_]f32{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, 5);
    defer store_mod.freeVectorResults(allocator, user_two_results);
    try std.testing.expectEqual(@as(usize, 1), user_two_results.len);
    try std.testing.expectEqualStrings("shared-key", user_two_results[0].key);
}

test "pgvector_pool_releases_on_query_error" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var self = try initPostgresTestStoreWithPool(allocator, 2, 500);
    defer {
        dropPostgresTestTable(self);
        self.deinit();
    }
    const iface = self.store();
    const original_table = self.table_name;
    self.table_name = "invalid table";

    if (iface.count()) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(err == error.PgQueryFailed or err == error.PgConnectionFailed);
    }

    const after_error = self.debugPoolSnapshot();
    try std.testing.expectEqual(@as(u32, 0), after_error.in_use);
    try std.testing.expect(after_error.open_conns <= after_error.pool_max);

    self.table_name = original_table;
    _ = try iface.count();
    const after_recovery = self.debugPoolSnapshot();
    try std.testing.expectEqual(@as(u32, 0), after_recovery.in_use);
}
