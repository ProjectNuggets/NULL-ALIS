const std = @import("std");
const root = @import("../root.zig");
const zaki_state = @import("../../zaki_state.zig");

pub const ZakiPostgresMemory = struct {
    allocator: std.mem.Allocator,
    manager: *zaki_state.Manager,
    user_id: i64,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, manager: *zaki_state.Manager, user_id: i64) Self {
        return .{
            .allocator = allocator,
            .manager = manager,
            .user_id = user_id,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn memory(self: *Self) root.Memory {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn implName(_: *anyopaque) []const u8 {
        return "zaki_postgres";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: root.MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.manager.upsertMemory(self.user_id, key, content, category, session_id);
        // V1.7 Item 1: when a session summary lands, record a structured
        // episode event so sessions are queryable by the brain timeline.
        // Key shape: timeline_summary/{session_id}/{ts}
        // Best-effort — a logging failure must not break the store path.
        if (std.mem.startsWith(u8, key, "timeline_summary/")) {
            const after_prefix = key["timeline_summary/".len..];
            if (std.mem.lastIndexOfScalar(u8, after_prefix, '/')) |slash| {
                const ep_session = after_prefix[0..slash];
                self.manager.insertEpisodeEvent(self.user_id, ep_session, content, "checkpoint") catch |err| {
                    std.log.warn("zaki_postgres: episode event write failed session={s}: {}", .{ ep_session, err });
                };
            }
        }
    }

    /// V1.5 day-3 — write path with attached JSONB metadata. Used by
    /// the `compose_memory` tool to land synthesized memories with
    /// `{"synthesized_by":"agent","references":["k1","k2"]}` provenance
    /// alongside the synthesis content. Routes to
    /// `state_mgr.upsertMemoryWithMetadata` which also writes a
    /// `compose` row to the `memory_events` audit table for free V1.6
    /// traversal-logging substrate.
    fn implStoreWithMetadata(
        ptr: *anyopaque,
        key: []const u8,
        content: []const u8,
        category: root.MemoryCategory,
        session_id: ?[]const u8,
        metadata_json: []const u8,
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.manager.upsertMemoryWithMetadata(self.user_id, key, content, category, session_id, metadata_json);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.recallMemories(allocator, self.user_id, query, limit, session_id);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.getMemory(allocator, self.user_id, key);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?root.MemoryCategory, session_id: ?[]const u8) anyerror![]root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.listMemories(allocator, self.user_id, category, session_id);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.forgetMemory(self.user_id, key);
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.countMemories(self.user_id);
    }

    fn implHealthCheck(_: *anyopaque) bool {
        return true;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
        if (self.owns_self) self.allocator.destroy(self);
    }

    const vtable = root.Memory.VTable{
        .name = &implName,
        .store = &implStore,
        .recall = &implRecall,
        .get = &implGet,
        .list = &implList,
        .forget = &implForget,
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
        .store_with_metadata = &implStoreWithMetadata,
    };
};
