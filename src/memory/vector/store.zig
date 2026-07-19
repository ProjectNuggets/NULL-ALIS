//! VectorStore — vtable interface + SQLite shared implementation.
//!
//! Provides a generic vector store abstraction for embedding-based
//! similarity search, plus a concrete SQLite implementation that
//! shares the database handle with SqliteMemory (memory_embeddings table).

const std = @import("std");
const build_options = @import("build_options");
const meeting_memory = @import("../../meeting_memory.zig");
const Allocator = std.mem.Allocator;
const vector = @import("math.zig");
const sqlite_mod = if (build_options.enable_sqlite) @import("../engines/sqlite.zig") else @import("../engines/sqlite_disabled.zig");
const c = sqlite_mod.c;
const SQLITE_STATIC = sqlite_mod.SQLITE_STATIC;

// ── Health status ─────────────────────────────────────────────────

pub const HealthStatus = struct {
    ok: bool,
    latency_ns: u64,
    entry_count: ?usize,
    error_msg: ?[]const u8,

    pub fn deinit(self: *const HealthStatus, allocator: Allocator) void {
        if (self.error_msg) |msg| allocator.free(msg);
    }
};

// ── Result types ──────────────────────────────────────────────────

pub const VectorResult = struct {
    key: []const u8,
    score: f32, // cosine similarity [0,1]

    pub fn deinit(self: *const VectorResult, allocator: Allocator) void {
        allocator.free(self.key);
    }
};

pub fn freeVectorResults(allocator: Allocator, results: []VectorResult) void {
    for (results) |*r| r.deinit(allocator);
    allocator.free(results);
}

// ── Pairwise edge discovery (V1.5 day-2 task 2A) ───────────────────
//
// `EdgeResult` represents a single edge in the memory similarity graph:
// two memory keys (source, target) plus their cosine similarity. Used
// by `/brain/graph` to render semantic edges between memory nodes
// without N round-trips through `searchScoped`. Single SQL query in
// the pgvector backend.
//
// Convention: source_key < target_key lexicographically (canonical
// orientation; prevents duplicate edges in undirected graphs).

pub const EdgeResult = struct {
    source_key: []const u8,
    target_key: []const u8,
    similarity: f32,

    pub fn deinit(self: *const EdgeResult, allocator: Allocator) void {
        allocator.free(self.source_key);
        allocator.free(self.target_key);
    }
};

pub fn freeEdgeResults(allocator: Allocator, edges: []EdgeResult) void {
    for (edges) |*e| e.deinit(allocator);
    allocator.free(edges);
}

// ── VectorStore vtable ────────────────────────────────────────────

pub const VectorStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        upsert: *const fn (ptr: *anyopaque, scope_user_id: ?i64, key: []const u8, embedding: []const f32) anyerror!void,
        search: *const fn (ptr: *anyopaque, alloc: Allocator, scope_user_id: ?i64, query_embedding: []const f32, limit: u32) anyerror![]VectorResult,
        delete: *const fn (ptr: *anyopaque, scope_user_id: ?i64, key: []const u8) anyerror!void,
        /// S7.2 — bulk delete every embedding scoped to `user_id`. Used by
        /// the GDPR purgeUser orchestrator (`src/gdpr.zig`). Returns the
        /// number of rows removed for accounting.
        delete_all_for_user: *const fn (ptr: *anyopaque, user_id: i64) anyerror!usize,
        count: *const fn (ptr: *anyopaque) anyerror!usize,
        health_check: *const fn (ptr: *anyopaque, alloc: Allocator) anyerror!HealthStatus,
        deinit: *const fn (ptr: *anyopaque) void,
        /// V1.5 day-2 task 2A — optional pairwise similarity discovery
        /// for `/brain/graph` semantic edges. Returns edges (source,
        /// target, similarity) where both endpoints are in `key_set`,
        /// `source < target` lexicographically (canonical orientation),
        /// and `similarity > threshold`. When the backend doesn't
        /// support this (e.g. SqliteSharedVectorStore), the wrapper
        /// returns an empty slice — the graph endpoint degrades to
        /// session + reference edges only. PgVector backend implements
        /// it as a single self-join; cost is O(K · log K) with the
        /// ivfflat index covering up to `max_pairs` rows.
        pairwise_similarities: ?*const fn (
            ptr: *anyopaque,
            alloc: Allocator,
            scope_user_id: i64,
            key_set: []const []const u8,
            threshold: f32,
            max_pairs: u32,
        ) anyerror![]EdgeResult = null,
    };

    pub fn upsert(self: VectorStore, key: []const u8, embedding: []const f32) !void {
        return self.upsertScoped(null, key, embedding);
    }

    pub fn upsertScoped(self: VectorStore, scope_user_id: ?i64, key: []const u8, embedding: []const f32) !void {
        if (std.mem.startsWith(u8, key, meeting_memory.memory_key_prefix)) {
            return error.MeetingDerivedMemoryEmbeddingForbidden;
        }
        return self.vtable.upsert(self.ptr, scope_user_id, key, embedding);
    }

    pub fn search(self: VectorStore, alloc: Allocator, query_embedding: []const f32, limit: u32) ![]VectorResult {
        return self.searchScoped(alloc, null, query_embedding, limit);
    }

    pub fn searchScoped(self: VectorStore, alloc: Allocator, scope_user_id: ?i64, query_embedding: []const f32, limit: u32) ![]VectorResult {
        return self.vtable.search(self.ptr, alloc, scope_user_id, query_embedding, limit);
    }

    pub fn delete(self: VectorStore, key: []const u8) !void {
        return self.deleteScoped(null, key);
    }

    pub fn deleteScoped(self: VectorStore, scope_user_id: ?i64, key: []const u8) !void {
        return self.vtable.delete(self.ptr, scope_user_id, key);
    }

    /// S7.2 — bulk delete every embedding owned by `user_id`.
    /// Returns the count of rows removed.
    pub fn deleteAllForUser(self: VectorStore, user_id: i64) !usize {
        return self.vtable.delete_all_for_user(self.ptr, user_id);
    }

    pub fn count(self: VectorStore) !usize {
        return self.vtable.count(self.ptr);
    }

    pub fn healthCheck(self: VectorStore, alloc: Allocator) !HealthStatus {
        return self.vtable.health_check(self.ptr, alloc);
    }

    pub fn deinitStore(self: VectorStore) void {
        self.vtable.deinit(self.ptr);
    }

    /// V1.5 day-2 task 2A — pairwise similarity edge discovery for
    /// `/brain/graph`. Backends that don't implement the vtable slot
    /// return an empty slice (graceful degrade — graph still ships
    /// session + reference edges).
    pub fn pairwiseSimilarities(
        self: VectorStore,
        alloc: Allocator,
        user_id: i64,
        key_set: []const []const u8,
        threshold: f32,
        max_pairs: u32,
    ) ![]EdgeResult {
        if (self.vtable.pairwise_similarities) |fn_ptr| {
            return fn_ptr(self.ptr, alloc, user_id, key_set, threshold, max_pairs);
        }
        return alloc.alloc(EdgeResult, 0);
    }
};

// ── SqliteSharedVectorStore ───────────────────────────────────────

pub const SqliteSharedVectorStore = struct {
    db: ?*c.sqlite3, // borrowed from SqliteMemory — NOT owned
    allocator: Allocator,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: Allocator, db: ?*c.sqlite3) SqliteSharedVectorStore {
        var self = SqliteSharedVectorStore{
            .db = db,
            .allocator = allocator,
        };
        self.ensureSchema() catch {};
        return self;
    }

    pub fn store(self: *SqliteSharedVectorStore) VectorStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_instance,
        };
    }

    pub fn deinit(self: *SqliteSharedVectorStore) void {
        // Do NOT close the db — it's borrowed from SqliteMemory.
        if (self.owns_self) {
            self.allocator.destroy(self);
        }
    }

    fn ensureSchema(self: *const Self) !void {
        if (self.db == null) return error.PrepareFailed;

        if (try self.hasLegacySchema()) {
            const drop_sql = "DROP TABLE IF EXISTS memory_embeddings";
            if (c.sqlite3_exec(self.db, drop_sql, null, null, null) != c.SQLITE_OK) {
                return error.MigrationFailed;
            }
        }

        const create_sql =
            "CREATE TABLE IF NOT EXISTS memory_embeddings (" ++
            "user_id INTEGER NOT NULL DEFAULT 0, " ++
            "memory_key TEXT NOT NULL, " ++
            "embedding BLOB NOT NULL, " ++
            "updated_at TEXT NOT NULL DEFAULT (datetime('now')), " ++
            "PRIMARY KEY (user_id, memory_key))";
        if (c.sqlite3_exec(self.db, create_sql, null, null, null) != c.SQLITE_OK) {
            return error.MigrationFailed;
        }
    }

    fn hasLegacySchema(self: *const Self) !bool {
        const sql = "PRAGMA table_info(memory_embeddings)";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var saw_rows = false;
        while (true) {
            rc = c.sqlite3_step(stmt);
            if (rc != c.SQLITE_ROW) break;
            saw_rows = true;
            const name_ptr = c.sqlite3_column_text(stmt, 1);
            const name_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            if (name_ptr == null or name_len == 0) continue;
            const name = @as([*]const u8, @ptrCast(name_ptr))[0..name_len];
            if (std.mem.eql(u8, name, "user_id")) return false;
        }
        return saw_rows;
    }

    // ── vtable implementations ────────────────────────────────────

    fn implUpsert(ptr: *anyopaque, scope_user_id: ?i64, key: []const u8, embedding: []const f32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.ensureSchema();
        const user_id = scope_user_id orelse 0;

        const blob = try vector.vecToBytes(self.allocator, embedding);
        defer self.allocator.free(blob);

        const sql = "INSERT OR REPLACE INTO memory_embeddings (user_id, memory_key, embedding, updated_at) VALUES (?1, ?2, ?3, datetime('now'))";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 3, blob.ptr, @intCast(blob.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.StepFailed;
    }

    fn implSearch(ptr: *anyopaque, alloc: Allocator, scope_user_id: ?i64, query_embedding: []const f32, limit: u32) anyerror![]VectorResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.ensureSchema();

        const sql = "SELECT memory_key, embedding FROM memory_embeddings WHERE user_id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, scope_user_id orelse 0);

        var candidates: std.ArrayList(VectorResult) = .empty;
        errdefer {
            for (candidates.items) |*r| r.deinit(alloc);
            candidates.deinit(alloc);
        }

        while (true) {
            rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_ROW) {
                // Read key
                const key_ptr = c.sqlite3_column_text(stmt, 0);
                const key_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
                if (key_ptr == null) continue;

                // Read embedding blob
                const blob_ptr: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 1));
                const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

                if (blob_ptr == null or blob_len == 0) continue;

                const row_vec = try vector.bytesToVec(alloc, blob_ptr.?[0..blob_len]);
                defer alloc.free(row_vec);

                const score = vector.cosineSimilarity(query_embedding, row_vec);
                const owned_key = try alloc.dupe(u8, key_ptr[0..key_len]);
                errdefer alloc.free(owned_key);

                try candidates.append(alloc, .{
                    .key = owned_key,
                    .score = score,
                });
            } else break;
        }

        // Sort by score descending
        std.mem.sortUnstable(VectorResult, candidates.items, {}, struct {
            fn lessThan(_: void, a: VectorResult, b: VectorResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        // Truncate to limit
        const actual_limit = @min(@as(usize, limit), candidates.items.len);

        // Free excess results beyond the limit
        for (candidates.items[actual_limit..]) |*r| r.deinit(alloc);

        // Shrink the list and return owned slice
        const result = try alloc.dupe(VectorResult, candidates.items[0..actual_limit]);
        candidates.deinit(alloc);
        return result;
    }

    fn implDelete(ptr: *anyopaque, scope_user_id: ?i64, key: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.ensureSchema();

        const sql = "DELETE FROM memory_embeddings WHERE user_id = ?1 AND memory_key = ?2";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, scope_user_id orelse 0);
        _ = c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.StepFailed;
    }

    /// S7.2 — bulk delete every embedding for `user_id`. Called by the
    /// GDPR purgeUser orchestrator. Returns rows removed via
    /// sqlite3_changes (post-step, before finalize).
    fn implDeleteAllForUser(ptr: *anyopaque, user_id: i64) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.ensureSchema();

        const sql = "DELETE FROM memory_embeddings WHERE user_id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, user_id);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.StepFailed;

        const changed = c.sqlite3_changes(self.db);
        return if (changed < 0) 0 else @intCast(changed);
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.ensureSchema();

        const sql = "SELECT COUNT(*) FROM memory_embeddings";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const n = c.sqlite3_column_int64(stmt, 0);
            return @intCast(n);
        }
        return 0;
    }

    fn implHealthCheck(ptr: *anyopaque, alloc: Allocator) anyerror!HealthStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.ensureSchema() catch |err| {
            return HealthStatus{
                .ok = false,
                .latency_ns = 0,
                .entry_count = null,
                .error_msg = try alloc.dupe(u8, @errorName(err)),
            };
        };
        const start = std.time.nanoTimestamp();

        const sql = "SELECT COUNT(*) FROM memory_embeddings";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
            return HealthStatus{
                .ok = false,
                .latency_ns = elapsed,
                .entry_count = null,
                .error_msg = try alloc.dupe(u8, "sqlite prepare failed"),
            };
        }
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_step(stmt);
        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

        if (rc == c.SQLITE_ROW) {
            const n: usize = @intCast(c.sqlite3_column_int64(stmt, 0));
            return HealthStatus{
                .ok = true,
                .latency_ns = elapsed,
                .entry_count = n,
                .error_msg = null,
            };
        }

        return HealthStatus{
            .ok = false,
            .latency_ns = elapsed,
            .entry_count = null,
            .error_msg = try alloc.dupe(u8, "sqlite step failed"),
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
        .delete_all_for_user = &implDeleteAllForUser,
        .count = &implCount,
        .health_check = &implHealthCheck,
        .deinit = &implDeinit,
    };
};

// ── Sidecar vector store ──────────────────────────────────────────
//
// Opens its OWN SQLite database for vector storage.  Use this when the
// primary backend is *not* SQLite-based (markdown, postgres, redis, etc.).
// The sidecar owns the db handle and closes it on deinit.

pub const SqliteSidecarVectorStore = struct {
    db: ?*c.sqlite3,
    allocator: Allocator,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: Allocator, db_path: [*:0]const u8) !SqliteSidecarVectorStore {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        const shared = SqliteSharedVectorStore{
            .db = db,
            .allocator = allocator,
        };
        shared.ensureSchema() catch {
            _ = c.sqlite3_close(db);
            return error.MigrationFailed;
        };
        return .{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn store(self: *SqliteSidecarVectorStore) VectorStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &sidecar_vtable,
        };
    }

    pub fn deinit(self: *SqliteSidecarVectorStore) void {
        if (self.db) |d| _ = c.sqlite3_close(d);
        self.db = null;
        if (self.owns_self) {
            self.allocator.destroy(self);
        }
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    // Reuse shared vtable methods (same db schema, same struct layout).
    // Only deinit differs: sidecar closes its own db handle.
    // Safety: both structs must have `db` and `allocator` at the same offsets.
    comptime {
        const shared_db = @offsetOf(SqliteSharedVectorStore, "db");
        const shared_alloc = @offsetOf(SqliteSharedVectorStore, "allocator");
        const sidecar_db = @offsetOf(SqliteSidecarVectorStore, "db");
        const sidecar_alloc = @offsetOf(SqliteSidecarVectorStore, "allocator");
        if (shared_db != sidecar_db) @compileError("db field offset mismatch between Shared and Sidecar");
        if (shared_alloc != sidecar_alloc) @compileError("allocator field offset mismatch between Shared and Sidecar");
    }
    const sidecar_vtable = VectorStore.VTable{
        .upsert = SqliteSharedVectorStore.vtable_instance.upsert,
        .search = SqliteSharedVectorStore.vtable_instance.search,
        .delete = SqliteSharedVectorStore.vtable_instance.delete,
        .delete_all_for_user = SqliteSharedVectorStore.vtable_instance.delete_all_for_user,
        .count = SqliteSharedVectorStore.vtable_instance.count,
        .health_check = SqliteSharedVectorStore.vtable_instance.health_check,
        .deinit = &implDeinit,
    };
};

// ── Tests ─────────────────────────────────────────────────────────

const RecordingVectorBackend = struct {
    upsert_calls: usize = 0,

    const Self = @This();

    fn store(self: *Self) VectorStore {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_instance };
    }

    fn implUpsert(ptr: *anyopaque, _: ?i64, _: []const u8, _: []const f32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.upsert_calls += 1;
    }

    fn implSearch(_: *anyopaque, alloc: Allocator, _: ?i64, _: []const f32, _: u32) anyerror![]VectorResult {
        return alloc.alloc(VectorResult, 0);
    }

    fn implDelete(_: *anyopaque, _: ?i64, _: []const u8) anyerror!void {}
    fn implDeleteAllForUser(_: *anyopaque, _: i64) anyerror!usize {
        return 0;
    }
    fn implCount(_: *anyopaque) anyerror!usize {
        return 0;
    }
    fn implHealthCheck(_: *anyopaque, _: Allocator) anyerror!HealthStatus {
        return .{ .ok = true, .latency_ns = 0, .entry_count = 0, .error_msg = null };
    }
    fn implDeinit(_: *anyopaque) void {}

    const vtable_instance = VectorStore.VTable{
        .upsert = &implUpsert,
        .search = &implSearch,
        .delete = &implDelete,
        .delete_all_for_user = &implDeleteAllForUser,
        .count = &implCount,
        .health_check = &implHealthCheck,
        .deinit = &implDeinit,
    };
};

test "VectorStore rejects meeting-derived upserts before the backend boundary" {
    var backend = RecordingVectorBackend{};
    const store = backend.store();

    try std.testing.expectError(
        error.MeetingDerivedMemoryEmbeddingForbidden,
        store.upsertScoped(42, "meeting_ingest/not-yet-validated", &[_]f32{ 1.0, 0.0 }),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.upsert_calls);
}

test "init with in-memory sqlite" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const cnt = try s.count();
    try std.testing.expectEqual(@as(usize, 0), cnt);
}

test "upsert stores embedding then verify with count" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const emb = [_]f32{ 1.0, 2.0, 3.0 };
    try s.upsert("key1", &emb);

    const cnt = try s.count();
    try std.testing.expectEqual(@as(usize, 1), cnt);
}

test "upsert overwrites existing key" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const emb1 = [_]f32{ 1.0, 2.0, 3.0 };
    const emb2 = [_]f32{ 4.0, 5.0, 6.0 };
    try s.upsert("key1", &emb1);
    try s.upsert("key1", &emb2);

    const cnt = try s.count();
    try std.testing.expectEqual(@as(usize, 1), cnt);
}

test "scoped upsert allows same key for different users" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    try s.upsertScoped(1, "shared_key", &[_]f32{ 1.0, 0.0 });
    try s.upsertScoped(2, "shared_key", &[_]f32{ 0.0, 1.0 });

    try std.testing.expectEqual(@as(usize, 2), try s.count());
}

test "scoped search isolates user results" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    try s.upsertScoped(1, "shared_key", &[_]f32{ 1.0, 0.0 });
    try s.upsertScoped(2, "shared_key", &[_]f32{ 0.0, 1.0 });

    const user_one_results = try s.searchScoped(std.testing.allocator, 1, &[_]f32{ 1.0, 0.0 }, 5);
    defer freeVectorResults(std.testing.allocator, user_one_results);
    try std.testing.expectEqual(@as(usize, 1), user_one_results.len);
    try std.testing.expectEqualStrings("shared_key", user_one_results[0].key);

    const user_two_results = try s.searchScoped(std.testing.allocator, 2, &[_]f32{ 0.0, 1.0 }, 5);
    defer freeVectorResults(std.testing.allocator, user_two_results);
    try std.testing.expectEqual(@as(usize, 1), user_two_results.len);
    try std.testing.expectEqualStrings("shared_key", user_two_results[0].key);
}

test "S7.2 deleteAllForUser bulk-removes every row for the target user" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    // Seed 3 rows for user 1, 2 for user 2.
    try s.upsertScoped(1, "k1", &[_]f32{ 1.0, 0.0 });
    try s.upsertScoped(1, "k2", &[_]f32{ 0.0, 1.0 });
    try s.upsertScoped(1, "k3", &[_]f32{ 1.0, 1.0 });
    try s.upsertScoped(2, "k1", &[_]f32{ 0.5, 0.5 });
    try s.upsertScoped(2, "k2", &[_]f32{ 0.2, 0.8 });
    try std.testing.expectEqual(@as(usize, 5), try s.count());

    const removed = try s.deleteAllForUser(1);
    try std.testing.expectEqual(@as(usize, 3), removed);
    try std.testing.expectEqual(@as(usize, 2), try s.count());

    // User 2's rows survived.
    const u2_results = try s.searchScoped(std.testing.allocator, 2, &[_]f32{ 0.5, 0.5 }, 5);
    defer freeVectorResults(std.testing.allocator, u2_results);
    try std.testing.expectEqual(@as(usize, 2), u2_results.len);
}

test "S7.2 deleteAllForUser on absent user is a no-op" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    try s.upsertScoped(1, "k1", &[_]f32{ 1.0, 0.0 });
    const removed = try s.deleteAllForUser(999);
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), try s.count());
}

test "scoped delete only removes matching user key" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    try s.upsertScoped(1, "shared_key", &[_]f32{ 1.0, 0.0 });
    try s.upsertScoped(2, "shared_key", &[_]f32{ 0.0, 1.0 });

    try s.deleteScoped(1, "shared_key");

    const user_one_results = try s.searchScoped(std.testing.allocator, 1, &[_]f32{ 1.0, 0.0 }, 5);
    defer freeVectorResults(std.testing.allocator, user_one_results);
    try std.testing.expectEqual(@as(usize, 0), user_one_results.len);

    const user_two_results = try s.searchScoped(std.testing.allocator, 2, &[_]f32{ 0.0, 1.0 }, 5);
    defer freeVectorResults(std.testing.allocator, user_two_results);
    try std.testing.expectEqual(@as(usize, 1), user_two_results.len);
    try std.testing.expectEqualStrings("shared_key", user_two_results[0].key);
}

test "search returns sorted results" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();

    // Insert 3 items: a is very similar to query, b is less similar, c is orthogonal
    const query = [_]f32{ 1.0, 0.0, 0.0 };
    const emb_a = [_]f32{ 0.9, 0.1, 0.0 }; // very similar to query
    const emb_b = [_]f32{ 0.5, 0.5, 0.5 }; // partially similar
    const emb_c = [_]f32{ 0.0, 0.0, 1.0 }; // orthogonal

    try s.upsert("a", &emb_a);
    try s.upsert("b", &emb_b);
    try s.upsert("c", &emb_c);

    const results = try s.search(std.testing.allocator, &query, 3);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    // Best match should be "a"
    try std.testing.expectEqualStrings("a", results[0].key);
    // Scores should be descending
    try std.testing.expect(results[0].score >= results[1].score);
    try std.testing.expect(results[1].score >= results[2].score);
}

test "search with no data returns empty" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const query = [_]f32{ 1.0, 2.0, 3.0 };
    const results = try s.search(std.testing.allocator, &query, 10);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "search respects limit" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();

    // Insert 5 items
    var bufs: [5][8]u8 = undefined;
    for (0..5) |i| {
        const key = std.fmt.bufPrint(&bufs[i], "key_{d}", .{i}) catch "?";
        var emb = [_]f32{ 1.0, 0.0, 0.0 };
        emb[0] = 1.0 - @as(f32, @floatFromInt(i)) * 0.1;
        try s.upsert(key, &emb);
    }

    const results = try s.search(std.testing.allocator, &[_]f32{ 1.0, 0.0, 0.0 }, 2);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "delete removes embedding" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const emb = [_]f32{ 1.0, 2.0, 3.0 };
    try s.upsert("key1", &emb);
    try std.testing.expectEqual(@as(usize, 1), try s.count());

    try s.delete("key1");
    try std.testing.expectEqual(@as(usize, 0), try s.count());
}

test "delete non-existent key is no-op" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    // Should not error
    try s.delete("nonexistent");
    try std.testing.expectEqual(@as(usize, 0), try s.count());
}

test "count returns correct count" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    try std.testing.expectEqual(@as(usize, 0), try s.count());

    try s.upsert("a", &[_]f32{ 1.0, 0.0 });
    try std.testing.expectEqual(@as(usize, 1), try s.count());

    try s.upsert("b", &[_]f32{ 0.0, 1.0 });
    try std.testing.expectEqual(@as(usize, 2), try s.count());

    try s.upsert("c", &[_]f32{ 1.0, 1.0 });
    try std.testing.expectEqual(@as(usize, 3), try s.count());
}

test "VectorResult deinit frees key" {
    const allocator = std.testing.allocator;
    const key = try allocator.dupe(u8, "test_key");
    const r = VectorResult{ .key = key, .score = 0.5 };
    r.deinit(allocator);
    // No leak = pass (testing allocator detects leaks)
}

test "freeVectorResults frees slice" {
    const allocator = std.testing.allocator;
    var results = try allocator.alloc(VectorResult, 2);
    results[0] = .{ .key = try allocator.dupe(u8, "key_a"), .score = 0.9 };
    results[1] = .{ .key = try allocator.dupe(u8, "key_b"), .score = 0.5 };
    freeVectorResults(allocator, results);
    // No leak = pass
}

test "cosine similarity cross-check: exact match returns score near 1.0" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const emb = [_]f32{ 1.0, 2.0, 3.0 };
    try s.upsert("exact", &emb);

    const results = try s.search(std.testing.allocator, &emb, 1);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("exact", results[0].key);
    try std.testing.expect(@abs(results[0].score - 1.0) < 0.001);
}

test "round-trip: upsert then search finds the key" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const emb = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    try s.upsert("roundtrip_key", &emb);

    const results = try s.search(std.testing.allocator, &emb, 10);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("roundtrip_key", results[0].key);
    try std.testing.expect(results[0].score > 0.99);
}

test "multiple upserts + search returns best match" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();

    // Insert several items
    try s.upsert("north", &[_]f32{ 1.0, 0.0, 0.0 });
    try s.upsert("east", &[_]f32{ 0.0, 1.0, 0.0 });
    try s.upsert("up", &[_]f32{ 0.0, 0.0, 1.0 });
    try s.upsert("northeast", &[_]f32{ 0.7, 0.7, 0.0 });

    // Search for something close to "north"
    const query = [_]f32{ 0.95, 0.05, 0.0 };
    const results = try s.search(std.testing.allocator, &query, 4);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 4), results.len);
    // Best match should be "north"
    try std.testing.expectEqualStrings("north", results[0].key);
}

test "empty embedding handled gracefully" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const empty: []const f32 = &.{};

    // Upsert with empty vec should not crash
    try s.upsert("empty_key", empty);
    try std.testing.expectEqual(@as(usize, 1), try s.count());

    // Search with empty query should not crash (cosine returns 0 for empty)
    const results = try s.search(std.testing.allocator, empty, 10);
    defer freeVectorResults(std.testing.allocator, results);
    // The empty embedding row has 0-length blob, bytesToVec returns empty, cosine returns 0
    // Result is still returned (score = 0)
}

test "healthCheck returns ok with entry count" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();

    // Insert some data
    try s.upsert("hc_key1", &[_]f32{ 1.0, 0.0 });
    try s.upsert("hc_key2", &[_]f32{ 0.0, 1.0 });

    const status = try s.healthCheck(std.testing.allocator);
    defer status.deinit(std.testing.allocator);

    try std.testing.expect(status.ok);
    try std.testing.expect(status.latency_ns > 0);
    try std.testing.expectEqual(@as(?usize, 2), status.entry_count);
    try std.testing.expectEqual(@as(?[]const u8, null), status.error_msg);
}

test "healthCheck on empty store returns ok with zero count" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const status = try s.healthCheck(std.testing.allocator);
    defer status.deinit(std.testing.allocator);

    try std.testing.expect(status.ok);
    try std.testing.expectEqual(@as(?usize, 0), status.entry_count);
    try std.testing.expectEqual(@as(?[]const u8, null), status.error_msg);
}

test "HealthStatus deinit frees error_msg" {
    const allocator = std.testing.allocator;
    const msg = try allocator.dupe(u8, "test error");
    const status = HealthStatus{
        .ok = false,
        .latency_ns = 100,
        .entry_count = null,
        .error_msg = msg,
    };
    status.deinit(allocator);
    // No leak = pass (testing allocator detects leaks)
}

test "HealthStatus deinit with null error_msg is safe" {
    const status = HealthStatus{
        .ok = true,
        .latency_ns = 50,
        .entry_count = 42,
        .error_msg = null,
    };
    status.deinit(std.testing.allocator);
}

// ── R3 tests ──────────────────────────────────────────────────────

test "upsert same key updates embedding not duplicate" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();
    const emb1 = [_]f32{ 1.0, 0.0, 0.0 };
    const emb2 = [_]f32{ 0.0, 1.0, 0.0 };

    try s.upsert("same_key", &emb1);
    try std.testing.expectEqual(@as(usize, 1), try s.count());

    // Upsert again with different embedding
    try s.upsert("same_key", &emb2);
    try std.testing.expectEqual(@as(usize, 1), try s.count()); // still 1, not 2

    // Search with emb2 as query — should find "same_key" with high score
    const results = try s.search(std.testing.allocator, &emb2, 1);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("same_key", results[0].key);
    // Score should be ~1.0 since emb2 matches the stored embedding
    try std.testing.expect(results[0].score > 0.99);
}

test "search returns results sorted by similarity descending" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();

    // Insert vectors with known similarity to query [1,0,0]
    try s.upsert("exact", &[_]f32{ 1.0, 0.0, 0.0 }); // cosine = 1.0
    try s.upsert("close", &[_]f32{ 0.9, 0.1, 0.0 }); // cosine ~ 0.994
    try s.upsert("medium", &[_]f32{ 0.5, 0.5, 0.5 }); // cosine ~ 0.577
    try s.upsert("far", &[_]f32{ 0.0, 0.0, 1.0 }); // cosine = 0.0

    const query = [_]f32{ 1.0, 0.0, 0.0 };
    const results = try s.search(std.testing.allocator, &query, 4);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 4), results.len);

    // Verify descending order
    try std.testing.expectEqualStrings("exact", results[0].key);
    try std.testing.expect(results[0].score >= results[1].score);
    try std.testing.expect(results[1].score >= results[2].score);
    try std.testing.expect(results[2].score >= results[3].score);

    // Verify boundary scores
    try std.testing.expect(results[0].score > 0.99); // exact match
    try std.testing.expect(results[3].score < 0.01); // orthogonal
}

test "delete then search returns empty for deleted key" {
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();

    const emb = [_]f32{ 1.0, 0.0, 0.0 };
    try s.upsert("del_target", &emb);
    try s.upsert("keep_this", &[_]f32{ 0.0, 1.0, 0.0 });

    try std.testing.expectEqual(@as(usize, 2), try s.count());

    // Delete del_target
    try s.delete("del_target");
    try std.testing.expectEqual(@as(usize, 1), try s.count());

    // Search with del_target's embedding — should not find it
    const results = try s.search(std.testing.allocator, &emb, 10);
    defer freeVectorResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("keep_this", results[0].key);
}

// ── V1.5 day-2 task 2A — EdgeResult + pairwiseSimilarities ──

test "EdgeResult deinit frees both keys" {
    const src = try std.testing.allocator.dupe(u8, "memory_a");
    const dst = try std.testing.allocator.dupe(u8, "memory_b");
    const e = EdgeResult{
        .source_key = src,
        .target_key = dst,
        .similarity = 0.85,
    };
    e.deinit(std.testing.allocator);
    // No assertion; the test passes if the allocator's leak detector doesn't fire.
}

test "freeEdgeResults frees slice and all owned keys" {
    const edges = try std.testing.allocator.alloc(EdgeResult, 2);
    edges[0] = .{
        .source_key = try std.testing.allocator.dupe(u8, "k1"),
        .target_key = try std.testing.allocator.dupe(u8, "k2"),
        .similarity = 0.91,
    };
    edges[1] = .{
        .source_key = try std.testing.allocator.dupe(u8, "k3"),
        .target_key = try std.testing.allocator.dupe(u8, "k4"),
        .similarity = 0.72,
    };
    freeEdgeResults(std.testing.allocator, edges);
    // Allocator leak-detector verifies both keys + the slice were freed.
}

test "pairwiseSimilarities falls back to empty when backend has no fn pointer" {
    // SqliteSharedVectorStore intentionally does NOT implement pairwise
    // (no use case for /brain/graph in sqlite-only deployments). The
    // vtable's `pairwise_similarities` field defaults to null; the
    // wrapper returns an empty slice rather than erroring. This is the
    // "graceful degrade" path: graph endpoint still ships session +
    // reference edges; semantic edges silently absent.
    var mem = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    var vs = SqliteSharedVectorStore.init(std.testing.allocator, mem.db);
    defer vs.deinit();

    const s = vs.store();

    const keys = [_][]const u8{ "key_a", "key_b", "key_c" };
    const edges = try s.pairwiseSimilarities(std.testing.allocator, 1, &keys, 0.7, 100);
    defer freeEdgeResults(std.testing.allocator, edges);

    try std.testing.expectEqual(@as(usize, 0), edges.len);
}
