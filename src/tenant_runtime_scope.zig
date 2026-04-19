const std = @import("std");
const build_options = @import("build_options");
const Config = @import("config.zig").Config;
const tools_mod = @import("tools/root.zig");
const user_settings = @import("user_settings.zig");
const zaki_session = @import("session/root.zig");
const zaki_state = @import("zaki_state.zig");

pub const ScopedTenantRuntime = struct {
    user_id: ?[]u8 = null,
    numeric_user_id: ?i64 = null,
    workspace_dir: ?[]u8 = null,
    user_root: ?[]u8 = null,
    state_mgr: ?zaki_state.Manager = null,
    expect_postgres_state: bool = false,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.state_mgr) |*mgr| mgr.deinit();
        if (self.workspace_dir) |value| allocator.free(value);
        if (self.user_root) |value| allocator.free(value);
        if (self.user_id) |value| allocator.free(value);
    }

    pub fn hasTenantUser(self: *const @This()) bool {
        return self.user_id != null and self.numeric_user_id != null;
    }

    pub fn tenantContext(self: *@This(), session_key: ?[]const u8) tools_mod.ToolTenantContext {
        return .{
            .user_id = self.user_id,
            .numeric_user_id = self.numeric_user_id,
            .session_key = session_key,
            .state_mgr = if (self.state_mgr) |*mgr| mgr else null,
            .expect_postgres_state = self.expect_postgres_state and self.user_id != null,
            .user_root = self.user_root,
        };
    }
};

pub fn tenantWorkspacePathForUser(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    user_id: []const u8,
) ![]u8 {
    if (cfg.tenant.data_root.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}/{s}/workspace", .{ cfg.tenant.data_root, user_id });
    }
    return allocator.dupe(u8, cfg.workspace_dir);
}

/// User-scoped filesystem root for file-backed tenant state and secrets.
/// In tenant mode this is `<data_root>/<user_id>`; otherwise we derive it
/// from the non-workspace parent of `workspace_dir` (mirrors
/// `runtime_info.zig` semantics) so local/CLI runs still find
/// `channel_state.json` and `secrets/*` when state_mgr is null.
pub fn tenantUserRootForUser(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    user_id: []const u8,
) ![]u8 {
    if (cfg.tenant.data_root.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.tenant.data_root, user_id });
    }
    const user_root = std.fs.path.dirname(cfg.workspace_dir) orelse cfg.workspace_dir;
    return allocator.dupe(u8, user_root);
}

pub fn resolveForAgentSession(
    allocator: std.mem.Allocator,
    cfg: *Config,
    session_key: ?[]const u8,
    explicit_user_id: ?[]const u8,
) !ScopedTenantRuntime {
    var scoped: ScopedTenantRuntime = .{};
    errdefer scoped.deinit(allocator);

    const raw_user_id = blk: {
        if (explicit_user_id) |user_id| {
            const trimmed = std.mem.trim(u8, user_id, " \t\r\n");
            if (trimmed.len > 0) break :blk trimmed;
        }
        if (session_key) |key| {
            if (zaki_session.parseUserIdFromSessionKey(key)) |user_id| break :blk user_id;
        }
        break :blk null;
    };
    if (raw_user_id == null) return scoped;

    scoped.user_id = try allocator.dupe(u8, raw_user_id.?);
    scoped.numeric_user_id = std.fmt.parseInt(i64, scoped.user_id.?, 10) catch return error.InvalidTenantUserId;
    scoped.workspace_dir = try tenantWorkspacePathForUser(allocator, cfg, scoped.user_id.?);
    scoped.user_root = try tenantUserRootForUser(allocator, cfg, scoped.user_id.?);
    cfg.workspace_dir = scoped.workspace_dir.?;

    scoped.expect_postgres_state = cfg.tenant.enabled and
        std.mem.eql(u8, cfg.state.backend, "postgres") and
        build_options.enable_postgres;

    if (!scoped.expect_postgres_state) return scoped;

    scoped.state_mgr = try zaki_state.Manager.init(allocator, cfg.state);
    try scoped.state_mgr.?.provisionUser(scoped.numeric_user_id.?, scoped.workspace_dir.?);

    const user_config_json = scoped.state_mgr.?.getConfigJson(allocator, scoped.numeric_user_id.?) catch null;
    if (user_config_json) |json| {
        defer allocator.free(json);
        const trimmed = std.mem.trim(u8, json, " \t\r\n");
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "{}")) {
            if (user_settings.normalizeTenantConfigJson(allocator, trimmed)) |normalized| {
                defer allocator.free(normalized.json);
                cfg.parseJson(normalized.json) catch {};
                cfg.applyProfileDefaults() catch {};
                cfg.memory.applyProfileDefaults();
                user_settings.applySettingsToConfig(cfg, normalized.settings);
            } else |_| {}
        }
    }

    // User-scoped runtime must keep the tenant workspace even after config overlays.
    cfg.workspace_dir = scoped.workspace_dir.?;
    return scoped;
}

test "tenantWorkspacePathForUser uses tenant data root" {
    var cfg = Config{
        .workspace_dir = "/tmp/global/workspace",
        .config_path = "/tmp/global/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.data_root = "/tmp/users";
    const path = try tenantWorkspacePathForUser(std.testing.allocator, &cfg, "7");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/users/7/workspace", path);
}

test "tenantUserRootForUser derives parent of local workspace" {
    var cfg = Config{
        .workspace_dir = "/tmp/local-user/workspace",
        .config_path = "/tmp/local-user/config.json",
        .allocator = std.testing.allocator,
    };
    const path = try tenantUserRootForUser(std.testing.allocator, &cfg, "7");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/local-user", path);
}

test "resolveForAgentSession scopes workspace from canonical tenant session key" {
    var cfg = Config{
        .workspace_dir = "/tmp/global/workspace",
        .config_path = "/tmp/global/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.tenant.data_root = "/tmp/users";
    cfg.state.backend = "file";

    var scoped = try resolveForAgentSession(
        std.testing.allocator,
        &cfg,
        "agent:zaki-bot:user:42:main",
        null,
    );
    defer scoped.deinit(std.testing.allocator);

    try std.testing.expect(scoped.hasTenantUser());
    try std.testing.expectEqualStrings("42", scoped.user_id.?);
    try std.testing.expectEqualStrings("/tmp/users/42/workspace", cfg.workspace_dir);
}
