//! Skill Registry Tool — install/search/list skills with Decision Hub integration.

const std = @import("std");
const root = @import("root.zig");
const skills_mod = @import("../skills.zig");

const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const SkillRegistryTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "skill_registry";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Manage skills. Actions: list installed skills, search Decision Hub skills, install a skill from Deci",
        .use_when = &.{
            "first scenario",
            "second scenario",
        },
        .do_not_use_for = &.{
            "web_search — for web queries",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("skill_registry", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Manage skills. Actions: list installed skills, search Decision Hub skills, install a skill from Decision Hub, and remove locally installed skills.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["list","search","install","remove","uninstall"],"default":"list"},"query":{"type":"string","description":"Natural-language search query or install target query"},"skill_ref":{"type":"string","description":"Decision Hub reference org/skill for install"},"name":{"type":"string","description":"Local installed skill name for remove/uninstall"},"count":{"type":"integer","minimum":1,"maximum":20,"default":5},"spec":{"type":"string","description":"Version spec for install (default latest)"},"allow_risky":{"type":"boolean","default":false,"description":"Allow C-grade risky skills on install"}}}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SkillRegistryTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *SkillRegistryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse "list";
        if (std.ascii.eqlIgnoreCase(action, "list")) return try listInstalled(self, allocator);
        if (std.ascii.eqlIgnoreCase(action, "search")) return try searchRegistry(allocator, args);
        if (std.ascii.eqlIgnoreCase(action, "install")) return try installSkill(self, allocator, args);
        if (std.ascii.eqlIgnoreCase(action, "remove") or std.ascii.eqlIgnoreCase(action, "uninstall")) return try removeSkill(self, allocator, args);
        const msg = try std.fmt.allocPrint(allocator, "Unknown action '{s}'. Use list|search|install|remove.", .{action});
        return .{ .success = false, .output = "", .error_msg = msg };
    }
};

fn parseCount(args: JsonObjectMap) usize {
    const raw = root.getInt(args, "count") orelse 5;
    if (raw < 1) return 1;
    if (raw > 20) return 20;
    return @intCast(raw);
}

fn listInstalled(self: *SkillRegistryTool, allocator: std.mem.Allocator) !ToolResult {
    const skills = try skills_mod.listSkills(allocator, self.workspace_dir);
    defer skills_mod.freeSkills(allocator, skills);
    if (skills.len == 0) {
        return ToolResult.ok("No skills installed.");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("Installed skills ({d}):\n", .{skills.len});
    for (skills) |skill| {
        try w.print("- {s} v{s}", .{ skill.name, skill.version });
        if (skill.description.len > 0) try w.print(" — {s}", .{skill.description});
        if (!skill.available) try w.print(" (unavailable: {s})", .{skill.missing_deps});
        try w.writeByte('\n');
    }
    return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
}

fn searchRegistry(allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
    const query = root.getString(args, "query") orelse {
        return ToolResult.fail("Missing 'query'. Use action=search with query text.");
    };
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return ToolResult.fail("'query' must not be empty.");

    const count = parseCount(args);
    const results = skills_mod.searchDecisionHubSkills(allocator, trimmed, count) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Decision Hub search failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer skills_mod.freeDecisionHubSearchResults(allocator, results);
    if (results.len == 0) {
        return ToolResult.ok("No matching skills found in Decision Hub.");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("Decision Hub results ({d}):\n", .{results.len});
    for (results) |item| {
        try w.print("- {s}/{s}", .{ item.org_slug, item.skill_name });
        if (item.latest_version.len > 0) try w.print(" @ {s}", .{item.latest_version});
        if (item.safety_rating.len > 0) try w.print(" [grade {s}]", .{item.safety_rating});
        if (item.description.len > 0) try w.print(" — {s}", .{item.description});
        try w.writeByte('\n');
    }
    return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
}

fn installSkill(self: *SkillRegistryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
    const skill_ref = root.getString(args, "skill_ref");
    const query = root.getString(args, "query");
    const target = if (skill_ref) |r| r else if (query) |q| q else {
        return ToolResult.fail("Missing target. Use skill_ref=org/skill or query=natural language.");
    };
    const trimmed_target = std.mem.trim(u8, target, " \t\r\n");
    if (trimmed_target.len == 0) {
        return ToolResult.fail("Install target must not be empty.");
    }

    const spec = std.mem.trim(u8, root.getString(args, "spec") orelse "latest", " \t\r\n");
    const options = skills_mod.DecisionHubInstallOptions{
        .spec = if (spec.len == 0) "latest" else spec,
        .allow_risky = root.getBool(args, "allow_risky") orelse false,
    };

    const installed = skills_mod.installSkillFromDecisionHubQueryOrRef(allocator, trimmed_target, self.workspace_dir, options) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Skill install failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer skills_mod.freeDecisionHubInstallResult(allocator, &installed);

    const msg = try std.fmt.allocPrint(
        allocator,
        "Installed {s}/{s}@{s} as local skill `{s}`. It is now available for /skill and next-turn prompt loading.",
        .{ installed.org_slug, installed.skill_name, installed.resolved_version, installed.installed_name },
    );
    return .{ .success = true, .output = msg };
}

fn removeSkill(self: *SkillRegistryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
    const raw_name = root.getString(args, "name") orelse {
        return ToolResult.fail("Missing 'name'. Use action=remove with local skill name.");
    };
    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    if (name.len == 0) return ToolResult.fail("'name' must not be empty.");

    skills_mod.removeSkill(allocator, name, self.workspace_dir) catch |err| {
        return switch (err) {
            error.SkillNotFound => ToolResult.fail("Skill not found."),
            error.UnsafeName => ToolResult.fail("Invalid skill name."),
            else => ToolResult.fail("Skill remove failed."),
        };
    };

    return ToolResult.ok("Removed local skill.");
}

test "skill_registry list action handles empty workspace" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var tool = SkillRegistryTool{ .workspace_dir = workspace };
    var parsed = try root.parseTestArgs("{\"action\":\"list\"}");
    defer parsed.deinit();
    const result = try tool.execute(allocator, parsed.value.object);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No skills installed") != null);
}

test "skill_registry search action requires query" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var tool = SkillRegistryTool{ .workspace_dir = workspace };
    var parsed = try root.parseTestArgs("{\"action\":\"search\"}");
    defer parsed.deinit();
    const result = try tool.execute(allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing 'query'") != null);
}

test "skill_registry remove action requires name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var tool = SkillRegistryTool{ .workspace_dir = workspace };
    var parsed = try root.parseTestArgs("{\"action\":\"remove\"}");
    defer parsed.deinit();
    const result = try tool.execute(allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing 'name'") != null);
}

test "skill_registry remove action returns not found" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var tool = SkillRegistryTool{ .workspace_dir = workspace };
    var parsed = try root.parseTestArgs("{\"action\":\"remove\",\"name\":\"ghost\"}");
    defer parsed.deinit();
    const result = try tool.execute(allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Skill not found.") != null);
}

test "skill_registry remove action deletes installed skill" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    const skills_root = try std.fs.path.join(allocator, &.{ workspace, "skills" });
    defer allocator.free(skills_root);
    try std.fs.makeDirAbsolute(skills_root);

    const skills_dir = try std.fs.path.join(allocator, &.{ workspace, "skills", "temp-skill" });
    defer allocator.free(skills_dir);
    try std.fs.makeDirAbsolute(skills_dir);

    const marker_path = try std.fs.path.join(allocator, &.{ skills_dir, "skill.json" });
    defer allocator.free(marker_path);
    const marker_file = try std.fs.createFileAbsolute(marker_path, .{});
    marker_file.close();

    var tool = SkillRegistryTool{ .workspace_dir = workspace };
    var parsed = try root.parseTestArgs("{\"action\":\"remove\",\"name\":\"temp-skill\"}");
    defer parsed.deinit();
    const result = try tool.execute(allocator, parsed.value.object);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Removed local skill.") != null);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(skills_dir, .{}));
}
