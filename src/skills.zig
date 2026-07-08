const std = @import("std");
const platform = @import("platform.zig");
const http_util = @import("http_util.zig");

// Skills — user-defined capabilities loaded from disk.
//
// Each skill lives in ~/.nullalis/workspace/skills/<name>/ with:
//   - skill.json  — manifest (name, version, description, author)
//   - SKILL.md    — optional instruction text
//
// The skillforge module handles discovery and evaluation;
// this module handles definition, loading, installation, and removal.

// ── Types ───────────────────────────────────────────────────────

pub const Skill = struct {
    name: []const u8,
    version: []const u8 = "0.0.1",
    description: []const u8 = "",
    author: []const u8 = "",
    instructions: []const u8 = "",
    enabled: bool = true,
    /// If true, full instructions are always included in the system prompt.
    /// If false, only an XML summary is included and the agent must use read_file to load instructions.
    always: bool = false,
    /// List of CLI binaries required by this skill (e.g. "docker", "git").
    requires_bins: []const []const u8 = &.{},
    /// List of environment variables required by this skill (e.g. "OPENAI_API_KEY").
    requires_env: []const []const u8 = &.{},
    /// Whether all requirements are satisfied. Set by checkRequirements().
    available: bool = true,
    /// Human-readable description of missing dependencies. Set by checkRequirements().
    missing_deps: []const u8 = "",
    /// Path to the skill directory on disk (for read_file references).
    path: []const u8 = "",
};

pub const SkillManifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    always: bool = false,
    requires_bins: []const []const u8 = &.{},
    requires_env: []const []const u8 = &.{},
};

pub const DECISION_HUB_DEFAULT_API_URL = "https://hub.decision.ai";
pub const DECISION_HUB_ENV_API_URL = "NULLALIS_DECISION_HUB_API_URL";
pub const DECISION_HUB_ENV_TOKEN = "NULLALIS_DECISION_HUB_TOKEN";
pub const DHUB_ENV_API_URL = "DHUB_API_URL";
pub const DHUB_ENV_TOKEN = "DHUB_TOKEN";

pub const DecisionHubSkillRef = struct {
    org_slug: []const u8,
    skill_name: []const u8,
};

pub const DecisionHubSearchResult = struct {
    org_slug: []const u8,
    skill_name: []const u8,
    description: []const u8,
    safety_rating: []const u8,
    latest_version: []const u8,
};

pub const DecisionHubInstallOptions = struct {
    spec: []const u8 = "latest",
    allow_risky: bool = false,
};

pub const DecisionHubInstallResult = struct {
    org_slug: []const u8,
    skill_name: []const u8,
    installed_name: []const u8,
    resolved_version: []const u8,
};

fn decisionHubTransportConfig() http_util.TransportConfig {
    // Keep Decision Hub network path on curl transport.
    // Native TLS can trap under real-world cert verification on macOS/Zig 0.15.
    return .{ .mode = .curl_only };
}

const RequestHeaders = struct {
    headers: []const []const u8,
    owned_auth: ?[]u8,
};

// ── JSON Parsing (manual, no allocations) ───────────────────────

/// Extract a string field value from a JSON blob (minimal parser — no allocations).
/// Same pattern as tools/shell.zig parseStringField.
fn parseStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}

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

/// Extract a boolean field value from a JSON blob (true/false literal).
fn parseBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}

    if (i + 4 <= after_key.len and std.mem.eql(u8, after_key[i..][0..4], "true")) return true;
    if (i + 5 <= after_key.len and std.mem.eql(u8, after_key[i..][0..5], "false")) return false;
    return null;
}

/// Parse a JSON string array field, returning allocated slices.
/// E.g. for `"requires_bins": ["docker", "git"]` returns &["docker", "git"].
/// Caller owns the returned outer slice and each inner slice.
fn parseStringArray(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]const []const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return &.{};
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return &.{};
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon to find '['
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}
    if (i >= after_key.len or after_key[i] != '[') return &.{};
    i += 1; // skip '['

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    while (i < after_key.len) {
        // Skip whitespace and commas
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ',' or
            after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
        {}
        if (i >= after_key.len or after_key[i] == ']') break;
        if (after_key[i] != '"') break; // unexpected token
        i += 1; // skip opening quote

        const start = i;
        while (i < after_key.len) : (i += 1) {
            if (after_key[i] == '\\' and i + 1 < after_key.len) {
                i += 1;
                continue;
            }
            if (after_key[i] == '"') break;
        }
        if (i >= after_key.len) break;
        const value = after_key[start..i];
        i += 1; // skip closing quote
        try items.append(allocator, try allocator.dupe(u8, value));
    }

    return try items.toOwnedSlice(allocator);
}

/// Free a string array returned by parseStringArray.
fn freeStringArray(allocator: std.mem.Allocator, arr: []const []const u8) void {
    for (arr) |item| allocator.free(item);
    allocator.free(arr);
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else if (c == ' ') {
            try buf.append(allocator, '+');
        } else {
            try buf.appendSlice(allocator, &.{ '%', "0123456789ABCDEF"[c >> 4], "0123456789ABCDEF"[c & 0x0f] });
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn apiBaseUrl(allocator: std.mem.Allocator) ![]u8 {
    if (platform.getEnvOrNull(allocator, DECISION_HUB_ENV_API_URL)) |v| {
        defer allocator.free(v);
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len > 0) {
            if (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://")) {
                return allocator.dupe(u8, std.mem.trimRight(u8, trimmed, "/"));
            }
            return std.fmt.allocPrint(allocator, "https://{s}", .{std.mem.trim(u8, trimmed, "/")});
        }
    }
    if (platform.getEnvOrNull(allocator, DHUB_ENV_API_URL)) |v| {
        defer allocator.free(v);
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len > 0) {
            if (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://")) {
                return allocator.dupe(u8, std.mem.trimRight(u8, trimmed, "/"));
            }
            return std.fmt.allocPrint(allocator, "https://{s}", .{std.mem.trim(u8, trimmed, "/")});
        }
    }
    return allocator.dupe(u8, DECISION_HUB_DEFAULT_API_URL);
}

fn apiToken(allocator: std.mem.Allocator) ?[]u8 {
    if (platform.getEnvOrNull(allocator, DECISION_HUB_ENV_TOKEN)) |v| {
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len == 0) {
            allocator.free(v);
            return null;
        }
        if (trimmed.ptr == v.ptr and trimmed.len == v.len) return @constCast(v);
        const out = allocator.dupe(u8, trimmed) catch {
            allocator.free(v);
            return null;
        };
        allocator.free(v);
        return out;
    }
    if (platform.getEnvOrNull(allocator, DHUB_ENV_TOKEN)) |v| {
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len == 0) {
            allocator.free(v);
            return null;
        }
        if (trimmed.ptr == v.ptr and trimmed.len == v.len) return @constCast(v);
        const out = allocator.dupe(u8, trimmed) catch {
            allocator.free(v);
            return null;
        };
        allocator.free(v);
        return out;
    }
    return null;
}

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    token: ?[]const u8,
) !RequestHeaders {
    if (token) |t| {
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{t});
        const headers = try allocator.alloc([]const u8, 1);
        headers[0] = auth;
        return .{ .headers = headers, .owned_auth = auth };
    }
    const empty = try allocator.alloc([]const u8, 0);
    return .{ .headers = empty, .owned_auth = null };
}

fn freeRequestHeaders(
    allocator: std.mem.Allocator,
    bundle: RequestHeaders,
) void {
    if (bundle.owned_auth) |auth| allocator.free(auth);
    allocator.free(bundle.headers);
}

fn jsonObjectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn validSkillSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    for (segment) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return false;
    }
    return true;
}

pub fn isDecisionHubSkillRef(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return false;
    if (std.mem.indexOfScalarPos(u8, trimmed, slash + 1, '/')) |_| return false;
    const org = trimmed[0..slash];
    const name = trimmed[slash + 1 ..];
    return validSkillSegment(org) and validSkillSegment(name);
}

pub fn parseDecisionHubSkillRef(input: []const u8) !DecisionHubSkillRef {
    if (!isDecisionHubSkillRef(input)) return error.InvalidSkillReference;
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const slash = std.mem.indexOfScalar(u8, trimmed, '/').?;
    return .{
        .org_slug = trimmed[0..slash],
        .skill_name = trimmed[slash + 1 ..],
    };
}

pub fn freeDecisionHubSearchResults(allocator: std.mem.Allocator, results: []DecisionHubSearchResult) void {
    for (results) |r| {
        allocator.free(r.org_slug);
        allocator.free(r.skill_name);
        allocator.free(r.description);
        allocator.free(r.safety_rating);
        allocator.free(r.latest_version);
    }
    allocator.free(results);
}

pub fn freeDecisionHubInstallResult(allocator: std.mem.Allocator, result: *const DecisionHubInstallResult) void {
    allocator.free(result.org_slug);
    allocator.free(result.skill_name);
    allocator.free(result.installed_name);
    allocator.free(result.resolved_version);
}

pub fn searchDecisionHubSkills(
    allocator: std.mem.Allocator,
    query: []const u8,
    max_results: usize,
) ![]DecisionHubSearchResult {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyQuery;

    const api_url = try apiBaseUrl(allocator);
    defer allocator.free(api_url);
    const encoded_query = try urlEncode(allocator, trimmed);
    defer allocator.free(encoded_query);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/ask?q={s}", .{ api_url, encoded_query });
    defer allocator.free(url);

    const token = apiToken(allocator);
    defer if (token) |t| allocator.free(t);
    const header_bundle = try buildRequestHeaders(allocator, token);
    defer freeRequestHeaders(allocator, header_bundle);

    const response = try http_util.request_with_mode(allocator, decisionHubTransportConfig(), .{
        .method = "GET",
        .url = url,
        .headers = header_bundle.headers,
        .body = null,
        .timeout_ms = 30_000,
        .subsystem = .tools,
    });
    defer allocator.free(response.body);

    if (response.status_code != 200) return error.DecisionHubSearchFailed;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDecisionHubResponse;
    const skills_val = parsed.value.object.get("skills") orelse return try allocator.alloc(DecisionHubSearchResult, 0);
    if (skills_val != .array) return try allocator.alloc(DecisionHubSearchResult, 0);

    var out: std.ArrayList(DecisionHubSearchResult) = .empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.org_slug);
            allocator.free(item.skill_name);
            allocator.free(item.description);
            allocator.free(item.safety_rating);
            allocator.free(item.latest_version);
        }
        out.deinit(allocator);
    }

    var i: usize = 0;
    while (i < skills_val.array.items.len and i < max_results) : (i += 1) {
        const item = skills_val.array.items[i];
        if (item != .object) continue;
        const org_slug = jsonObjectString(item.object, "org_slug") orelse continue;
        const skill_name = jsonObjectString(item.object, "skill_name") orelse continue;
        const description = jsonObjectString(item.object, "description") orelse "";
        const safety_rating = jsonObjectString(item.object, "safety_rating") orelse "";
        const latest_version = jsonObjectString(item.object, "latest_version") orelse "";

        try out.append(allocator, .{
            .org_slug = try allocator.dupe(u8, org_slug),
            .skill_name = try allocator.dupe(u8, skill_name),
            .description = try allocator.dupe(u8, description),
            .safety_rating = try allocator.dupe(u8, safety_rating),
            .latest_version = try allocator.dupe(u8, latest_version),
        });
    }
    return try out.toOwnedSlice(allocator);
}

const ResolvedDecisionHubSkill = struct {
    org_slug: []const u8,
    skill_name: []const u8,
    version: []const u8,
    download_url: []const u8,
    checksum: []const u8,
};

fn resolveDecisionHubSkill(
    allocator: std.mem.Allocator,
    ref: DecisionHubSkillRef,
    options: DecisionHubInstallOptions,
) !ResolvedDecisionHubSkill {
    const api_url = try apiBaseUrl(allocator);
    defer allocator.free(api_url);
    const encoded_spec = try urlEncode(allocator, options.spec);
    defer allocator.free(encoded_spec);
    const allow_risky_str = if (options.allow_risky) "true" else "false";
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/v1/resolve/{s}/{s}?spec={s}&allow_risky={s}",
        .{ api_url, ref.org_slug, ref.skill_name, encoded_spec, allow_risky_str },
    );
    defer allocator.free(url);

    const token = apiToken(allocator);
    defer if (token) |t| allocator.free(t);
    const header_bundle = try buildRequestHeaders(allocator, token);
    defer freeRequestHeaders(allocator, header_bundle);

    const response = try http_util.request_with_mode(allocator, decisionHubTransportConfig(), .{
        .method = "GET",
        .url = url,
        .headers = header_bundle.headers,
        .body = null,
        .timeout_ms = 60_000,
        .subsystem = .tools,
    });
    defer allocator.free(response.body);

    if (response.status_code == 404) return error.SkillNotFound;
    if (response.status_code != 200) return error.DecisionHubResolveFailed;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDecisionHubResponse;
    const version = jsonObjectString(parsed.value.object, "version") orelse return error.InvalidDecisionHubResponse;
    const download_url = jsonObjectString(parsed.value.object, "download_url") orelse return error.InvalidDecisionHubResponse;
    const checksum = jsonObjectString(parsed.value.object, "checksum") orelse return error.InvalidDecisionHubResponse;

    return .{
        .org_slug = try allocator.dupe(u8, ref.org_slug),
        .skill_name = try allocator.dupe(u8, ref.skill_name),
        .version = try allocator.dupe(u8, version),
        .download_url = try allocator.dupe(u8, download_url),
        .checksum = try allocator.dupe(u8, checksum),
    };
}

fn freeResolvedDecisionHubSkill(allocator: std.mem.Allocator, resolved: *const ResolvedDecisionHubSkill) void {
    allocator.free(resolved.org_slug);
    allocator.free(resolved.skill_name);
    allocator.free(resolved.version);
    allocator.free(resolved.download_url);
    allocator.free(resolved.checksum);
}

fn verifySha256Hex(bytes: []const u8, expected_hex: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    const trimmed_expected = std.mem.trim(u8, expected_hex, " \t\r\n");
    return std.ascii.eqlIgnoreCase(actual_hex[0..], trimmed_expected);
}

fn commandSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn extractZipArchive(
    allocator: std.mem.Allocator,
    zip_path: []const u8,
    output_dir: []const u8,
) !void {
    const unzip_res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "unzip", "-qq", "-o", zip_path, "-d", output_dir },
        .max_output_bytes = 8 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (unzip_res) |res| {
        defer {
            allocator.free(res.stdout);
            allocator.free(res.stderr);
        }
        if (commandSucceeded(res.term)) return;
    }

    const bsdtar_res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bsdtar", "-xf", zip_path, "-C", output_dir },
        .max_output_bytes = 8 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingArchiveExtractor,
        else => return err,
    };
    defer {
        allocator.free(bsdtar_res.stdout);
        allocator.free(bsdtar_res.stderr);
    }
    if (!commandSucceeded(bsdtar_res.term)) return error.ZipExtractFailed;
}

fn findInstalledSkillSourceDir(allocator: std.mem.Allocator, extracted_dir: []const u8) ![]u8 {
    const root_manifest = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{extracted_dir});
    defer allocator.free(root_manifest);
    if (std.fs.accessAbsolute(root_manifest, .{})) |_| {
        return allocator.dupe(u8, extracted_dir);
    } else |_| {}

    const dir = try std.fs.openDirAbsolute(extracted_dir, .{ .iterate = true });
    var dir_mut = dir;
    defer dir_mut.close();
    var it = dir_mut.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extracted_dir, entry.name });
        defer allocator.free(candidate);
        const candidate_manifest = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{candidate});
        defer allocator.free(candidate_manifest);
        if (std.fs.accessAbsolute(candidate_manifest, .{})) |_| {
            return allocator.dupe(u8, candidate);
        } else |_| {}
    }
    return error.ManifestNotFound;
}

fn ensureSyntheticManifestIfMissing(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    resolved: ResolvedDecisionHubSkill,
) !void {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{source_dir});
    defer allocator.free(manifest_path);
    if (std.fs.accessAbsolute(manifest_path, .{})) |_| return else |_| {}

    const description = try std.fmt.allocPrint(
        allocator,
        "Installed from Decision Hub: {s}/{s}",
        .{ resolved.org_slug, resolved.skill_name },
    );
    defer allocator.free(description);

    const manifest_json = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\",\"version\":\"{s}\",\"description\":\"{s}\",\"author\":\"{s}\"}}",
        .{ resolved.skill_name, resolved.version, description, resolved.org_slug },
    );
    defer allocator.free(manifest_json);

    const f = try std.fs.createFileAbsolute(manifest_path, .{});
    defer f.close();
    try f.writeAll(manifest_json);
}

fn installResolvedDecisionHubSkill(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    resolved: ResolvedDecisionHubSkill,
) !DecisionHubInstallResult {
    const response = try http_util.request_with_mode(allocator, decisionHubTransportConfig(), .{
        .method = "GET",
        .url = resolved.download_url,
        .headers = &.{},
        .body = null,
        .timeout_ms = 120_000,
        .subsystem = .tools,
    });
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.DecisionHubDownloadFailed;
    if (!verifySha256Hex(response.body, resolved.checksum)) return error.DecisionHubChecksumMismatch;

    const tmp_dir = try std.fmt.allocPrint(allocator, "{s}/state/tmp", .{workspace_dir});
    defer allocator.free(tmp_dir);
    std.fs.makeDirAbsolute(tmp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => std.fs.cwd().makePath(tmp_dir) catch return err,
    };

    const nonce = std.crypto.random.int(u64);
    const zip_path = try std.fmt.allocPrint(allocator, "{s}/decision-hub-{d}.zip", .{ tmp_dir, nonce });
    defer allocator.free(zip_path);
    const extracted_dir = try std.fmt.allocPrint(allocator, "{s}/decision-hub-{d}", .{ tmp_dir, nonce });
    defer allocator.free(extracted_dir);
    defer std.fs.deleteTreeAbsolute(extracted_dir) catch {};
    defer std.fs.deleteFileAbsolute(zip_path) catch {};

    {
        const f = try std.fs.createFileAbsolute(zip_path, .{});
        defer f.close();
        try f.writeAll(response.body);
    }
    std.fs.makeDirAbsolute(extracted_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try extractZipArchive(allocator, zip_path, extracted_dir);
    const source_dir = findInstalledSkillSourceDir(allocator, extracted_dir) catch |err| switch (err) {
        error.ManifestNotFound => try allocator.dupe(u8, extracted_dir),
        else => return err,
    };
    defer allocator.free(source_dir);
    try ensureSyntheticManifestIfMissing(allocator, source_dir, resolved);
    try installSkillFromPath(allocator, source_dir, workspace_dir);

    const installed_skill = try loadSkill(allocator, source_dir);
    defer freeSkill(allocator, &installed_skill);
    return .{
        .org_slug = try allocator.dupe(u8, resolved.org_slug),
        .skill_name = try allocator.dupe(u8, resolved.skill_name),
        .installed_name = try allocator.dupe(u8, installed_skill.name),
        .resolved_version = try allocator.dupe(u8, resolved.version),
    };
}

pub fn installSkillFromDecisionHubRef(
    allocator: std.mem.Allocator,
    skill_ref: []const u8,
    workspace_dir: []const u8,
    options: DecisionHubInstallOptions,
) !DecisionHubInstallResult {
    const ref = try parseDecisionHubSkillRef(skill_ref);
    const resolved = try resolveDecisionHubSkill(allocator, ref, options);
    defer freeResolvedDecisionHubSkill(allocator, &resolved);
    return installResolvedDecisionHubSkill(allocator, workspace_dir, resolved);
}

pub fn installSkillFromDecisionHubQueryOrRef(
    allocator: std.mem.Allocator,
    query_or_ref: []const u8,
    workspace_dir: []const u8,
    options: DecisionHubInstallOptions,
) !DecisionHubInstallResult {
    const trimmed = std.mem.trim(u8, query_or_ref, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyQuery;
    if (isDecisionHubSkillRef(trimmed)) {
        return installSkillFromDecisionHubRef(allocator, trimmed, workspace_dir, options);
    }

    const hits = try searchDecisionHubSkills(allocator, trimmed, 1);
    defer freeDecisionHubSearchResults(allocator, hits);
    if (hits.len == 0) return error.SkillNotFound;

    const ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ hits[0].org_slug, hits[0].skill_name });
    defer allocator.free(ref);
    return installSkillFromDecisionHubRef(allocator, ref, workspace_dir, options);
}

/// Parse a skill.json manifest from raw JSON bytes.
/// Returns slices pointing into the original json_bytes (no allocations needed
/// beyond what the caller already owns for json_bytes).
/// Note: requires_bins and requires_env are heap-allocated; caller must use allocator version.
pub fn parseManifest(json_bytes: []const u8) !SkillManifest {
    const name = parseStringField(json_bytes, "name") orelse return error.MissingField;
    const version = parseStringField(json_bytes, "version") orelse "0.0.1";
    const description = parseStringField(json_bytes, "description") orelse "";
    const author = parseStringField(json_bytes, "author") orelse "";

    return SkillManifest{
        .name = name,
        .version = version,
        .description = description,
        .author = author,
        .always = parseBoolField(json_bytes, "always") orelse false,
    };
}

/// Parse a skill.json manifest with allocator support for array fields.
pub fn parseManifestAlloc(allocator: std.mem.Allocator, json_bytes: []const u8) !SkillManifest {
    var m = try parseManifest(json_bytes);
    m.requires_bins = parseStringArray(allocator, json_bytes, "requires_bins") catch &.{};
    m.requires_env = parseStringArray(allocator, json_bytes, "requires_env") catch &.{};
    return m;
}

// ── Skill Loading ───────────────────────────────────────────────

/// Load a single skill from a directory.
/// Reads skill.json (required) and SKILL.md (optional) from skill_dir_path.
pub fn loadSkill(allocator: std.mem.Allocator, skill_dir_path: []const u8) !Skill {
    // Read skill.json
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{skill_dir_path});
    defer allocator.free(manifest_path);

    const manifest_bytes = std.fs.cwd().readFileAlloc(allocator, manifest_path, 64 * 1024) catch
        return error.ManifestNotFound;
    defer allocator.free(manifest_bytes);

    const manifest = parseManifestAlloc(allocator, manifest_bytes) catch
        (parseManifest(manifest_bytes) catch return error.InvalidManifest);

    // Dupe all strings so they outlive the manifest_bytes buffer
    const name = try allocator.dupe(u8, manifest.name);
    errdefer allocator.free(name);
    const version = try allocator.dupe(u8, manifest.version);
    errdefer allocator.free(version);
    const description = try allocator.dupe(u8, manifest.description);
    errdefer allocator.free(description);
    const author = try allocator.dupe(u8, manifest.author);
    errdefer allocator.free(author);
    const path = try allocator.dupe(u8, skill_dir_path);
    errdefer allocator.free(path);

    // Try to read SKILL.md (optional)
    const instructions_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir_path});
    defer allocator.free(instructions_path);

    const instructions = std.fs.cwd().readFileAlloc(allocator, instructions_path, 256 * 1024) catch
        try allocator.dupe(u8, "");

    return Skill{
        .name = name,
        .version = version,
        .description = description,
        .author = author,
        .instructions = instructions,
        .enabled = true,
        .always = manifest.always,
        .requires_bins = manifest.requires_bins,
        .requires_env = manifest.requires_env,
        .path = path,
    };
}

/// Free all heap-allocated fields of a Skill.
pub fn freeSkill(allocator: std.mem.Allocator, skill: *const Skill) void {
    if (skill.name.len > 0) allocator.free(skill.name);
    if (skill.version.len > 0) allocator.free(skill.version);
    if (skill.description.len > 0) allocator.free(skill.description);
    if (skill.author.len > 0) allocator.free(skill.author);
    allocator.free(skill.instructions);
    if (skill.path.len > 0) allocator.free(skill.path);
    if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    if (skill.requires_bins.len > 0) freeStringArray(allocator, skill.requires_bins);
    if (skill.requires_env.len > 0) freeStringArray(allocator, skill.requires_env);
}

/// Free a slice of skills and all their contents.
pub fn freeSkills(allocator: std.mem.Allocator, skills_slice: []Skill) void {
    for (skills_slice) |*s| {
        freeSkill(allocator, s);
    }
    allocator.free(skills_slice);
}

// ── Requirement Checking ────────────────────────────────────────

/// Check whether a skill's required binaries and env vars are available.
/// Updates skill.available and skill.missing_deps in place.
pub fn checkRequirements(allocator: std.mem.Allocator, skill: *Skill) void {
    var missing: std.ArrayListUnmanaged(u8) = .empty;

    // Check required binaries via `which`
    for (skill.requires_bins) |bin| {
        const found = checkBinaryExists(allocator, bin);
        if (!found) {
            if (missing.items.len > 0) missing.append(allocator, ',') catch {};
            missing.append(allocator, ' ') catch {};
            missing.appendSlice(allocator, "bin:") catch {};
            missing.appendSlice(allocator, bin) catch {};
        }
    }

    // Check required environment variables
    for (skill.requires_env) |env_name| {
        const val = platform.getEnvOrNull(allocator, env_name);
        defer if (val) |v| allocator.free(v);
        if (val == null) {
            if (missing.items.len > 0) missing.append(allocator, ',') catch {};
            missing.append(allocator, ' ') catch {};
            missing.appendSlice(allocator, "env:") catch {};
            missing.appendSlice(allocator, env_name) catch {};
        }
    }

    if (missing.items.len > 0) {
        skill.available = false;
        skill.missing_deps = missing.toOwnedSlice(allocator) catch "";
    } else {
        skill.available = true;
        missing.deinit(allocator);
    }
}

/// Check if a binary exists on PATH using `which`.
fn checkBinaryExists(allocator: std.mem.Allocator, bin_name: []const u8) bool {
    var child = std.process.Child.init(&.{ "which", bin_name }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// ── Listing ─────────────────────────────────────────────────────

/// Scan workspace_dir/skills/ for subdirectories, loading each as a Skill.
/// Returns owned slice; caller must free with freeSkills().
pub fn listSkills(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]Skill {
    const skills_dir_path = try std.fmt.allocPrint(allocator, "{s}/skills", .{workspace_dir});
    defer allocator.free(skills_dir_path);

    var skills_list: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills_list.items) |*s| freeSkill(allocator, s);
        skills_list.deinit(allocator);
    }

    const dir = std.fs.cwd().openDir(skills_dir_path, .{ .iterate = true }) catch {
        // Directory doesn't exist or can't be opened — return empty
        return try skills_list.toOwnedSlice(allocator);
    };
    // Note: openDir returns by value in Zig 0.15, no need to dereference
    var dir_mut = dir;
    defer dir_mut.close();

    var it = dir_mut.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ skills_dir_path, entry.name });
        defer allocator.free(sub_path);

        if (loadSkill(allocator, sub_path)) |skill| {
            try skills_list.append(allocator, skill);
        } else |_| {
            // Skip directories without valid skill.json
            continue;
        }
    }

    // S5.5 — sort by name for byte-stable prompt prefix. POSIX directory-
    // iteration order is filesystem-dependent (ext4 can change it across
    // mount remaps; tmpfs differs from it; container layer diffs in CI
    // vs prod). Without an explicit sort, the Skills section of the
    // system prompt could shuffle between the local dev run and the
    // container deploy — cache miss with no visible cause.
    std.mem.sort(Skill, skills_list.items, {}, skillLessThanByName);

    return try skills_list.toOwnedSlice(allocator);
}

fn skillLessThanByName(_: void, a: Skill, b: Skill) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Load skills from two sources: built-in and workspace.
/// Workspace skills with the same name override built-in skills.
/// Also runs checkRequirements() on each loaded skill.
pub fn listSkillsMerged(allocator: std.mem.Allocator, builtin_dir: []const u8, workspace_dir: []const u8) ![]Skill {
    // Load built-in skills first
    const builtin = listSkills(allocator, builtin_dir) catch try allocator.alloc(Skill, 0);

    // Load workspace skills
    const workspace = listSkills(allocator, workspace_dir) catch try allocator.alloc(Skill, 0);

    // Build a set of workspace skill names for override detection
    var ws_names = std.StringHashMap(void).init(allocator);
    defer ws_names.deinit();
    for (workspace) |s| {
        ws_names.put(s.name, {}) catch {};
    }

    // Merge: keep built-in skills that are NOT overridden
    var merged: std.ArrayList(Skill) = .empty;
    errdefer {
        for (merged.items) |*s| freeSkill(allocator, s);
        merged.deinit(allocator);
    }

    for (builtin) |s| {
        if (ws_names.contains(s.name)) {
            // Overridden by workspace — free the built-in copy
            var s_mut = s;
            freeSkill(allocator, &s_mut);
        } else {
            try merged.append(allocator, s);
        }
    }
    allocator.free(builtin); // free outer slice only (items moved into merged or freed)

    // Add all workspace skills
    for (workspace) |s| {
        try merged.append(allocator, s);
    }
    allocator.free(workspace);

    // Check requirements for all skills
    for (merged.items) |*s| {
        checkRequirements(allocator, s);
    }

    // S5.5 — sort merged output by name. Both inputs are now sorted (see
    // listSkills), but the merge above appends non-overridden builtins
    // first, then all workspace skills — the concatenation is not
    // necessarily alphabetical. Explicit sort ensures the Skills section
    // renders byte-stably regardless of builtin/workspace split.
    std.mem.sort(Skill, merged.items, {}, skillLessThanByName);

    return try merged.toOwnedSlice(allocator);
}

// ── Installation ────────────────────────────────────────────────

/// Install a skill by copying its directory into workspace_dir/skills/<name>/.
/// source_path must contain a valid skill.json.
pub fn installSkillFromPath(allocator: std.mem.Allocator, source_path: []const u8, workspace_dir: []const u8) !void {
    // Validate source has a manifest
    const src_manifest_path = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{source_path});
    defer allocator.free(src_manifest_path);

    const manifest_bytes = std.fs.cwd().readFileAlloc(allocator, src_manifest_path, 64 * 1024) catch
        return error.ManifestNotFound;
    defer allocator.free(manifest_bytes);

    const manifest = parseManifest(manifest_bytes) catch return error.InvalidManifest;

    // Sanitize skill name for safe path usage
    for (manifest.name) |c| {
        if (c == '/' or c == '\\' or c == 0) return error.UnsafeName;
    }
    if (manifest.name.len == 0 or std.mem.eql(u8, manifest.name, "..")) return error.UnsafeName;

    // Ensure skills directory exists
    const skills_dir_path = try std.fmt.allocPrint(allocator, "{s}/skills", .{workspace_dir});
    defer allocator.free(skills_dir_path);
    std.fs.makeDirAbsolute(skills_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Create target directory
    const target_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ workspace_dir, manifest.name });
    defer allocator.free(target_path);
    std.fs.makeDirAbsolute(target_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Copy skill.json
    const dst_manifest = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{target_path});
    defer allocator.free(dst_manifest);
    try copyFileAbsolute(src_manifest_path, dst_manifest);

    // Copy SKILL.md if present
    const src_instructions = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{source_path});
    defer allocator.free(src_instructions);
    const dst_instructions = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{target_path});
    defer allocator.free(dst_instructions);
    copyFileAbsolute(src_instructions, dst_instructions) catch {
        // SKILL.md is optional, ignore if missing
    };
}

/// Copy a file from src to dst using absolute paths.
fn copyFileAbsolute(src: []const u8, dst: []const u8) !void {
    const src_file = try std.fs.openFileAbsolute(src, .{});
    defer src_file.close();

    const dst_file = try std.fs.createFileAbsolute(dst, .{});
    defer dst_file.close();

    // Read and write in chunks
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = src_file.read(&buf) catch return error.ReadError;
        if (n == 0) break;
        dst_file.writeAll(buf[0..n]) catch return error.WriteError;
    }
}

// ── Removal ─────────────────────────────────────────────────────

/// Remove a skill by deleting its directory from workspace_dir/skills/<name>/.
pub fn removeSkill(allocator: std.mem.Allocator, name: []const u8, workspace_dir: []const u8) !void {
    // Sanitize name
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return error.UnsafeName;
    }
    if (name.len == 0 or std.mem.eql(u8, name, "..")) return error.UnsafeName;

    const skill_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ workspace_dir, name });
    defer allocator.free(skill_path);

    // Verify the skill directory actually exists before deleting
    std.fs.accessAbsolute(skill_path, .{}) catch return error.SkillNotFound;

    std.fs.deleteTreeAbsolute(skill_path) catch |err| {
        return err;
    };
}

// ── Community Skills Sync ────────────────────────────────────────

pub const COMMUNITY_SYNC_INTERVAL_DAYS: u64 = 7;
pub const COMMUNITY_SKILLS_ENABLED_ENV = "NULLALIS_COMMUNITY_SKILLS_ENABLED";
pub const COMMUNITY_SKILLS_DIR_ENV = "NULLALIS_COMMUNITY_SKILLS_DIR";
pub const COMMUNITY_SYNC_DEFERRED_MESSAGE = "community skills sync deferred-explicit: source repository connector not configured";

pub const CommunitySkillsSync = struct {
    enabled: bool,
    skills_dir: []const u8,
    sync_marker_path: []const u8,
};

/// Parse integer field from minimal JSON like {"last_sync": 12345}.
fn parseIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}

    if (i >= after_key.len) return null;

    const start = i;
    while (i < after_key.len and (after_key[i] >= '0' and after_key[i] <= '9')) : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(i64, after_key[start..i], 10) catch null;
}

/// Read the last_sync timestamp from a marker file.
/// Returns null if file doesn't exist or can't be parsed.
fn readSyncMarker(marker_path: []const u8, buf: []u8) ?i64 {
    const f = std.fs.cwd().openFile(marker_path, .{}) catch return null;
    defer f.close();
    const n = f.read(buf) catch return null;
    if (n == 0) return null;
    return parseIntField(buf[0..n], "last_sync");
}

/// Write a timestamp into the marker file, creating parent directories as needed.
fn writeSyncMarkerWithTimestamp(allocator: std.mem.Allocator, marker_path: []const u8, timestamp: i64) !void {
    if (std.fs.path.dirname(marker_path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const content = try std.fmt.allocPrint(allocator, "{{\"last_sync\": {d}}}", .{timestamp});
    defer allocator.free(content);

    const f = try std.fs.createFileAbsolute(marker_path, .{});
    defer f.close();
    try f.writeAll(content);
}

/// Write current timestamp into the marker file.
fn writeSyncMarker(allocator: std.mem.Allocator, marker_path: []const u8) !void {
    return writeSyncMarkerWithTimestamp(allocator, marker_path, std.time.timestamp());
}

/// Synchronize community skill metadata without remote repository access.
/// The remote connector is intentionally deferred; this function only updates
/// local sync markers when community sync is enabled.
pub fn syncCommunitySkills(allocator: std.mem.Allocator, workspace_dir: []const u8) !void {
    // Check if enabled via env var
    const enabled_env = platform.getEnvOrNull(allocator, COMMUNITY_SKILLS_ENABLED_ENV);
    defer if (enabled_env) |v| allocator.free(v);
    if (enabled_env == null) return; // not set — disabled
    if (std.mem.eql(u8, enabled_env.?, "false")) return;

    // Determine community skills directory
    const community_dir = blk: {
        if (platform.getEnvOrNull(allocator, COMMUNITY_SKILLS_DIR_ENV)) |dir| {
            break :blk dir;
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}/skills/community", .{workspace_dir});
    };
    defer allocator.free(community_dir);

    // Marker file path
    const marker_path = try std.fmt.allocPrint(allocator, "{s}/state/skills_sync.json", .{workspace_dir});
    defer allocator.free(marker_path);

    // Check if sync is needed
    const now = std.time.timestamp();
    const interval: i64 = @intCast(COMMUNITY_SYNC_INTERVAL_DAYS * 24 * 3600);
    var marker_buf: [256]u8 = undefined;
    if (readSyncMarker(marker_path, &marker_buf)) |last_sync| {
        if (now - last_sync < interval) return; // still fresh
    }

    // Ensure the local community directory exists; remote connector is deferred.
    std.fs.makeDirAbsolute(community_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {},
    };

    // Update marker
    writeSyncMarker(allocator, marker_path) catch {};
}

/// Load community skills from .md files in the community directory.
/// Returns owned slice; caller must free with freeSkills().
pub fn loadCommunitySkills(allocator: std.mem.Allocator, community_dir: []const u8) ![]Skill {
    var skills_list: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills_list.items) |*s| freeSkill(allocator, s);
        skills_list.deinit(allocator);
    }

    const dir = std.fs.cwd().openDir(community_dir, .{ .iterate = true }) catch {
        return try skills_list.toOwnedSlice(allocator);
    };
    var dir_mut = dir;
    defer dir_mut.close();

    var it = dir_mut.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const name_slice = entry.name;
        if (!std.mem.endsWith(u8, name_slice, ".md")) continue;

        // Skill name = filename without .md extension
        const skill_name = name_slice[0 .. name_slice.len - 3];
        if (skill_name.len == 0) continue;

        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ community_dir, name_slice });
        defer allocator.free(file_path);

        const content = std.fs.cwd().readFileAlloc(allocator, file_path, 256 * 1024) catch continue;

        const duped_name = try allocator.dupe(u8, skill_name);
        errdefer allocator.free(duped_name);
        const duped_ver = try allocator.dupe(u8, "0.0.1");
        errdefer allocator.free(duped_ver);

        try skills_list.append(allocator, Skill{
            .name = duped_name,
            .version = duped_ver,
            .instructions = content,
        });
    }

    return try skills_list.toOwnedSlice(allocator);
}

/// Merge community skills into workspace skills, with workspace skills taking priority.
/// Returns a new slice; caller must free with freeSkills().
/// The input slices are consumed (caller must NOT free them separately).
pub fn mergeCommunitySkills(allocator: std.mem.Allocator, workspace_skills: []Skill, community_skills: []Skill) ![]Skill {
    var merged: std.ArrayList(Skill) = .empty;
    errdefer {
        for (merged.items) |*s| freeSkill(allocator, s);
        merged.deinit(allocator);
    }

    // Add all workspace skills first (they have priority)
    for (workspace_skills) |s| {
        try merged.append(allocator, s);
    }

    // Add community skills that don't conflict by name
    for (community_skills) |cs| {
        var found = false;
        for (workspace_skills) |ws| {
            if (std.mem.eql(u8, ws.name, cs.name)) {
                found = true;
                break;
            }
        }
        if (found) {
            // Community skill shadowed by workspace — free it
            var mutable_cs = cs;
            freeSkill(allocator, &mutable_cs);
        } else {
            try merged.append(allocator, cs);
        }
    }

    // Free the input slice containers (but NOT elements — they've been moved)
    allocator.free(workspace_skills);
    allocator.free(community_skills);

    return try merged.toOwnedSlice(allocator);
}

// ── Sync Result API ─────────────────────────────────────────────

pub const SyncResult = struct {
    synced: bool,
    skills_count: u32,
    message: []u8,
};

/// Count .md files in a directory (non-recursive).
fn countMdFiles(dir_path: []const u8) u32 {
    const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
    var dir_mut = dir;
    defer dir_mut.close();

    var count: u32 = 0;
    var it = dir_mut.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".md")) count += 1;
    }
    return count;
}

/// Synchronize community skills and return a result struct with sync status.
/// This wraps syncCommunitySkills with additional information about the outcome.
pub fn syncCommunitySkillsResult(allocator: std.mem.Allocator, workspace_dir: []const u8) !SyncResult {
    // Check if enabled via env var
    const enabled_env = platform.getEnvOrNull(allocator, COMMUNITY_SKILLS_ENABLED_ENV);
    defer if (enabled_env) |v| allocator.free(v);
    if (enabled_env == null) {
        return SyncResult{
            .synced = false,
            .skills_count = 0,
            .message = try allocator.dupe(u8, "community skills sync disabled (env not set)"),
        };
    }
    if (std.mem.eql(u8, enabled_env.?, "false")) {
        return SyncResult{
            .synced = false,
            .skills_count = 0,
            .message = try allocator.dupe(u8, "community skills sync disabled"),
        };
    }

    // Determine community skills directory
    const community_dir = blk: {
        if (platform.getEnvOrNull(allocator, COMMUNITY_SKILLS_DIR_ENV)) |dir| {
            break :blk dir;
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}/skills/community", .{workspace_dir});
    };
    defer allocator.free(community_dir);

    // Marker file path
    const marker_path = try std.fmt.allocPrint(allocator, "{s}/state/skills_sync.json", .{workspace_dir});
    defer allocator.free(marker_path);

    // Check if sync is needed (7-day interval)
    const now = std.time.timestamp();
    const interval: i64 = @intCast(COMMUNITY_SYNC_INTERVAL_DAYS * 24 * 3600);
    var marker_buf: [256]u8 = undefined;
    if (readSyncMarker(marker_path, &marker_buf)) |last_sync| {
        if (now - last_sync < interval) {
            const count = countMdFiles(community_dir);
            return SyncResult{
                .synced = false,
                .skills_count = count,
                .message = try allocator.dupe(u8, "sync skipped, still fresh"),
            };
        }
    }

    std.fs.makeDirAbsolute(community_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {},
    };

    // Update marker
    writeSyncMarker(allocator, marker_path) catch {};

    const count = countMdFiles(community_dir);
    return SyncResult{
        .synced = false,
        .skills_count = count,
        .message = try allocator.dupe(u8, COMMUNITY_SYNC_DEFERRED_MESSAGE),
    };
}

/// Free a SyncResult's heap-allocated message.
pub fn freeSyncResult(allocator: std.mem.Allocator, result: *const SyncResult) void {
    allocator.free(result.message);
}

// ── Tests ───────────────────────────────────────────────────────

test "parseManifest full JSON" {
    const json =
        \\{"name": "code-review", "version": "1.2.0", "description": "Automated code review", "author": "nullalis"}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("code-review", m.name);
    try std.testing.expectEqualStrings("1.2.0", m.version);
    try std.testing.expectEqualStrings("Automated code review", m.description);
    try std.testing.expectEqualStrings("nullalis", m.author);
}

test "parseManifest minimal JSON (name only)" {
    const json =
        \\{"name": "minimal-skill"}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("minimal-skill", m.name);
    try std.testing.expectEqualStrings("0.0.1", m.version);
    try std.testing.expectEqualStrings("", m.description);
    try std.testing.expectEqualStrings("", m.author);
}

test "parseManifest missing name returns error" {
    const json =
        \\{"version": "1.0.0", "description": "no name"}
    ;
    try std.testing.expectError(error.MissingField, parseManifest(json));
}

test "parseManifest empty JSON object returns error" {
    try std.testing.expectError(error.MissingField, parseManifest("{}"));
}

test "parseManifest handles whitespace in JSON" {
    const json =
        \\{
        \\  "name": "spaced-skill",
        \\  "version": "0.1.0",
        \\  "description": "A skill with whitespace",
        \\  "author": "tester"
        \\}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("spaced-skill", m.name);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqualStrings("A skill with whitespace", m.description);
    try std.testing.expectEqualStrings("tester", m.author);
}

test "parseManifest handles escaped quotes" {
    const json =
        \\{"name": "escape-test", "description": "says \"hello\""}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("escape-test", m.name);
    try std.testing.expectEqualStrings("says \\\"hello\\\"", m.description);
}

test "parseStringField basic" {
    const json = "{\"command\": \"echo hello\", \"other\": \"val\"}";
    const val = parseStringField(json, "command");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("echo hello", val.?);
}

test "parseStringField missing key" {
    const json = "{\"other\": \"val\"}";
    try std.testing.expect(parseStringField(json, "command") == null);
}

test "parseStringField non-string value" {
    const json = "{\"count\": 42}";
    try std.testing.expect(parseStringField(json, "count") == null);
}

test "Skill struct defaults" {
    const s = Skill{ .name = "test" };
    try std.testing.expectEqualStrings("test", s.name);
    try std.testing.expectEqualStrings("0.0.1", s.version);
    try std.testing.expectEqualStrings("", s.description);
    try std.testing.expectEqualStrings("", s.author);
    try std.testing.expectEqualStrings("", s.instructions);
    try std.testing.expect(s.enabled);
}

test "Skill struct custom values" {
    const s = Skill{
        .name = "custom",
        .version = "2.0.0",
        .description = "A custom skill",
        .author = "dev",
        .instructions = "Do the thing",
        .enabled = false,
    };
    try std.testing.expectEqualStrings("custom", s.name);
    try std.testing.expectEqualStrings("2.0.0", s.version);
    try std.testing.expectEqualStrings("A custom skill", s.description);
    try std.testing.expectEqualStrings("dev", s.author);
    try std.testing.expectEqualStrings("Do the thing", s.instructions);
    try std.testing.expect(!s.enabled);
}

test "SkillManifest fields" {
    const m = SkillManifest{
        .name = "test",
        .version = "1.0.0",
        .description = "desc",
        .author = "author",
    };
    try std.testing.expectEqualStrings("test", m.name);
    try std.testing.expectEqualStrings("1.0.0", m.version);
}

test "listSkills from nonexistent directory" {
    const allocator = std.testing.allocator;
    const skills = try listSkills(allocator, "/tmp/nullalis-test-skills-nonexistent-dir");
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

test "listSkills from empty directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills");

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const skills = try listSkills(allocator, base);
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

test "loadSkill reads manifest and instructions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup: create skill directory with manifest and instructions
    {
        const sub = try std.fs.path.join(allocator, &.{ "skills", "test-skill" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }

    // Write skill.json
    {
        const rel = try std.fs.path.join(allocator, &.{ "skills", "test-skill", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"test-skill\", \"version\": \"1.0.0\", \"description\": \"A test\", \"author\": \"tester\"}");
    }

    // Write SKILL.md
    {
        const rel = try std.fs.path.join(allocator, &.{ "skills", "test-skill", "SKILL.md" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("# Test Skill\nDo the test thing.");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skill_dir = try std.fs.path.join(allocator, &.{ base, "skills", "test-skill" });
    defer allocator.free(skill_dir);

    const skill = try loadSkill(allocator, skill_dir);
    defer freeSkill(allocator, &skill);

    try std.testing.expectEqualStrings("test-skill", skill.name);
    try std.testing.expectEqualStrings("1.0.0", skill.version);
    try std.testing.expectEqualStrings("A test", skill.description);
    try std.testing.expectEqualStrings("tester", skill.author);
    try std.testing.expectEqualStrings("# Test Skill\nDo the test thing.", skill.instructions);
    try std.testing.expect(skill.enabled);
}

test "loadSkill without SKILL.md still works" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const sub = try std.fs.path.join(allocator, &.{ "skills", "bare-skill" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }

    // Write only skill.json, no SKILL.md
    {
        const rel = try std.fs.path.join(allocator, &.{ "skills", "bare-skill", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"bare-skill\", \"version\": \"0.5.0\"}");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skill_dir = try std.fs.path.join(allocator, &.{ base, "skills", "bare-skill" });
    defer allocator.free(skill_dir);

    const skill = try loadSkill(allocator, skill_dir);
    defer freeSkill(allocator, &skill);

    try std.testing.expectEqualStrings("bare-skill", skill.name);
    try std.testing.expectEqualStrings("0.5.0", skill.version);
    try std.testing.expectEqualStrings("", skill.instructions);
}

test "loadSkill missing manifest returns error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const skill_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(skill_dir);

    try std.testing.expectError(error.ManifestNotFound, loadSkill(allocator, skill_dir));
}

test "listSkills discovers skills in subdirectories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create two skill directories
    {
        const sub = try std.fs.path.join(allocator, &.{ "skills", "alpha" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "skills", "alpha", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"alpha\", \"version\": \"1.0.0\", \"description\": \"First skill\", \"author\": \"dev\"}");
    }

    {
        const sub = try std.fs.path.join(allocator, &.{ "skills", "beta" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "skills", "beta", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"beta\", \"version\": \"2.0.0\", \"description\": \"Second skill\", \"author\": \"dev2\"}");
    }

    // Also create a regular file (should be skipped)
    {
        const rel = try std.fs.path.join(allocator, &.{ "skills", "README.md" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("Not a skill directory");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const skills = try listSkills(allocator, base);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 2), skills.len);

    // Skills may come in any order from directory iteration
    var found_alpha = false;
    var found_beta = false;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "alpha")) found_alpha = true;
        if (std.mem.eql(u8, s.name, "beta")) found_beta = true;
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_beta);
}

test "listSkills returns skills sorted by name regardless of on-disk order [S5.5]" {
    // S5.5 — byte-stability invariant test for the skills surface.
    // Directory iteration order is filesystem-dependent; a skills dir
    // populated in reverse alphabetical order (zulu, mike, alpha) must
    // still render the Skills section of the system prompt with alpha
    // first. Without the sort, the prompt's byte layout drifts between
    // filesystems (tmpfs vs ext4 vs container layer), breaking provider
    // KV cache on every turn.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const names = [_][]const u8{ "zulu", "mike", "alpha" };
    for (names) |name| {
        const sub = try std.fs.path.join(allocator, &.{ "skills", name });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);

        const rel = try std.fs.path.join(allocator, &.{ "skills", name, "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        const json = try std.fmt.allocPrint(allocator, "{{\"name\": \"{s}\", \"version\": \"1.0.0\", \"description\": \"d\", \"author\": \"a\"}}", .{name});
        defer allocator.free(json);
        try f.writeAll(json);
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const skills = try listSkills(allocator, base);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 3), skills.len);
    try std.testing.expectEqualStrings("alpha", skills[0].name);
    try std.testing.expectEqualStrings("mike", skills[1].name);
    try std.testing.expectEqualStrings("zulu", skills[2].name);
}

test "listSkills skips directories without valid manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One valid skill
    {
        const sub = try std.fs.path.join(allocator, &.{ "skills", "valid" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "skills", "valid", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"valid\"}");
    }

    // One empty directory (no manifest)
    {
        const sub = try std.fs.path.join(allocator, &.{ "skills", "broken" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const skills = try listSkills(allocator, base);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("valid", skills[0].name);
}

test "installSkillFromPath and removeSkill roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup workspace and source directories
    try tmp.dir.makePath("workspace");
    try tmp.dir.makePath("source");

    // Write source skill files
    {
        const rel = try std.fs.path.join(allocator, &.{ "source", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"installable\", \"version\": \"1.0.0\", \"description\": \"Test install\", \"author\": \"dev\"}");
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "source", "SKILL.md" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("# Instructions\nInstall me.");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const workspace = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(workspace);
    const source = try std.fs.path.join(allocator, &.{ base, "source" });
    defer allocator.free(source);

    // Install
    try installSkillFromPath(allocator, source, workspace);

    // Verify installed skill loads
    const skills = try listSkills(allocator, workspace);
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("installable", skills[0].name);
    try std.testing.expectEqualStrings("# Instructions\nInstall me.", skills[0].instructions);

    // Remove
    try removeSkill(allocator, "installable", workspace);

    // Verify removal
    const after = try listSkills(allocator, workspace);
    defer freeSkills(allocator, after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "installSkillFromPath rejects missing manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("source");
    try tmp.dir.makePath("workspace");

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const source = try std.fs.path.join(allocator, &.{ base, "source" });
    defer allocator.free(source);
    const workspace = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(workspace);

    try std.testing.expectError(error.ManifestNotFound, installSkillFromPath(allocator, source, workspace));
}

test "removeSkill nonexistent returns SkillNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills");

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    try std.testing.expectError(error.SkillNotFound, removeSkill(allocator, "nonexistent", workspace));
}

test "removeSkill rejects unsafe names" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "../etc", "/tmp"));
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "foo/bar", "/tmp"));
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "", "/tmp"));
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "..", "/tmp"));
}

test "installSkillFromPath rejects unsafe skill names" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("source");
    try tmp.dir.makePath("workspace");

    // Write a manifest with a malicious name
    {
        const rel = try std.fs.path.join(allocator, &.{ "source", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"../../../etc/passwd\"}");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const source = try std.fs.path.join(allocator, &.{ base, "source" });
    defer allocator.free(source);
    const workspace = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(workspace);

    try std.testing.expectError(error.UnsafeName, installSkillFromPath(allocator, source, workspace));
}

// ── Community Sync Tests ────────────────────────────────────────

test "parseIntField basic" {
    const json = "{\"last_sync\": 1700000000}";
    const val = parseIntField(json, "last_sync");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 1700000000), val.?);
}

test "parseIntField missing key" {
    const json = "{\"other\": 42}";
    try std.testing.expect(parseIntField(json, "last_sync") == null);
}

test "parseIntField non-numeric value" {
    const json = "{\"last_sync\": \"not_a_number\"}";
    try std.testing.expect(parseIntField(json, "last_sync") == null);
}

test "sync marker read/write roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const marker = try std.fs.path.join(allocator, &.{ base, "state", "skills_sync.json" });
    defer allocator.free(marker);

    // Write marker with known timestamp
    try writeSyncMarkerWithTimestamp(allocator, marker, 1700000000);

    // Read it back
    var buf: [256]u8 = undefined;
    const ts = readSyncMarker(marker, &buf);
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 1700000000), ts.?);
}

test "readSyncMarker returns null for nonexistent file" {
    var buf: [256]u8 = undefined;
    const ts = readSyncMarker("/tmp/nullalis-nonexistent-marker-file.json", &buf);
    try std.testing.expect(ts == null);
}

test "syncCommunitySkills disabled when env not set" {
    // NULLALIS_COMMUNITY_SKILLS_ENABLED is not set in test environment,
    // so syncCommunitySkills should return immediately without doing anything
    const allocator = std.testing.allocator;
    try syncCommunitySkills(allocator, "/tmp/nullalis-test-sync-disabled");
    // No error = success (function returned early)
}

test "loadCommunitySkills from nonexistent directory" {
    const allocator = std.testing.allocator;
    const skills = try loadCommunitySkills(allocator, "/tmp/nullalis-test-community-nonexistent");
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

test "loadCommunitySkills loads .md files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("community");

    // Create two .md files and one non-.md file
    {
        const rel = try std.fs.path.join(allocator, &.{ "community", "code-review.md" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("Review code carefully.");
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "community", "refactor.md" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("Refactor for clarity.");
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "community", "README.txt" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("Not a skill.");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const community_dir = try std.fs.path.join(allocator, &.{ base, "community" });
    defer allocator.free(community_dir);

    const skills = try loadCommunitySkills(allocator, community_dir);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 2), skills.len);

    var found_review = false;
    var found_refactor = false;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "code-review")) {
            found_review = true;
            try std.testing.expectEqualStrings("Review code carefully.", s.instructions);
        }
        if (std.mem.eql(u8, s.name, "refactor")) {
            found_refactor = true;
            try std.testing.expectEqualStrings("Refactor for clarity.", s.instructions);
        }
    }
    try std.testing.expect(found_review);
    try std.testing.expect(found_refactor);
}

test "mergeCommunitySkills workspace takes priority" {
    const allocator = std.testing.allocator;

    // Create workspace skills (must dupe version since freeSkill frees it)
    var ws = try allocator.alloc(Skill, 1);
    ws[0] = Skill{
        .name = try allocator.dupe(u8, "my-skill"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .instructions = try allocator.dupe(u8, "workspace version"),
    };

    // Create community skills with one overlap and one unique
    var cs = try allocator.alloc(Skill, 2);
    cs[0] = Skill{
        .name = try allocator.dupe(u8, "my-skill"),
        .version = try allocator.dupe(u8, "0.0.1"),
        .instructions = try allocator.dupe(u8, "community version"),
    };
    cs[1] = Skill{
        .name = try allocator.dupe(u8, "community-only"),
        .version = try allocator.dupe(u8, "0.0.1"),
        .instructions = try allocator.dupe(u8, "from community"),
    };

    const merged = try mergeCommunitySkills(allocator, ws, cs);
    defer freeSkills(allocator, merged);

    // Should have 2 skills: workspace "my-skill" + community "community-only"
    try std.testing.expectEqual(@as(usize, 2), merged.len);

    var found_ws = false;
    var found_community = false;
    for (merged) |s| {
        if (std.mem.eql(u8, s.name, "my-skill")) {
            found_ws = true;
            try std.testing.expectEqualStrings("workspace version", s.instructions);
        }
        if (std.mem.eql(u8, s.name, "community-only")) {
            found_community = true;
            try std.testing.expectEqualStrings("from community", s.instructions);
        }
    }
    try std.testing.expect(found_ws);
    try std.testing.expect(found_community);
}

test "CommunitySkillsSync struct" {
    const sync = CommunitySkillsSync{
        .enabled = true,
        .skills_dir = "/tmp/skills/community",
        .sync_marker_path = "/tmp/state/skills_sync.json",
    };
    try std.testing.expect(sync.enabled);
    try std.testing.expectEqualStrings("/tmp/skills/community", sync.skills_dir);
}

test "community skills env constants are set" {
    try std.testing.expectEqualStrings("NULLALIS_COMMUNITY_SKILLS_ENABLED", COMMUNITY_SKILLS_ENABLED_ENV);
    try std.testing.expectEqualStrings("NULLALIS_COMMUNITY_SKILLS_DIR", COMMUNITY_SKILLS_DIR_ENV);
}

test "COMMUNITY_SYNC_INTERVAL_DAYS is 7" {
    try std.testing.expectEqual(@as(u64, 7), COMMUNITY_SYNC_INTERVAL_DAYS);
}

// ── Progressive Loading Tests ───────────────────────────────────

test "parseBoolField true" {
    const json = "{\"always\": true}";
    try std.testing.expectEqual(@as(?bool, true), parseBoolField(json, "always"));
}

test "parseBoolField false" {
    const json = "{\"always\": false}";
    try std.testing.expectEqual(@as(?bool, false), parseBoolField(json, "always"));
}

test "parseBoolField missing returns null" {
    const json = "{\"name\": \"test\"}";
    try std.testing.expect(parseBoolField(json, "always") == null);
}

test "parseStringArray basic" {
    const allocator = std.testing.allocator;
    const json = "{\"requires_bins\": [\"docker\", \"git\"]}";
    const arr = try parseStringArray(allocator, json, "requires_bins");
    defer freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("docker", arr[0]);
    try std.testing.expectEqualStrings("git", arr[1]);
}

test "parseStringArray empty array" {
    const allocator = std.testing.allocator;
    const json = "{\"requires_bins\": []}";
    const arr = try parseStringArray(allocator, json, "requires_bins");
    defer if (arr.len > 0) freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "parseStringArray missing key" {
    const allocator = std.testing.allocator;
    const json = "{\"name\": \"test\"}";
    const arr = try parseStringArray(allocator, json, "requires_bins");
    defer if (arr.len > 0) freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "parseStringArray single element" {
    const allocator = std.testing.allocator;
    const json = "{\"requires_env\": [\"API_KEY\"]}";
    const arr = try parseStringArray(allocator, json, "requires_env");
    defer freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expectEqualStrings("API_KEY", arr[0]);
}

test "parseManifest reads always field" {
    const json =
        \\{"name": "deploy", "always": true}
    ;
    const m = try parseManifest(json);
    try std.testing.expect(m.always);
}

test "parseManifest always defaults to false" {
    const json =
        \\{"name": "helper"}
    ;
    const m = try parseManifest(json);
    try std.testing.expect(!m.always);
}

test "parseManifestAlloc reads requires_bins" {
    const allocator = std.testing.allocator;
    const json = "{\"name\": \"deploy\", \"requires_bins\": [\"docker\", \"kubectl\"]}";
    const m = try parseManifestAlloc(allocator, json);
    defer freeStringArray(allocator, m.requires_bins);

    try std.testing.expectEqual(@as(usize, 2), m.requires_bins.len);
    try std.testing.expectEqualStrings("docker", m.requires_bins[0]);
    try std.testing.expectEqualStrings("kubectl", m.requires_bins[1]);
}

test "parseManifestAlloc reads requires_env" {
    const allocator = std.testing.allocator;
    const json = "{\"name\": \"deploy\", \"requires_env\": [\"AWS_KEY\"]}";
    const m = try parseManifestAlloc(allocator, json);
    defer freeStringArray(allocator, m.requires_env);

    try std.testing.expectEqual(@as(usize, 1), m.requires_env.len);
    try std.testing.expectEqualStrings("AWS_KEY", m.requires_env[0]);
}

test "Skill struct progressive loading defaults" {
    const s = Skill{ .name = "test" };
    try std.testing.expect(!s.always);
    try std.testing.expect(s.available);
    try std.testing.expectEqual(@as(usize, 0), s.requires_bins.len);
    try std.testing.expectEqual(@as(usize, 0), s.requires_env.len);
    try std.testing.expectEqualStrings("", s.missing_deps);
    try std.testing.expectEqualStrings("", s.path);
}

test "checkRequirements marks available when no requirements" {
    const allocator = std.testing.allocator;
    var skill = Skill{ .name = "simple" };
    checkRequirements(allocator, &skill);
    try std.testing.expect(skill.available);
    try std.testing.expectEqualStrings("", skill.missing_deps);
}

test "checkRequirements detects missing env var" {
    const allocator = std.testing.allocator;
    const env_arr = try allocator.alloc([]const u8, 1);
    env_arr[0] = try allocator.dupe(u8, "NULLALIS_TEST_NONEXISTENT_VAR_XYZ123");
    var skill = Skill{
        .name = "needs-env",
        .requires_env = env_arr,
    };
    checkRequirements(allocator, &skill);
    defer if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    defer freeStringArray(allocator, skill.requires_env);

    try std.testing.expect(!skill.available);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "env:NULLALIS_TEST_NONEXISTENT_VAR_XYZ123") != null);
}

test "checkBinaryExists finds common binary" {
    const allocator = std.testing.allocator;
    try std.testing.expect(checkBinaryExists(allocator, "ls"));
}

test "checkBinaryExists returns false for nonexistent binary" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!checkBinaryExists(allocator, "nullalis_nonexistent_binary_xyz"));
}

test "loadSkill reads always field" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"always-skill\", \"always\": true, \"requires_bins\": [\"ls\"]}");
    }

    const skill_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(skill_dir);

    const skill = try loadSkill(allocator, skill_dir);
    defer freeSkill(allocator, &skill);

    try std.testing.expect(skill.always);
    try std.testing.expectEqual(@as(usize, 1), skill.requires_bins.len);
    try std.testing.expectEqualStrings("ls", skill.requires_bins[0]);
    try std.testing.expectEqualStrings(skill_dir, skill.path);
}

test "listSkillsMerged workspace overrides builtin" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup builtin
    {
        const sub = try std.fs.path.join(allocator, &.{ "builtin", "skills", "shared" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }
    {
        const sub = try std.fs.path.join(allocator, &.{ "builtin", "skills", "builtin-only" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }

    {
        const rel = try std.fs.path.join(allocator, &.{ "builtin", "skills", "shared", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"shared\", \"description\": \"builtin version\"}");
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "builtin", "skills", "builtin-only", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"builtin-only\", \"description\": \"only in builtin\"}");
    }

    // Setup workspace
    {
        const sub = try std.fs.path.join(allocator, &.{ "workspace", "skills", "shared" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }
    {
        const sub = try std.fs.path.join(allocator, &.{ "workspace", "skills", "ws-only" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }

    {
        const rel = try std.fs.path.join(allocator, &.{ "workspace", "skills", "shared", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"shared\", \"description\": \"workspace version\"}");
    }
    {
        const rel = try std.fs.path.join(allocator, &.{ "workspace", "skills", "ws-only", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"ws-only\", \"description\": \"only in workspace\"}");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const builtin_base = try std.fs.path.join(allocator, &.{ base, "builtin" });
    defer allocator.free(builtin_base);
    const ws_base = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(ws_base);

    const skills = try listSkillsMerged(allocator, builtin_base, ws_base);
    defer freeSkills(allocator, skills);

    // Should have 3 skills: builtin-only, shared (ws version), ws-only
    try std.testing.expectEqual(@as(usize, 3), skills.len);

    var found_builtin_only = false;
    var found_ws_only = false;
    var shared_desc: ?[]const u8 = null;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "builtin-only")) found_builtin_only = true;
        if (std.mem.eql(u8, s.name, "ws-only")) found_ws_only = true;
        if (std.mem.eql(u8, s.name, "shared")) shared_desc = s.description;
    }
    try std.testing.expect(found_builtin_only);
    try std.testing.expect(found_ws_only);
    // Workspace version should win
    try std.testing.expectEqualStrings("workspace version", shared_desc.?);
}

test "listSkillsMerged with nonexistent dirs returns empty" {
    const allocator = std.testing.allocator;
    const skills = try listSkillsMerged(allocator, "/tmp/nullalis-nonexistent-a", "/tmp/nullalis-nonexistent-b");
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

// Repo-root `skills/` is the shipped builtin-skill source (see
// docs/superpowers/plans/CARRY-FORWARD-loadable-skills-and-skill-author.md
// item A — Dockerfile COPYs it to /opt/nullalis/skills/, the pod entrypoint
// seeds it onto {HOME}/.nullalis/skills/ at boot, and appendSkillsSection
// (src/agent/prompt.zig) loads that seeded path as listSkillsMerged's
// builtin_dir). This test loads the actual on-disk directory (relative to
// the repo root, where `zig build test` runs) to prove the shipped
// skills/spawn/skill.json is a valid manifest AND that listSkillsMerged
// actually discovers it — not just that the JSON parses in isolation.
test "listSkillsMerged discovers the shipped spawn skill" {
    const allocator = std.testing.allocator;
    // listSkills/listSkillsMerged always scan "{dir}/skills/" (see listSkills's
    // doc comment above) — the caller passes the PARENT of the skills/ folder,
    // not the folder itself. The repo root is that parent for the shipped
    // skills/spawn/ directory, and `zig build test` runs with cwd at the
    // repo root (verified: build.zig does not override addRunArtifact's cwd).
    const skills = try listSkillsMerged(allocator, ".", "/tmp/nullalis-nonexistent-workspace-spawn-skill-test");
    defer freeSkills(allocator, skills);

    var found: ?Skill = null;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "spawn")) found = s;
    }
    const skill = found orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("spawn", skill.name);
    // Deep playbook, load-on-need — must render as an XML summary in the
    // prompt (appendSkillsSection), not inline full instructions on every
    // turn. See skill.json's "always": false.
    try std.testing.expectEqual(false, skill.always);
    try std.testing.expect(skill.description.len > 0);
    try std.testing.expect(skill.instructions.len > 0);
}

test "checkRequirements detects missing binary" {
    const allocator = std.testing.allocator;
    const bin_arr = try allocator.alloc([]const u8, 1);
    bin_arr[0] = try allocator.dupe(u8, "nullalis_nonexistent_xyz_bin");
    var skill = Skill{
        .name = "needs-bin",
        .requires_bins = bin_arr,
    };
    checkRequirements(allocator, &skill);
    defer if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    defer freeStringArray(allocator, skill.requires_bins);

    try std.testing.expect(!skill.available);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "bin:nullalis_nonexistent_xyz_bin") != null);
}

test "checkRequirements detects both missing bin and env" {
    const allocator = std.testing.allocator;
    const bin_arr = try allocator.alloc([]const u8, 1);
    bin_arr[0] = try allocator.dupe(u8, "nullalis_missing_bin_abc");
    const env_arr = try allocator.alloc([]const u8, 1);
    env_arr[0] = try allocator.dupe(u8, "NULLALIS_MISSING_ENV_ABC");
    var skill = Skill{
        .name = "needs-both",
        .requires_bins = bin_arr,
        .requires_env = env_arr,
    };
    checkRequirements(allocator, &skill);
    defer if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    defer freeStringArray(allocator, skill.requires_bins);
    defer freeStringArray(allocator, skill.requires_env);

    try std.testing.expect(!skill.available);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "bin:nullalis_missing_bin_abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "env:NULLALIS_MISSING_ENV_ABC") != null);
}

test "listSkillsMerged runs checkRequirements" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup builtin with a skill that requires a nonexistent binary
    {
        const sub = try std.fs.path.join(allocator, &.{ "builtin", "skills", "needy" });
        defer allocator.free(sub);
        try tmp.dir.makePath(sub);
    }

    {
        const rel = try std.fs.path.join(allocator, &.{ "builtin", "skills", "needy", "skill.json" });
        defer allocator.free(rel);
        const f = try tmp.dir.createFile(rel, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"needy\", \"description\": \"needs stuff\", \"requires_bins\": [\"nullalis_fake_bin_zzz\"]}");
    }

    // Empty workspace
    try tmp.dir.makePath("workspace");

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const builtin_base = try std.fs.path.join(allocator, &.{ base, "builtin" });
    defer allocator.free(builtin_base);
    const ws_base = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(ws_base);

    const skills = try listSkillsMerged(allocator, builtin_base, ws_base);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 1), skills.len);
    // checkRequirements should have been called by listSkillsMerged
    try std.testing.expect(!skills[0].available);
    try std.testing.expect(std.mem.indexOf(u8, skills[0].missing_deps, "bin:nullalis_fake_bin_zzz") != null);
}

// ── SyncResult API Tests ────────────────────────────────────────

test "SyncResult struct fields" {
    const allocator = std.testing.allocator;
    const msg = try allocator.dupe(u8, "test message");
    const result = SyncResult{
        .synced = true,
        .skills_count = 42,
        .message = msg,
    };
    defer freeSyncResult(allocator, &result);

    try std.testing.expect(result.synced);
    try std.testing.expectEqual(@as(u32, 42), result.skills_count);
    try std.testing.expectEqualStrings("test message", result.message);
}

test "syncCommunitySkillsResult disabled when env not set" {
    // NULLALIS_COMMUNITY_SKILLS_ENABLED is not set in test environment
    const allocator = std.testing.allocator;
    const result = try syncCommunitySkillsResult(allocator, "/tmp/nullalis-test-sync-result-disabled");
    defer freeSyncResult(allocator, &result);

    try std.testing.expect(!result.synced);
    try std.testing.expectEqual(@as(u32, 0), result.skills_count);
    try std.testing.expectEqualStrings("community skills sync disabled (env not set)", result.message);
}

test "countMdFiles returns zero for nonexistent dir" {
    const count = countMdFiles("/tmp/nullalis-test-countmd-nonexistent");
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "countMdFiles counts only .md files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("countmd");

    // Create 3 .md files and 2 non-.md files
    inline for (.{ "a.md", "b.md", "c.md", "readme.txt", "data.json" }) |name| {
        const f = try tmp.dir.createFile("countmd" ++ std.fs.path.sep_str ++ name, .{});
        f.close();
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const dir = try std.fs.path.join(allocator, &.{ base, "countmd" });
    defer allocator.free(dir);

    const count = countMdFiles(dir);
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "freeSyncResult frees message" {
    const allocator = std.testing.allocator;
    const msg = try allocator.dupe(u8, "allocated message");
    const result = SyncResult{
        .synced = false,
        .skills_count = 0,
        .message = msg,
    };
    // freeSyncResult should not leak — testing allocator will catch leaks
    freeSyncResult(allocator, &result);
}

test "isDecisionHubSkillRef accepts org/skill format" {
    try std.testing.expect(isDecisionHubSkillRef("pymc-labs/causalpy"));
    try std.testing.expect(isDecisionHubSkillRef("acme-org/my_skill.v2"));
}

test "isDecisionHubSkillRef rejects malformed input" {
    try std.testing.expect(!isDecisionHubSkillRef("just-one"));
    try std.testing.expect(!isDecisionHubSkillRef("bad/ref/extra"));
    try std.testing.expect(!isDecisionHubSkillRef("bad ref/name"));
}

test "parseDecisionHubSkillRef splits org and skill" {
    const parsed = try parseDecisionHubSkillRef("pymc-labs/causalpy");
    try std.testing.expectEqualStrings("pymc-labs", parsed.org_slug);
    try std.testing.expectEqualStrings("causalpy", parsed.skill_name);
}

test "decision hub transport uses curl_only mode" {
    const cfg = decisionHubTransportConfig();
    try std.testing.expectEqual(http_util.TransportMode.curl_only, cfg.mode);
}

test "verifySha256Hex validates expected digest" {
    const data = "hello";
    // SHA-256("hello")
    const good = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    const bad = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expect(verifySha256Hex(data, good));
    try std.testing.expect(!verifySha256Hex(data, bad));
}
