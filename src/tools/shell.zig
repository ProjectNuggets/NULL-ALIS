const std = @import("std");
const platform = @import("../platform.zig");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const isResolvedPathAllowed = @import("path_security.zig").isResolvedPathAllowed;
const SecurityPolicy = @import("../security/policy.zig").SecurityPolicy;
const config_types = @import("../config_types.zig");
const tool_sandbox_v1 = @import("tool_sandbox_v1.zig");
const memory_mod = @import("../memory/root.zig");
const UNAVAILABLE_WORKSPACE_SENTINEL = "/__nullalis_workspace_unavailable__";
const log = std.log.scoped(.shell_tool);

/// Default maximum shell command execution time (nanoseconds).
const DEFAULT_SHELL_TIMEOUT_NS: u64 = 60 * std.time.ns_per_s;
/// Default maximum output size in bytes (1MB).
const DEFAULT_MAX_OUTPUT_BYTES: usize = 1_048_576;
/// Environment variables safe to pass to shell commands.
const SAFE_ENV_VARS = [_][]const u8{
    "PATH", "HOME", "TERM", "LANG", "LC_ALL", "LC_CTYPE", "USER", "SHELL", "TMPDIR",
};

/// Shell command execution tool with workspace scoping.
pub const ShellTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    timeout_ns: u64 = DEFAULT_SHELL_TIMEOUT_NS,
    max_output_bytes: usize = DEFAULT_MAX_OUTPUT_BYTES,
    policy: ?*const SecurityPolicy = null,
    sandbox_enabled: bool = false,
    sandbox_backend: config_types.SandboxBackend = .auto,
    /// Optional memory store for command audit trail.
    audit_memory: ?memory_mod.Memory = null,
    /// Session ID for scoping audit entries.
    audit_session_id: ?[]const u8 = null,

    pub const tool_name = "shell";
    pub const tool_description = "Execute a shell command when policy allows and no more specific tool is better.";
    pub const tool_params =
        \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"},"cwd":{"type":"string","description":"Working directory (absolute path within allowed paths; defaults to workspace)"}},"required":["command"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ShellTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ShellTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // Parse the command from the pre-parsed JSON object
        const command = root.getString(args, "command") orelse
            return ToolResult.fail("Missing 'command' parameter");

        // Validate command against security policy
        if (self.policy) |pol| {
            _ = pol.validateCommandExecution(command, false) catch |err| {
                return switch (err) {
                    error.CommandNotAllowed => ToolResult.fail("Command not allowed by security policy"),
                    error.HighRiskBlocked => ToolResult.fail("High-risk command blocked by security policy"),
                    error.ApprovalRequired => ToolResult.fail("Command requires approval (medium/high risk)"),
                };
            };

            // workspace_only cross-tenant guard. Shell's `cwd` is path-gated
            // above, but shell COMMAND ARGUMENTS (e.g. `cat /other/user/path`)
            // are not — they execute with the process UID and can read any
            // file the process can read. In shared-runtime tenant mode
            // (single binary serving many user_ids via same UID) that's a
            // cross-tenant read vector. When `policy.workspace_only=true`
            // and sandbox isn't enabled, we require the runtime to either:
            //   (a) enable `sandbox.enabled=true` (proper filesystem jail), or
            //   (b) explicitly set `autonomy.workspace_only=false` to
            //       acknowledge the trust model (e.g. per-user pod).
            // In tenant mode we refuse outright; in single-user/pod mode
            // we log a warning but allow — the pod's process isolation
            // provides the boundary.
            if (pol.workspace_only and !self.sandbox_enabled) {
                const tenant_ctx = root.getTenantContext();
                if (tenant_ctx.expect_postgres_state) {
                    return ToolResult.fail(
                        "shell disabled in multi-tenant runtime: enable sandbox.enabled=true or set autonomy.workspace_only=false. Shell command arguments bypass cwd gating and can read cross-tenant files via process UID.",
                    );
                }
                // Single-user/per-pod mode: allow with a one-line audit log
                // so the choice is visible in operator logs.
                std.log.scoped(.shell).debug(
                    "workspace_only=true, sandbox disabled, single-tenant — allowing shell under process isolation",
                    .{},
                );
            }
        }

        // Determine working directory
        const effective_cwd = if (root.getString(args, "cwd")) |cwd| blk: {
            // cwd must be absolute
            if (cwd.len == 0 or !std.fs.path.isAbsolute(cwd))
                return ToolResult.fail("cwd must be an absolute path");
            // Resolve and validate
            const resolved_cwd = std.fs.cwd().realpathAlloc(allocator, cwd) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to resolve cwd: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            defer allocator.free(resolved_cwd);

            const ws_resolved: ?[]const u8 = std.fs.cwd().realpathAlloc(allocator, self.workspace_dir) catch null;
            defer if (ws_resolved) |wr| allocator.free(wr);
            if (ws_resolved == null and self.allowed_paths.len == 0)
                return ToolResult.fail("cwd not allowed (workspace unavailable and no allowed_paths configured)");

            if (!isResolvedPathAllowed(allocator, resolved_cwd, ws_resolved orelse UNAVAILABLE_WORKSPACE_SENTINEL, self.allowed_paths))
                return ToolResult.fail("cwd is outside allowed areas");

            break :blk cwd;
        } else self.workspace_dir;

        // Clear environment to prevent leaking API keys (CWE-200),
        // then re-add only safe, functional variables.
        var env = std.process.EnvMap.init(allocator);
        defer env.deinit();
        for (&SAFE_ENV_VARS) |key| {
            if (platform.getEnvOrNull(allocator, key)) |val| {
                defer allocator.free(val);
                try env.put(key, val);
            }
        }

        // Execute via platform shell
        const result = tool_sandbox_v1.run_with_optional_sandbox(
            allocator,
            .{
                .enabled = self.sandbox_enabled,
                .backend = self.sandbox_backend,
                .workspace_dir = self.workspace_dir,
                .allowed_roots = self.allowed_paths,
            },
            &.{ platform.getShell(), platform.getShellFlag(), command },
            .{
                .cwd = effective_cwd,
                .env_map = &env,
                .max_output_bytes = self.max_output_bytes,
            },
        ) catch |err| {
            return switch (err) {
                error.SandboxUnavailable => ToolResult.fail("Sandbox unavailable for shell execution"),
                error.SandboxArgvTooLong => ToolResult.fail("Sandbox argv exceeds fixed tool limit"),
                else => ToolResult.fail("Shell execution failed in sandbox"),
            };
        };
        defer allocator.free(result.stderr);

        // Audit trail: log command execution to memory (best-effort)
        self.recordAuditEntry(allocator, command, effective_cwd, result.success, result.exit_code);

        if (result.success) {
            if (result.stdout.len > 0) return ToolResult{ .success = true, .output = result.stdout };
            allocator.free(result.stdout);
            return ToolResult{ .success = true, .output = try allocator.dupe(u8, "(no output)") };
        }
        defer allocator.free(result.stdout);
        if (result.exit_code != null) {
            const err_out = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "Command failed with non-zero exit code");
            return ToolResult{ .success = false, .output = "", .error_msg = err_out };
        }
        return ToolResult{ .success = false, .output = "", .error_msg = "Command terminated by signal" };
    }

    /// Record a durable audit entry for a shell command execution.
    fn recordAuditEntry(
        self: *const ShellTool,
        allocator: std.mem.Allocator,
        command: []const u8,
        cwd: []const u8,
        success: bool,
        exit_code: ?u32,
    ) void {
        const mem = self.audit_memory orelse return;

        const ts: u128 = @bitCast(std.time.nanoTimestamp());
        const key = std.fmt.allocPrint(allocator, "audit_shell/{d}", .{ts}) catch return;
        defer allocator.free(key);

        // Truncate command for audit (keep first 500 chars)
        const cmd_display = if (command.len > 500) command[0..500] else command;
        const exit_str = if (exit_code) |code|
            std.fmt.allocPrint(allocator, "{d}", .{code}) catch "?"
        else
            "signal";
        defer if (exit_code != null) allocator.free(exit_str);

        const entry = std.fmt.allocPrint(
            allocator,
            "type=shell_audit\nstatus={s}\nexit={s}\ncwd={s}\ncmd={s}",
            .{
                if (success) "ok" else "error",
                exit_str,
                cwd,
                cmd_display,
            },
        ) catch return;
        defer allocator.free(entry);

        mem.store(key, entry, .conversation, self.audit_session_id) catch |err| {
            log.warn("shell audit: failed to record: {}", .{err});
        };
    }
};

/// Extract a string field value from a JSON blob (minimal parser — no allocations).
/// NOTE: Prefer root.getString() with pre-parsed ObjectMap for tool implementations.
pub fn parseStringField(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key": "value"
    // Build the search pattern: "key":"  or "key" : "
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1; // skip escaped char
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

/// Extract a boolean field value from a JSON blob.
pub fn parseBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i + 4 <= after_key.len and std.mem.eql(u8, after_key[i..][0..4], "true")) return true;
    if (i + 5 <= after_key.len and std.mem.eql(u8, after_key[i..][0..5], "false")) return false;
    return null;
}

/// Extract an integer field value from a JSON blob.
pub fn parseIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    const start = i;
    if (i < after_key.len and after_key[i] == '-') i += 1;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(i64, after_key[start..i], 10) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "shell tool name" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    try std.testing.expectEqualStrings("shell", t.name());
}

test "shell tool schema has command" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "command") != null);
}

test "shell executes echo" {
    var st = ShellTool{ .workspace_dir = "." };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "shell captures failing command" {
    var st = ShellTool{ .workspace_dir = "." };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"ls /nonexistent_dir_xyz_42\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
}

test "shell missing command param" {
    var st = ShellTool{ .workspace_dir = "." };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "shell refuses in tenant runtime when workspace_only=true and sandbox off" {
    const pol = SecurityPolicy{
        .workspace_only = true,
        .block_high_risk_commands = true,
        .allowed_commands = &.{"echo"},
    };
    var st = ShellTool{
        .workspace_dir = ".",
        .policy = &pol,
        .sandbox_enabled = false,
    };
    const t = st.tool();

    // Simulate tenant runtime by setting expect_postgres_state=true.
    root.setTenantContext(.{ .expect_postgres_state = true, .user_id = "1" });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"command\":\"echo hi\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "multi-tenant") != null);
}

test "shell allows in single-user runtime when workspace_only=true and sandbox off" {
    const pol = SecurityPolicy{
        .workspace_only = true,
        .block_high_risk_commands = true,
        .allowed_commands = &.{"echo"},
    };
    var st = ShellTool{
        .workspace_dir = ".",
        .policy = &pol,
        .sandbox_enabled = false,
    };
    const t = st.tool();

    // No tenant context set — single-user/per-pod mode.
    root.clearTenantContext();
    const parsed = try root.parseTestArgs("{\"command\":\"echo single-user-ok\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "single-user-ok") != null);
}

test "shell allows in tenant runtime when autonomy.workspace_only=false" {
    const pol = SecurityPolicy{
        .workspace_only = false, // explicit acknowledgement
        .block_high_risk_commands = true,
        .allowed_commands = &.{"echo"},
    };
    var st = ShellTool{
        .workspace_dir = ".",
        .policy = &pol,
        .sandbox_enabled = false,
    };
    const t = st.tool();

    root.setTenantContext(.{ .expect_postgres_state = true, .user_id = "1" });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"command\":\"echo tenant-ok\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "tenant-ok") != null);
}

test "shell allows in tenant runtime when sandbox is enabled" {
    const pol = SecurityPolicy{
        .workspace_only = true,
        .block_high_risk_commands = true,
        .allowed_commands = &.{"echo"},
    };
    var st = ShellTool{
        .workspace_dir = ".",
        .policy = &pol,
        .sandbox_enabled = true, // sandbox provides the filesystem jail
    };
    const t = st.tool();

    root.setTenantContext(.{ .expect_postgres_state = true, .user_id = "1" });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"command\":\"echo sandbox-ok\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // With sandbox_enabled=true the shell tool will try to wrap the call —
    // that path may fail in the test env without a real sandbox backend.
    // We only care here that the workspace_only guard did NOT trigger.
    if (result.error_msg) |msg| {
        defer std.testing.allocator.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "multi-tenant") == null);
    }
    if (result.output.len > 0) std.testing.allocator.free(result.output);
}

test "parseStringField basic" {
    const json = "{\"command\": \"echo hello\", \"other\": \"val\"}";
    const val = parseStringField(json, "command");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("echo hello", val.?);
}

test "parseStringField missing" {
    const json = "{\"other\": \"val\"}";
    try std.testing.expect(parseStringField(json, "command") == null);
}

test "parseBoolField true" {
    const json = "{\"cached\": true}";
    try std.testing.expectEqual(@as(?bool, true), parseBoolField(json, "cached"));
}

test "parseBoolField false" {
    const json = "{\"cached\": false}";
    try std.testing.expectEqual(@as(?bool, false), parseBoolField(json, "cached"));
}

test "parseIntField positive" {
    const json = "{\"limit\": 42}";
    try std.testing.expectEqual(@as(?i64, 42), parseIntField(json, "limit"));
}

test "parseIntField negative" {
    const json = "{\"offset\": -5}";
    try std.testing.expectEqual(@as(?i64, -5), parseIntField(json, "offset"));
}

test "shell cwd inside workspace works without allowed_paths" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // pwd not available on Windows

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var args_buf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{tmp_path});

    var st = ShellTool{ .workspace_dir = tmp_path };
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, tmp_path) != null);
}

test "shell cwd outside workspace without allowed_paths is rejected" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // pwd not available on Windows

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("ws");
    try tmp_dir.dir.makeDir("other");
    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const ws_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "ws" });
    defer std.testing.allocator.free(ws_path);
    const other_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "other" });
    defer std.testing.allocator.free(other_path);

    var args_buf: [768]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{other_path});

    var st = ShellTool{ .workspace_dir = ws_path };
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "outside allowed areas") != null);
}

test "shell cwd relative path is rejected" {
    var st = ShellTool{ .workspace_dir = "/tmp", .allowed_paths = &.{"/tmp"} };
    const parsed = try root.parseTestArgs("{\"command\": \"pwd\", \"cwd\": \"relative\"}");
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "absolute") != null);
}

test "shell cwd with allowed_paths runs in cwd" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // pwd not available on Windows

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var args_buf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{tmp_path});

    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();

    var st = ShellTool{ .workspace_dir = ".", .allowed_paths = &.{tmp_path} };
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, tmp_path) != null);
}

test "shell cwd outside explicit tenant allowed_paths is rejected" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // pwd not available on Windows

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("users/1/workspace");
    try tmp_dir.dir.makePath("users/2/workspace");

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const tenant_one_ws = try std.fs.path.join(std.testing.allocator, &.{ root_path, "users", "1", "workspace" });
    defer std.testing.allocator.free(tenant_one_ws);
    const tenant_two_ws = try std.fs.path.join(std.testing.allocator, &.{ root_path, "users", "2", "workspace" });
    defer std.testing.allocator.free(tenant_two_ws);

    var args_buf: [1024]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{tenant_two_ws});

    var st = ShellTool{
        .workspace_dir = tenant_one_ws,
        .allowed_paths = &.{tenant_one_ws},
    };
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "outside allowed areas") != null);
}

test "shell fail closed when sandbox backend resolves to none" {
    var st = ShellTool{
        .workspace_dir = "/tmp",
        .sandbox_enabled = true,
        .sandbox_backend = .none,
    };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Sandbox unavailable") != null);
}
