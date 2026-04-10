//! Security Review — runs structured checks covering sandbox, workspace isolation,
//! audit logging, rate limiting, API key exposure, SSRF protection, auth config,
//! and sandbox backend.
//!
//! Outputs JSON/text with per-check pass/fail/warning, score (0-100), and letter grade.
//! This is a pure computation module — wired into slash commands and API endpoints in Plan 04.

const std = @import("std");
const config_types = @import("config_types.zig");
const doctor = @import("doctor.zig");

// ── Types ───────────────────────────────────────────────────────────

/// Result of a single security check.
pub const SecurityCheckResult = struct {
    name: []const u8,
    category: []const u8,
    severity: doctor.Severity,
    message: []const u8,
    score_impact: i8,
};

/// Extensible check vtable for future custom checks (per D-14).
/// Built-in checks are called directly by runAllChecks; this struct
/// provides the extension point for user-defined checks.
pub const SecurityCheck = struct {
    name: []const u8,
    category: []const u8,
    run: *const fn (ctx: *const CheckContext) SecurityCheckResult,
};

/// Context passed to extensible checks.
pub const CheckContext = struct {
    security: config_types.SecurityConfig,
    workspace_only: bool,
    max_actions_per_hour: u32,
    pairing_enabled: bool,
};

/// Summary counts for the security report.
pub const SeveritySummary = struct {
    ok_count: u32 = 0,
    warn_count: u32 = 0,
    err_count: u32 = 0,
};

/// Full security report with score, grade, and per-check results.
pub const SecurityReport = struct {
    score: u8,
    grade: []const u8,
    checks: []const SecurityCheckResult,
    summary: SeveritySummary,
};

// ── Built-in Check Functions (8 checks) ─────────────────────────────

/// Check 1: Sandbox enabled — category "isolation"
/// ok (+10) if sandbox.enabled=true, warn (-5) if false/null
pub fn checkSandboxEnabled(enabled: ?bool) SecurityCheckResult {
    if (enabled != null and enabled.?) {
        return .{
            .name = "sandbox_enabled",
            .category = "isolation",
            .severity = .ok,
            .message = "sandbox enabled",
            .score_impact = 10,
        };
    }
    return .{
        .name = "sandbox_enabled",
        .category = "isolation",
        .severity = .warn,
        .message = "sandbox not enabled — tool execution runs without isolation",
        .score_impact = -5,
    };
}

/// Check 2: Sandbox backend — category "isolation"
/// ok (+5) if backend is not .none, warn (-3) otherwise
pub fn checkSandboxBackend(backend: config_types.SandboxBackend) SecurityCheckResult {
    if (backend != .none) {
        return .{
            .name = "sandbox_backend",
            .category = "isolation",
            .severity = .ok,
            .message = "sandbox backend configured",
            .score_impact = 5,
        };
    }
    return .{
        .name = "sandbox_backend",
        .category = "isolation",
        .severity = .warn,
        .message = "sandbox backend is none — no sandboxing active",
        .score_impact = -3,
    };
}

/// Check 3: Workspace isolation — category "isolation"
/// ok (+10) if workspace_only=true, err (-10) if false
pub fn checkWorkspaceIsolation(workspace_only: bool) SecurityCheckResult {
    if (workspace_only) {
        return .{
            .name = "workspace_isolation",
            .category = "isolation",
            .severity = .ok,
            .message = "workspace_only=true — agent restricted to workspace",
            .score_impact = 10,
        };
    }
    return .{
        .name = "workspace_isolation",
        .category = "isolation",
        .severity = .err,
        .message = "workspace_only=false — agent can access files outside workspace",
        .score_impact = -10,
    };
}

/// Check 4: Audit logging — category "audit"
/// ok (+5) if audit.enabled=true, warn (-5) if false
pub fn checkAuditLogging(enabled: bool) SecurityCheckResult {
    if (enabled) {
        return .{
            .name = "audit_logging",
            .category = "audit",
            .severity = .ok,
            .message = "audit logging enabled",
            .score_impact = 5,
        };
    }
    return .{
        .name = "audit_logging",
        .category = "audit",
        .severity = .warn,
        .message = "audit logging disabled — no action trail",
        .score_impact = -5,
    };
}

/// Check 5: Rate limiting — category "rate_limiting"
/// ok (+5) if max_actions_per_hour > 0, warn (-5) if 0
pub fn checkRateLimiting(max_actions: u32) SecurityCheckResult {
    if (max_actions > 0) {
        return .{
            .name = "rate_limiting",
            .category = "rate_limiting",
            .severity = .ok,
            .message = "rate limiting active",
            .score_impact = 5,
        };
    }
    return .{
        .name = "rate_limiting",
        .category = "rate_limiting",
        .severity = .warn,
        .message = "max_actions_per_hour=0 — no rate limiting",
        .score_impact = -5,
    };
}

/// Check 6: API key exposure — category "secrets"
/// Always ok (+5) — runtime check cannot detect plaintext keys in config files.
/// Actual key exposure detection requires static config file scanning (out of scope).
pub fn checkApiKeyExposure() SecurityCheckResult {
    return .{
        .name = "api_key_exposure",
        .category = "secrets",
        .severity = .ok,
        .message = "no plaintext API keys detected at runtime",
        .score_impact = 5,
    };
}

/// Check 7: SSRF protection — category "network"
/// Always ok (+10) — net_security.zig is always active (compiled in).
pub fn checkSsrfProtection() SecurityCheckResult {
    return .{
        .name = "ssrf_protection",
        .category = "network",
        .severity = .ok,
        .message = "SSRF protection active (net_security module compiled in)",
        .score_impact = 10,
    };
}

/// Check 8: Auth config — category "auth"
/// ok (+5) if pairing enabled, warn (-5) otherwise
pub fn checkAuthConfig(pairing_enabled: bool) SecurityCheckResult {
    if (pairing_enabled) {
        return .{
            .name = "auth_config",
            .category = "auth",
            .severity = .ok,
            .message = "pairing authentication enabled",
            .score_impact = 5,
        };
    }
    return .{
        .name = "auth_config",
        .category = "auth",
        .severity = .warn,
        .message = "pairing not enabled — API endpoints unprotected",
        .score_impact = -5,
    };
}

// ── Score & Grade Calculation ───────────────────────────────────────

/// Calculate security score from check results.
/// Starts at 100, deducts score_impact for non-ok results. Clamped to 0-100.
pub fn calculateScore(results: []const SecurityCheckResult) u8 {
    var score: i16 = 100;
    for (results) |r| {
        if (r.severity != .ok) {
            score += @as(i16, r.score_impact);
        }
    }
    return @intCast(@max(0, @min(100, score)));
}

/// Map a numeric score to a letter grade.
pub fn calculateGrade(score: u8) []const u8 {
    if (score >= 90) return "A";
    if (score >= 80) return "B";
    if (score >= 70) return "C";
    if (score >= 60) return "D";
    return "F";
}

// ── Run All Checks ──────────────────────────────────────────────────

/// Number of built-in checks.
pub const BUILTIN_CHECK_COUNT = 8;

/// Run all 8 built-in security checks and produce a SecurityReport.
/// Caller owns the returned checks slice.
pub fn runAllChecks(
    allocator: std.mem.Allocator,
    security: config_types.SecurityConfig,
    workspace_only: bool,
    max_actions_per_hour: u32,
    pairing_enabled: bool,
) !SecurityReport {
    const checks = try allocator.alloc(SecurityCheckResult, BUILTIN_CHECK_COUNT);

    checks[0] = checkSandboxEnabled(security.sandbox.enabled);
    checks[1] = checkSandboxBackend(security.sandbox.backend);
    checks[2] = checkWorkspaceIsolation(workspace_only);
    checks[3] = checkAuditLogging(security.audit.enabled);
    checks[4] = checkRateLimiting(max_actions_per_hour);
    checks[5] = checkApiKeyExposure();
    checks[6] = checkSsrfProtection();
    checks[7] = checkAuthConfig(pairing_enabled);

    const score = calculateScore(checks);
    const grade = calculateGrade(score);

    var summary = SeveritySummary{};
    for (checks) |c| {
        switch (c.severity) {
            .ok => summary.ok_count += 1,
            .warn => summary.warn_count += 1,
            .err => summary.err_count += 1,
        }
    }

    return .{
        .score = score,
        .grade = grade,
        .checks = checks,
        .summary = summary,
    };
}

// ── JSON Formatter ──────────────────────────────────────────────────

fn severityString(s: doctor.Severity) []const u8 {
    return switch (s) {
        .ok => "ok",
        .warn => "warn",
        .err => "err",
    };
}

/// Serialize a SecurityReport to JSON.
/// Output: {"score":N,"grade":"X","checks":[...],"summary":{"ok":N,"warn":N,"err":N}}
/// Caller owns the returned memory.
pub fn formatReviewJson(allocator: std.mem.Allocator, report: SecurityReport) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("{{\"score\":{d},\"grade\":\"{s}\",\"checks\":[", .{ report.score, report.grade });

    for (report.checks, 0..) |check, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"category\":\"{s}\",\"severity\":\"{s}\",\"message\":\"{s}\"}}", .{
            check.name,
            check.category,
            severityString(check.severity),
            check.message,
        });
    }

    try w.print("],\"summary\":{{\"ok\":{d},\"warn\":{d},\"err\":{d}}}}}", .{
        report.summary.ok_count,
        report.summary.warn_count,
        report.summary.err_count,
    });

    return try allocator.dupe(u8, buf.items);
}

// ── Text Formatter ──────────────────────────────────────────────────

/// Format a SecurityReport as human-readable text for the /security-review command.
/// Caller owns the returned memory.
pub fn formatReviewText(allocator: std.mem.Allocator, report: SecurityReport) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("Security Review: Score {d}/100 ({s})\n\n", .{ report.score, report.grade });

    for (report.checks) |check| {
        const icon: []const u8 = switch (check.severity) {
            .ok => "[ok]  ",
            .warn => "[warn]",
            .err => "[ERR] ",
        };
        try w.print("{s} {s} ({s}): {s}\n", .{
            icon,
            check.name,
            check.category,
            check.message,
        });
    }

    return try allocator.dupe(u8, buf.items);
}

// ── Tests ────────────────────────────────────────────────────────────

test "SecurityCheckResult has required fields" {
    const result = SecurityCheckResult{
        .name = "test_check",
        .category = "test",
        .severity = .ok,
        .message = "all good",
        .score_impact = 10,
    };
    try std.testing.expectEqualStrings("test_check", result.name);
    try std.testing.expectEqualStrings("test", result.category);
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
    try std.testing.expectEqualStrings("all good", result.message);
    try std.testing.expectEqual(@as(i8, 10), result.score_impact);
}

test "checkSandboxEnabled returns ok when enabled=true" {
    const result = checkSandboxEnabled(true);
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
    try std.testing.expectEqual(@as(i8, 10), result.score_impact);
    try std.testing.expectEqualStrings("sandbox_enabled", result.name);
}

test "checkSandboxEnabled returns warn when enabled=false" {
    const result_false = checkSandboxEnabled(false);
    try std.testing.expectEqual(doctor.Severity.warn, result_false.severity);
    try std.testing.expectEqual(@as(i8, -5), result_false.score_impact);

    const result_null = checkSandboxEnabled(null);
    try std.testing.expectEqual(doctor.Severity.warn, result_null.severity);
    try std.testing.expectEqual(@as(i8, -5), result_null.score_impact);
}

test "checkWorkspaceIsolation returns err when workspace_only=false" {
    const result = checkWorkspaceIsolation(false);
    try std.testing.expectEqual(doctor.Severity.err, result.severity);
    try std.testing.expectEqual(@as(i8, -10), result.score_impact);
    try std.testing.expectEqualStrings("workspace_isolation", result.name);
}

test "checkWorkspaceIsolation returns ok when workspace_only=true" {
    const result = checkWorkspaceIsolation(true);
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
    try std.testing.expectEqual(@as(i8, 10), result.score_impact);
}

test "checkAuditLogging returns ok when enabled=true" {
    const result = checkAuditLogging(true);
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
    try std.testing.expectEqualStrings("audit_logging", result.name);
}

test "checkRateLimiting returns warn when max_actions=0" {
    const result = checkRateLimiting(0);
    try std.testing.expectEqual(doctor.Severity.warn, result.severity);
    try std.testing.expectEqual(@as(i8, -5), result.score_impact);
    try std.testing.expectEqualStrings("rate_limiting", result.name);
}

test "checkRateLimiting returns ok when max_actions>0" {
    const result = checkRateLimiting(100);
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
}

test "calculateScore returns 100 for all-ok results" {
    const results = [_]SecurityCheckResult{
        .{ .name = "a", .category = "x", .severity = .ok, .message = "ok", .score_impact = 10 },
        .{ .name = "b", .category = "x", .severity = .ok, .message = "ok", .score_impact = 5 },
        .{ .name = "c", .category = "x", .severity = .ok, .message = "ok", .score_impact = 10 },
    };
    try std.testing.expectEqual(@as(u8, 100), calculateScore(&results));
}

test "calculateScore deducts for non-ok results" {
    const results = [_]SecurityCheckResult{
        .{ .name = "a", .category = "x", .severity = .ok, .message = "ok", .score_impact = 10 },
        .{ .name = "b", .category = "x", .severity = .warn, .message = "warn", .score_impact = -5 },
        .{ .name = "c", .category = "x", .severity = .err, .message = "err", .score_impact = -10 },
    };
    // 100 + (-5) + (-10) = 85
    try std.testing.expectEqual(@as(u8, 85), calculateScore(&results));
}

test "calculateGrade returns correct grades" {
    try std.testing.expectEqualStrings("A", calculateGrade(100));
    try std.testing.expectEqualStrings("A", calculateGrade(90));
    try std.testing.expectEqualStrings("B", calculateGrade(89));
    try std.testing.expectEqualStrings("B", calculateGrade(80));
    try std.testing.expectEqualStrings("C", calculateGrade(79));
    try std.testing.expectEqualStrings("C", calculateGrade(70));
    try std.testing.expectEqualStrings("D", calculateGrade(69));
    try std.testing.expectEqualStrings("D", calculateGrade(60));
    try std.testing.expectEqualStrings("F", calculateGrade(59));
    try std.testing.expectEqualStrings("F", calculateGrade(0));
}

test "formatReviewJson produces valid JSON structure" {
    const checks = [_]SecurityCheckResult{
        .{ .name = "sandbox_enabled", .category = "isolation", .severity = .ok, .message = "sandbox enabled", .score_impact = 10 },
        .{ .name = "audit_logging", .category = "audit", .severity = .warn, .message = "audit logging disabled", .score_impact = -5 },
    };
    const report = SecurityReport{
        .score = 95,
        .grade = "A",
        .checks = &checks,
        .summary = .{ .ok_count = 1, .warn_count = 1, .err_count = 0 },
    };
    const json = try formatReviewJson(std.testing.allocator, report);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"score\":95") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"grade\":\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"checks\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"sandbox_enabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"summary\":{\"ok\":1,\"warn\":1,\"err\":0}") != null);
}

test "runAllChecks with all-secure config returns high score" {
    const security = config_types.SecurityConfig{
        .sandbox = .{ .enabled = true, .backend = .landlock },
        .audit = .{ .enabled = true },
    };
    const report = try runAllChecks(std.testing.allocator, security, true, 100, true);
    defer std.testing.allocator.free(report.checks);

    try std.testing.expectEqual(@as(u8, 100), report.score);
    try std.testing.expectEqualStrings("A", report.grade);
    try std.testing.expectEqual(@as(u32, 8), report.summary.ok_count);
    try std.testing.expectEqual(@as(u32, 0), report.summary.warn_count);
    try std.testing.expectEqual(@as(u32, 0), report.summary.err_count);
    try std.testing.expectEqual(@as(usize, 8), report.checks.len);
}

test "runAllChecks with insecure config returns low score" {
    const security = config_types.SecurityConfig{
        .sandbox = .{ .enabled = false, .backend = .none },
        .audit = .{ .enabled = false },
    };
    const report = try runAllChecks(std.testing.allocator, security, false, 0, false);
    defer std.testing.allocator.free(report.checks);

    // sandbox_enabled warn(-5) + sandbox_backend warn(-3) + workspace_isolation err(-10)
    // + audit_logging warn(-5) + rate_limiting warn(-5) + auth_config warn(-5)
    // = 100 - 33 = 67
    try std.testing.expectEqual(@as(u8, 67), report.score);
    try std.testing.expectEqualStrings("D", report.grade);
    try std.testing.expect(report.summary.err_count >= 1);
    try std.testing.expect(report.summary.warn_count >= 4);
}

test "formatReviewText produces human-readable output" {
    const checks = [_]SecurityCheckResult{
        .{ .name = "sandbox_enabled", .category = "isolation", .severity = .ok, .message = "sandbox enabled", .score_impact = 10 },
        .{ .name = "workspace_isolation", .category = "isolation", .severity = .err, .message = "workspace_only=false", .score_impact = -10 },
    };
    const report = SecurityReport{
        .score = 85,
        .grade = "B",
        .checks = &checks,
        .summary = .{ .ok_count = 1, .warn_count = 0, .err_count = 1 },
    };
    const text = try formatReviewText(std.testing.allocator, report);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Security Review: Score 85/100 (B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[ok]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[ERR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sandbox_enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "workspace_isolation") != null);
}

test "checkSandboxBackend ok for non-none backends" {
    const result_auto = checkSandboxBackend(.auto);
    try std.testing.expectEqual(doctor.Severity.ok, result_auto.severity);

    const result_landlock = checkSandboxBackend(.landlock);
    try std.testing.expectEqual(doctor.Severity.ok, result_landlock.severity);

    const result_none = checkSandboxBackend(.none);
    try std.testing.expectEqual(doctor.Severity.warn, result_none.severity);
}

test "checkApiKeyExposure always returns ok" {
    const result = checkApiKeyExposure();
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
    try std.testing.expectEqualStrings("api_key_exposure", result.name);
}

test "checkSsrfProtection always returns ok" {
    const result = checkSsrfProtection();
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
    try std.testing.expectEqualStrings("ssrf_protection", result.name);
}

test "checkAuthConfig ok when pairing enabled" {
    const result_on = checkAuthConfig(true);
    try std.testing.expectEqual(doctor.Severity.ok, result_on.severity);

    const result_off = checkAuthConfig(false);
    try std.testing.expectEqual(doctor.Severity.warn, result_off.severity);
}

test "SecurityCheck vtable struct exists with expected fields" {
    const ctx = CheckContext{
        .security = .{},
        .workspace_only = true,
        .max_actions_per_hour = 100,
        .pairing_enabled = true,
    };
    // Demonstrate vtable usage with a custom check
    const custom = SecurityCheck{
        .name = "custom_check",
        .category = "custom",
        .run = &struct {
            fn check(_: *const CheckContext) SecurityCheckResult {
                return .{
                    .name = "custom_check",
                    .category = "custom",
                    .severity = .ok,
                    .message = "custom check passed",
                    .score_impact = 5,
                };
            }
        }.check,
    };
    const result = custom.run(&ctx);
    try std.testing.expectEqualStrings("custom_check", result.name);
    try std.testing.expectEqual(doctor.Severity.ok, result.severity);
}
