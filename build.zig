const std = @import("std");
const builtin = @import("builtin");

fn addHomebrewLibpqPaths(step: anytype) void {
    const lib_candidates = [_][]const u8{
        "/opt/homebrew/opt/libpq/lib",
        "/usr/local/opt/libpq/lib",
    };
    const include_candidates = [_][]const u8{
        "/opt/homebrew/opt/libpq/include",
        "/usr/local/opt/libpq/include",
    };

    for (lib_candidates) |candidate| {
        std.fs.accessAbsolute(candidate, .{}) catch continue;
        step.addLibraryPath(.{ .cwd_relative = candidate });
        break;
    }
    for (include_candidates) |candidate| {
        std.fs.accessAbsolute(candidate, .{}) catch continue;
        step.addIncludePath(.{ .cwd_relative = candidate });
        break;
    }
}

const ChannelSelection = struct {
    enable_channel_cli: bool = false,
    enable_channel_telegram: bool = false,
    enable_channel_discord: bool = false,
    enable_channel_slack: bool = false,
    enable_channel_whatsapp: bool = false,
    enable_channel_matrix: bool = false,
    enable_channel_mattermost: bool = false,
    enable_channel_irc: bool = false,
    enable_channel_imessage: bool = false,
    enable_channel_email: bool = false,
    // enable_channel_lark: REMOVED from operator-facing build flags
    // 2026-04-30 (Nova directive — "delete Lark, we are not going to offer
    // it at all"). Field retained at default `false` for ABI compat with
    // the rest of the build_options switch in channel_catalog.zig; no
    // -Dchannels= token can flip it true. Dead-code cleanup of
    // src/channels/lark.zig + LarkConfig + 200+ call sites is scheduled
    // for V1.5 first-week per scope-before-delete discipline.
    enable_channel_lark: bool = false,
    // enable_channel_dingtalk: deleted Sprint 8 (S8.4+S8.6, 2026-04-24).
    enable_channel_line: bool = false,
    enable_channel_onebot: bool = false,
    enable_channel_qq: bool = false,
    enable_channel_maixcam: bool = false,
    enable_channel_signal: bool = false,
    enable_channel_teams: bool = false,
    enable_channel_nostr: bool = false,

    fn enableAll(self: *ChannelSelection) void {
        self.enable_channel_cli = true;
        self.enable_channel_telegram = true;
        self.enable_channel_discord = true;
        self.enable_channel_slack = true;
        self.enable_channel_whatsapp = true;
        self.enable_channel_matrix = true;
        self.enable_channel_mattermost = true;
        self.enable_channel_irc = true;
        self.enable_channel_imessage = true;
        self.enable_channel_email = true;
        // Lark intentionally NOT enabled by `-Dchannels=all` (2026-04-30).
        // Operator-facing surface removed; see field comment above.
        self.enable_channel_line = true;
        self.enable_channel_onebot = true;
        self.enable_channel_qq = true;
        self.enable_channel_maixcam = true;
        self.enable_channel_signal = true;
        self.enable_channel_teams = true;
        self.enable_channel_nostr = true;
    }
};

fn defaultChannels() ChannelSelection {
    var selection = ChannelSelection{};
    selection.enableAll();
    return selection;
}

/// V1 default channel selection: CLI (admin/ops) + Telegram (product).
/// Per the V1 convergence plan, all other channels are frozen and must be
/// explicitly re-enabled via `-Dchannels=all` or a comma-separated list.
fn v1DefaultChannels() ChannelSelection {
    var selection = ChannelSelection{};
    selection.enable_channel_cli = true;
    selection.enable_channel_telegram = true;
    return selection;
}

fn parseChannelsOption(raw: []const u8) !ChannelSelection {
    var selection = ChannelSelection{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        std.log.err("empty -Dchannels list; use e.g. -Dchannels=all or -Dchannels=telegram,slack", .{});
        return error.InvalidChannelsOption;
    }

    var saw_token = false;
    var saw_all = false;
    var saw_none = false;

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;
        saw_token = true;

        if (std.mem.eql(u8, token, "all")) {
            saw_all = true;
            selection.enableAll();
        } else if (std.mem.eql(u8, token, "none")) {
            saw_none = true;
            selection = .{};
        } else if (std.mem.eql(u8, token, "cli")) {
            selection.enable_channel_cli = true;
        } else if (std.mem.eql(u8, token, "telegram")) {
            selection.enable_channel_telegram = true;
        } else if (std.mem.eql(u8, token, "discord")) {
            selection.enable_channel_discord = true;
        } else if (std.mem.eql(u8, token, "slack")) {
            selection.enable_channel_slack = true;
        } else if (std.mem.eql(u8, token, "whatsapp")) {
            selection.enable_channel_whatsapp = true;
        } else if (std.mem.eql(u8, token, "matrix")) {
            selection.enable_channel_matrix = true;
        } else if (std.mem.eql(u8, token, "mattermost")) {
            selection.enable_channel_mattermost = true;
        } else if (std.mem.eql(u8, token, "irc")) {
            selection.enable_channel_irc = true;
        } else if (std.mem.eql(u8, token, "imessage")) {
            selection.enable_channel_imessage = true;
        } else if (std.mem.eql(u8, token, "email")) {
            selection.enable_channel_email = true;
        } else if (std.mem.eql(u8, token, "lark")) {
            // 2026-04-30 — Lark removed from operator-facing surface. The
            // build option no longer accepts it; the runtime channel is
            // unreachable. Erroring loudly so deploy scripts that still
            // request it surface immediately.
            std.log.err("-Dchannels=lark is no longer supported (channel removed 2026-04-30). Drop 'lark' from your channels list.", .{});
            return error.InvalidChannelsOption;
        } else if (std.mem.eql(u8, token, "line")) {
            selection.enable_channel_line = true;
        } else if (std.mem.eql(u8, token, "onebot")) {
            selection.enable_channel_onebot = true;
        } else if (std.mem.eql(u8, token, "qq")) {
            selection.enable_channel_qq = true;
        } else if (std.mem.eql(u8, token, "maixcam")) {
            selection.enable_channel_maixcam = true;
        } else if (std.mem.eql(u8, token, "signal")) {
            selection.enable_channel_signal = true;
        } else if (std.mem.eql(u8, token, "teams")) {
            selection.enable_channel_teams = true;
        } else if (std.mem.eql(u8, token, "nostr")) {
            selection.enable_channel_nostr = true;
        } else {
            std.log.err("unknown channel '{s}' in -Dchannels list", .{token});
            return error.InvalidChannelsOption;
        }
    }

    if (!saw_token) {
        std.log.err("empty -Dchannels list; use e.g. -Dchannels=all or -Dchannels=telegram,slack", .{});
        return error.InvalidChannelsOption;
    }
    if (saw_all and saw_none) {
        std.log.err("ambiguous -Dchannels list: cannot combine 'all' with 'none'", .{});
        return error.InvalidChannelsOption;
    }

    return selection;
}

const EngineSelection = struct {
    // Base backends
    enable_memory_none: bool = false,
    enable_memory_markdown: bool = false,
    enable_memory_memory: bool = false,
    enable_memory_api: bool = false,

    // Optional backends
    enable_sqlite: bool = false,
    enable_memory_sqlite: bool = false,
    enable_memory_lucid: bool = false,
    enable_memory_redis: bool = false,
    enable_memory_lancedb: bool = false,
    enable_postgres: bool = false,

    fn enableBase(self: *EngineSelection) void {
        self.enable_memory_none = true;
        self.enable_memory_markdown = true;
        self.enable_memory_memory = true;
        self.enable_memory_api = true;
    }

    fn enableAllOptional(self: *EngineSelection) void {
        self.enable_memory_sqlite = true;
        self.enable_memory_lucid = true;
        self.enable_memory_redis = true;
        self.enable_memory_lancedb = true;
        self.enable_postgres = true;
    }

    fn finalize(self: *EngineSelection) void {
        // SQLite runtime is needed by sqlite/lucid/lancedb memory backends.
        self.enable_sqlite = self.enable_memory_sqlite or self.enable_memory_lucid or self.enable_memory_lancedb;
    }

    fn hasAnyBackend(self: EngineSelection) bool {
        return self.enable_memory_none or
            self.enable_memory_markdown or
            self.enable_memory_memory or
            self.enable_memory_api or
            self.enable_memory_sqlite or
            self.enable_memory_lucid or
            self.enable_memory_redis or
            self.enable_memory_lancedb or
            self.enable_postgres;
    }
};

fn defaultEngines() EngineSelection {
    var selection = EngineSelection{};
    // Default binary: practical local setup with file/memory/api plus sqlite.
    selection.enableBase();
    selection.enable_memory_sqlite = true;
    selection.finalize();
    return selection;
}

fn parseEnginesOption(raw: []const u8) !EngineSelection {
    var selection = EngineSelection{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        std.log.err("empty -Dengines list; use e.g. -Dengines=base or -Dengines=base,sqlite", .{});
        return error.InvalidEnginesOption;
    }

    var saw_token = false;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;
        saw_token = true;

        if (std.mem.eql(u8, token, "base") or std.mem.eql(u8, token, "minimal")) {
            selection.enableBase();
        } else if (std.mem.eql(u8, token, "all")) {
            selection.enableBase();
            selection.enableAllOptional();
        } else if (std.mem.eql(u8, token, "none")) {
            selection.enable_memory_none = true;
        } else if (std.mem.eql(u8, token, "markdown")) {
            selection.enable_memory_markdown = true;
        } else if (std.mem.eql(u8, token, "memory")) {
            selection.enable_memory_memory = true;
        } else if (std.mem.eql(u8, token, "api")) {
            selection.enable_memory_api = true;
        } else if (std.mem.eql(u8, token, "sqlite")) {
            selection.enable_memory_sqlite = true;
        } else if (std.mem.eql(u8, token, "lucid")) {
            selection.enable_memory_lucid = true;
        } else if (std.mem.eql(u8, token, "redis")) {
            selection.enable_memory_redis = true;
        } else if (std.mem.eql(u8, token, "lancedb")) {
            selection.enable_memory_lancedb = true;
        } else if (std.mem.eql(u8, token, "postgres")) {
            selection.enable_postgres = true;
        } else {
            std.log.err("unknown engine '{s}' in -Dengines list", .{token});
            return error.InvalidEnginesOption;
        }
    }

    if (!saw_token) {
        std.log.err("empty -Dengines list; use e.g. -Dengines=base or -Dengines=base,sqlite", .{});
        return error.InvalidEnginesOption;
    }

    selection.finalize();
    if (!selection.hasAnyBackend()) {
        std.log.err("no memory backends selected; choose at least one engine (e.g. base or none)", .{});
        return error.InvalidEnginesOption;
    }

    return selection;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = b.option([]const u8, "version", "Version string embedded in the binary") orelse "2026.2.25";
    // V1 convergence flag. When true (default), the build narrows defaults to
    // V1-safe choices: channel default becomes `cli,telegram` only. Pass
    // `-Dv1=false` to restore pre-V1 defaults (all channels enabled) as an
    // escape hatch for one release cycle. Explicit `-Dchannels=...` always
    // wins over the v1 default.
    const v1 = b.option(bool, "v1", "V1 convergence mode: narrow defaults to V1-safe subsystems (default: true)") orelse true;
    const channels_raw = b.option(
        []const u8,
        "channels",
        "Channels list. Tokens: all|none|cli|telegram|discord|slack|whatsapp|matrix|mattermost|irc|imessage|email|lark|line|onebot|qq|maixcam|signal (default: cli,telegram under -Dv1=true; all under -Dv1=false)",
    );
    const channels = if (channels_raw) |raw| blk: {
        const parsed = parseChannelsOption(raw) catch {
            std.process.exit(1);
        };
        break :blk parsed;
    } else if (v1) v1DefaultChannels() else defaultChannels();

    const engines_raw = b.option(
        []const u8,
        "engines",
        "Memory engines list. Tokens: base|minimal|all|none|markdown|memory|api|sqlite|lucid|redis|lancedb|postgres (default: base,sqlite)",
    );
    const engines = if (engines_raw) |raw| blk: {
        const parsed = parseEnginesOption(raw) catch {
            std.process.exit(1);
        };
        break :blk parsed;
    } else defaultEngines();

    const enable_memory_none = engines.enable_memory_none;
    const enable_memory_markdown = engines.enable_memory_markdown;
    const enable_memory_memory = engines.enable_memory_memory;
    const enable_memory_api = engines.enable_memory_api;
    const enable_sqlite = engines.enable_sqlite;
    const enable_memory_sqlite = engines.enable_memory_sqlite;
    const enable_memory_lucid = engines.enable_memory_lucid;
    const enable_memory_redis = engines.enable_memory_redis;
    const enable_memory_lancedb = engines.enable_memory_lancedb;
    const enable_postgres = engines.enable_postgres;
    const enable_channel_cli = channels.enable_channel_cli;
    const enable_channel_telegram = channels.enable_channel_telegram;
    const enable_channel_discord = channels.enable_channel_discord;
    const enable_channel_slack = channels.enable_channel_slack;
    const enable_channel_whatsapp = channels.enable_channel_whatsapp;
    const enable_channel_matrix = channels.enable_channel_matrix;
    const enable_channel_mattermost = channels.enable_channel_mattermost;
    const enable_channel_irc = channels.enable_channel_irc;
    const enable_channel_imessage = channels.enable_channel_imessage;
    const enable_channel_email = channels.enable_channel_email;
    const enable_channel_lark = channels.enable_channel_lark;
    const enable_channel_line = channels.enable_channel_line;
    const enable_channel_onebot = channels.enable_channel_onebot;
    const enable_channel_qq = channels.enable_channel_qq;
    const enable_channel_maixcam = channels.enable_channel_maixcam;
    const enable_channel_signal = channels.enable_channel_signal;
    const enable_channel_teams = channels.enable_channel_teams;
    const enable_channel_nostr = channels.enable_channel_nostr;

    const effective_enable_memory_sqlite = enable_sqlite and enable_memory_sqlite;
    const effective_enable_memory_lucid = enable_sqlite and enable_memory_lucid;
    const effective_enable_memory_lancedb = enable_sqlite and enable_memory_lancedb;

    const sqlite3 = if (enable_sqlite) blk: {
        const sqlite3_dep = b.dependency("sqlite3", .{
            .target = target,
            .optimize = optimize,
        });
        const sqlite3_artifact = sqlite3_dep.artifact("sqlite3");
        sqlite3_artifact.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");
        break :blk sqlite3_artifact;
    } else null;

    const sentry_dep = b.dependency("sentry_zig", .{
        .target = target,
        .optimize = optimize,
    });

    var build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption(bool, "v1", v1);
    build_options.addOption(bool, "enable_memory_none", enable_memory_none);
    build_options.addOption(bool, "enable_memory_markdown", enable_memory_markdown);
    build_options.addOption(bool, "enable_memory_memory", enable_memory_memory);
    build_options.addOption(bool, "enable_memory_api", enable_memory_api);
    build_options.addOption(bool, "enable_sqlite", enable_sqlite);
    build_options.addOption(bool, "enable_postgres", enable_postgres);
    build_options.addOption(bool, "enable_memory_sqlite", effective_enable_memory_sqlite);
    build_options.addOption(bool, "enable_memory_lucid", effective_enable_memory_lucid);
    build_options.addOption(bool, "enable_memory_redis", enable_memory_redis);
    build_options.addOption(bool, "enable_memory_lancedb", effective_enable_memory_lancedb);
    build_options.addOption(bool, "enable_channel_cli", enable_channel_cli);
    build_options.addOption(bool, "enable_channel_telegram", enable_channel_telegram);
    build_options.addOption(bool, "enable_channel_discord", enable_channel_discord);
    build_options.addOption(bool, "enable_channel_slack", enable_channel_slack);
    build_options.addOption(bool, "enable_channel_whatsapp", enable_channel_whatsapp);
    build_options.addOption(bool, "enable_channel_matrix", enable_channel_matrix);
    build_options.addOption(bool, "enable_channel_mattermost", enable_channel_mattermost);
    build_options.addOption(bool, "enable_channel_irc", enable_channel_irc);
    build_options.addOption(bool, "enable_channel_imessage", enable_channel_imessage);
    build_options.addOption(bool, "enable_channel_email", enable_channel_email);
    build_options.addOption(bool, "enable_channel_lark", enable_channel_lark);
    build_options.addOption(bool, "enable_channel_line", enable_channel_line);
    build_options.addOption(bool, "enable_channel_onebot", enable_channel_onebot);
    build_options.addOption(bool, "enable_channel_qq", enable_channel_qq);
    build_options.addOption(bool, "enable_channel_maixcam", enable_channel_maixcam);
    build_options.addOption(bool, "enable_channel_signal", enable_channel_signal);
    build_options.addOption(bool, "enable_channel_teams", enable_channel_teams);
    build_options.addOption(bool, "enable_channel_nostr", enable_channel_nostr);
    const build_options_module = build_options.createModule();

    // ---------- library module (importable by consumers) ----------
    const lib_mod = b.addModule("nullalis", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("build_options", build_options_module);
    lib_mod.addImport("sentry-zig", sentry_dep.module("sentry-zig"));
    if (sqlite3) |lib| {
        lib_mod.linkLibrary(lib);
    }
    if (enable_postgres) {
        lib_mod.linkSystemLibrary("pq", .{});
    }

    // ---------- executable ----------
    const exe = b.addExecutable(.{
        .name = "nullalis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nullalis", .module = lib_mod },
            },
        }),
    });
    exe.root_module.addImport("build_options", build_options_module);
    exe.root_module.addImport("sentry-zig", sentry_dep.module("sentry-zig"));

    // Link SQLite on the compile step (not the module)
    if (sqlite3) |lib| {
        exe.linkLibrary(lib);
    }
    if (enable_postgres) {
        addHomebrewLibpqPaths(exe);
        addHomebrewLibpqPaths(exe.root_module);
        exe.root_module.linkSystemLibrary("pq", .{});
    }
    exe.dead_strip_dylibs = true;

    if (optimize != .Debug) {
        exe.root_module.strip = true;
        exe.root_module.unwind_tables = .none;
        exe.root_module.omit_frame_pointer = true;
    }

    b.installArtifact(exe);

    // macOS host+target only: strip local symbols post-install.
    // Host `strip` cannot process ELF/PE during cross-builds.
    if (optimize != .Debug and builtin.os.tag == .macos and target.result.os.tag == .macos) {
        const strip_cmd = b.addSystemCommand(&.{"strip"});
        strip_cmd.addArgs(&.{"-x"});
        strip_cmd.addFileArg(exe.getEmittedBin());
        strip_cmd.step.dependOn(b.getInstallStep());
        b.default_step = &strip_cmd.step;
    }

    // ---------- run step ----------
    const run_step = b.step("run", "Run nullalis");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ---------- tests ----------
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    if (sqlite3) |lib| {
        lib_tests.linkLibrary(lib);
    }
    if (enable_postgres) {
        addHomebrewLibpqPaths(lib_tests);
        addHomebrewLibpqPaths(lib_tests.root_module);
        lib_tests.root_module.linkSystemLibrary("pq", .{});
    }

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    // V8 (v1.14.13 Step 0): security tests live outside src/ because
    // they pin cross-module boundaries (sandbox bypass gate). Wire each
    // such test as its own addTest step with `nullalis` as an import.
    const security_sandbox_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/security/sandbox_fail_closed_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nullalis", .module = lib_mod },
            },
        }),
    });
    if (sqlite3) |lib| {
        security_sandbox_tests.linkLibrary(lib);
    }
    if (enable_postgres) {
        addHomebrewLibpqPaths(security_sandbox_tests);
        addHomebrewLibpqPaths(security_sandbox_tests.root_module);
        security_sandbox_tests.root_module.linkSystemLibrary("pq", .{});
    }

    // v1.14.18-B Fix C — promotion + reflection-store postgres integration
    // test. Lives outside src/ (like the security tests above) because it
    // pins a cross-module session-end flow (working_memory → promotion →
    // durable_fact, reflection → procedural_memory → skill_executions).
    // Postgres-gated at runtime, so it compiles — and cleanly skips — under
    // every engine profile.
    const agent_pg_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/agent/promotion_reflection_pg_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nullalis", .module = lib_mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    if (sqlite3) |lib| {
        agent_pg_tests.linkLibrary(lib);
    }
    if (enable_postgres) {
        addHomebrewLibpqPaths(agent_pg_tests);
        addHomebrewLibpqPaths(agent_pg_tests.root_module);
        agent_pg_tests.root_module.linkSystemLibrary("pq", .{});
    }

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(security_sandbox_tests).step);
    test_step.dependOn(&b.addRunArtifact(agent_pg_tests).step);

    // Focused step: run only the v1.14.18-B Fix C integration test —
    // exercises the postgres round-trip without rebuilding/running the
    // full suite. Set NULLALIS_POSTGRES_TEST_URL to run it for real; it
    // skips cleanly otherwise.
    const agent_pg_step = b.step("test-agent-pg", "Run only the promotion + reflection-store postgres integration test");
    agent_pg_step.dependOn(&b.addRunArtifact(agent_pg_tests).step);
}
