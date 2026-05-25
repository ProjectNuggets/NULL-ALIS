const std = @import("std");
const build_options = @import("build_options");
const channel_catalog = @import("../channel_catalog.zig");
const config_mod = @import("../config.zig");
const http_util = @import("../http_util.zig");
const zaki_session = @import("../session/root.zig");
const zaki_state = @import("../zaki_state.zig");

pub const Source = enum {
    gateway_internal,
    local_fallback,

    pub fn toSlice(self: Source) []const u8 {
        return switch (self) {
            .gateway_internal => "gateway_internal",
            .local_fallback => "local_fallback",
        };
    }
};

pub const RuntimeSnapshot = struct {
    source: Source,
    state_backend_configured: []u8,
    state_backend_effective: []u8,
    scheduler_backend: []u8,
    degraded: bool,
    degraded_reason: []u8,
    heartbeat_enabled: bool,
    heartbeat_interval_minutes: u32,
    tenant_enabled: bool,
    scheduler_max_tasks_configured: u32,
    scheduler_max_concurrent_configured: u32,
    scheduler_max_tasks_effective: ?u32 = null,
    chat_provider_effective: []u8,
    chat_fallback_chain: []u8,
    embedding_provider_effective: []u8,
    provider_data_source: []u8,
    telegram_configured: ?bool = null,
    telegram_connected: ?bool = null,
    telegram_account_id: ?[]u8 = null,
    telegram_chat_id: ?i64 = null,
    telegram_data_source: ?[]u8 = null,
    context_incomplete: bool = false,
    identity_mapped: ?u64 = null,
    identity_unmapped: ?u64 = null,
    identity_strict_rejected: ?u64 = null,
    identity_degraded_compat: ?u64 = null,
    identity_cache_hit: ?u64 = null,
    identity_cache_miss: ?u64 = null,
    identity_cache_stale: ?u64 = null,
    identity_db_lookup_count: ?u64 = null,
    identity_db_lookup_ms_total: ?u64 = null,
    tenant_lock_conflicts_chat_stream_sse: ?u64 = null,
    tenant_lock_conflicts_chat_stream_http: ?u64 = null,
    tenant_lock_conflicts_webhook: ?u64 = null,
    tenant_lock_conflicts_daemon: ?u64 = null,
    tenant_lock_conflicts_api: ?u64 = null,
    stt_transcriber_configured: ?u64 = null,
    stt_transcription_attempted: ?u64 = null,
    stt_transcription_succeeded: ?u64 = null,
    stt_transcription_failed: ?u64 = null,
    stt_transcription_skipped_no_transcriber: ?u64 = null,
    multimodal_image_markers_detected: ?u64 = null,
    multimodal_messages_with_image_markers: ?u64 = null,
    multimodal_image_parts_prepared: ?u64 = null,
    multimodal_image_parts_failed: ?u64 = null,
    multimodal_image_markers_ignored: ?u64 = null,
    proactive_last_status: ?[]u8 = null,
    proactive_last_reason: ?[]u8 = null,
    proactive_policy_dedupe_window_secs: ?u64 = null,
    proactive_policy_rate_window_secs: ?u64 = null,
    proactive_policy_rate_limit_per_window: ?u64 = null,
    heartbeat_runtime_available: ?bool = null,
    heartbeat_runtime_last_run_s: ?i64 = null,
    heartbeat_runtime_last_status: ?[]u8 = null,
    heartbeat_runtime_last_reason: ?[]u8 = null,
    tenant_lease_probe_user_id: ?[]u8 = null,
    tenant_lease_probe_data_source: ?[]u8 = null,
    tenant_lease_probe_owner_id: ?[]u8 = null,
    tenant_lease_probe_lease_until_s: ?i64 = null,
    tenant_lease_probe_updated_at_s: ?i64 = null,

    pub fn deinit(self: *RuntimeSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.state_backend_configured);
        allocator.free(self.state_backend_effective);
        allocator.free(self.scheduler_backend);
        allocator.free(self.degraded_reason);
        allocator.free(self.chat_provider_effective);
        allocator.free(self.chat_fallback_chain);
        allocator.free(self.embedding_provider_effective);
        allocator.free(self.provider_data_source);
        if (self.telegram_account_id) |value| allocator.free(value);
        if (self.telegram_data_source) |value| allocator.free(value);
        if (self.proactive_last_status) |value| allocator.free(value);
        if (self.proactive_last_reason) |value| allocator.free(value);
        if (self.heartbeat_runtime_last_status) |value| allocator.free(value);
        if (self.heartbeat_runtime_last_reason) |value| allocator.free(value);
        if (self.tenant_lease_probe_user_id) |value| allocator.free(value);
        if (self.tenant_lease_probe_data_source) |value| allocator.free(value);
        if (self.tenant_lease_probe_owner_id) |value| allocator.free(value);
    }
};

pub const ExecutionTruth = struct {
    task: []u8,
    task_key: ?[]u8,
    owner: []u8,
    owner_source: []u8,
    status: []u8,
    result: []u8,
    failure: []u8,
    degraded: bool,
    degraded_reason: []u8,
    fallback_active: bool,
    fallback_reason: []u8,
    fallback_chain: []u8,

    pub fn deinit(self: *ExecutionTruth, allocator: std.mem.Allocator) void {
        allocator.free(self.task);
        if (self.task_key) |value| allocator.free(value);
        allocator.free(self.owner);
        allocator.free(self.owner_source);
        allocator.free(self.status);
        allocator.free(self.result);
        allocator.free(self.failure);
        allocator.free(self.degraded_reason);
        allocator.free(self.fallback_reason);
        allocator.free(self.fallback_chain);
    }
};

pub const ExecutionTaskFocus = struct {
    task_snapshot: ?zaki_state.TaskSnapshot = null,
    task_session_key: ?[]u8 = null,
    selection_rule: []const u8 = "current_session",

    pub fn deinit(self: *ExecutionTaskFocus, allocator: std.mem.Allocator) void {
        if (self.task_snapshot) |*snapshot| snapshot.deinit(allocator);
        if (self.task_session_key) |value| allocator.free(value);
    }
};

pub fn deriveExecutionTruth(
    allocator: std.mem.Allocator,
    snapshot: *const RuntimeSnapshot,
    task_snapshot: ?*const zaki_state.TaskSnapshot,
    session_key: ?[]const u8,
    owner_hint: ?[]const u8,
) !ExecutionTruth {
    const result_label = deriveResultLabel(snapshot, task_snapshot, session_key);
    const failure_label = deriveFailureLabel(task_snapshot);
    const degraded = deriveDegraded(snapshot);
    const owner, const owner_source = deriveOwnerTruth(snapshot, owner_hint);
    const fallback_active, const fallback_reason = deriveFallbackState(snapshot);

    return .{
        .task = try allocator.dupe(u8, deriveTaskLabel(session_key)),
        .task_key = if (session_key) |value| try allocator.dupe(u8, value) else null,
        .owner = try allocator.dupe(u8, owner),
        .owner_source = try allocator.dupe(u8, owner_source),
        .status = try allocator.dupe(u8, deriveStatusLabel(degraded, task_snapshot, session_key, result_label)),
        .result = try allocator.dupe(u8, result_label),
        .failure = try allocator.dupe(u8, failure_label),
        .degraded = degraded,
        .degraded_reason = try allocator.dupe(u8, deriveDegradedReason(snapshot)),
        .fallback_active = fallback_active,
        .fallback_reason = try allocator.dupe(u8, fallback_reason),
        .fallback_chain = try allocator.dupe(u8, snapshot.chat_fallback_chain),
    };
}

fn deriveTaskLabel(session_key: ?[]const u8) []const u8 {
    const key = session_key orelse return "idle";
    if (std.mem.indexOf(u8, key, ":task:") != null or std.mem.startsWith(u8, key, "task:")) return "task";
    if (std.mem.indexOf(u8, key, ":thread:") != null or std.mem.startsWith(u8, key, "thread:")) return "thread";
    if (std.mem.indexOf(u8, key, ":cron:") != null or std.mem.startsWith(u8, key, "cron:")) return "cron";
    if (std.mem.endsWith(u8, key, ":main") or std.mem.eql(u8, key, "main")) return "main";
    return "session";
}

fn deriveResultLabel(snapshot: *const RuntimeSnapshot, task_snapshot: ?*const zaki_state.TaskSnapshot, session_key: ?[]const u8) []const u8 {
    if (task_snapshot) |task| {
        if (task.result) |value| return value;
        if (std.mem.eql(u8, task.status, "failed")) return "failed";
        if (std.mem.eql(u8, task.status, "completed")) return "completed";
        return task.status;
    }
    if (snapshot.heartbeat_runtime_last_status) |value| return value;
    if (snapshot.proactive_last_status) |value| return value;
    if (session_key != null) return "in_progress";
    return "none";
}

fn deriveFailureLabel(task_snapshot: ?*const zaki_state.TaskSnapshot) []const u8 {
    if (task_snapshot) |task| {
        if (task.error_msg) |value| return value;
    }
    return "";
}

fn deriveDegraded(snapshot: *const RuntimeSnapshot) bool {
    return snapshot.degraded or snapshot.context_incomplete;
}

fn deriveDegradedReason(snapshot: *const RuntimeSnapshot) []const u8 {
    if (snapshot.degraded_reason.len > 0) return snapshot.degraded_reason;
    if (snapshot.context_incomplete) return "context_incomplete";
    return "";
}

fn deriveStatusLabel(degraded: bool, task_snapshot: ?*const zaki_state.TaskSnapshot, session_key: ?[]const u8, result_label: []const u8) []const u8 {
    if (degraded) return "degraded";
    if (task_snapshot) |task| {
        if (std.mem.eql(u8, task.status, "failed") or task.error_msg != null) return "attention";
    }
    if (isAttentionResult(result_label)) return "attention";
    if (session_key != null) return "active";
    return "ready";
}

fn deriveOwnerTruth(snapshot: *const RuntimeSnapshot, owner_hint: ?[]const u8) struct { []const u8, []const u8 } {
    if (snapshot.tenant_lease_probe_owner_id) |owner_id| {
        return .{ owner_id, snapshot.tenant_lease_probe_data_source orelse "tenant_lease_probe" };
    }
    if (owner_hint) |hint| return .{ hint, "scoped_user_id" };
    return .{ "unowned", "none" };
}

fn deriveFallbackState(snapshot: *const RuntimeSnapshot) struct { bool, []const u8 } {
    if (snapshot.source == .local_fallback) return .{ true, "local_fallback" };
    if (snapshot.context_incomplete) return .{ true, "context_incomplete" };
    if (isExplicitFallbackSource(snapshot.provider_data_source)) {
        return .{ true, snapshot.provider_data_source };
    }
    return .{ false, "" };
}

fn isExplicitFallbackSource(source: []const u8) bool {
    return std.mem.eql(u8, source, "local_fallback") or
        std.mem.eql(u8, source, "file_fallback") or
        std.mem.eql(u8, source, "context_missing");
}

fn isAttentionResult(result_label: []const u8) bool {
    return std.mem.indexOf(u8, result_label, "failed") != null or
        std.mem.indexOf(u8, result_label, "blocked") != null or
        std.mem.indexOf(u8, result_label, "error") != null or
        std.mem.indexOf(u8, result_label, "reconnect") != null or
        std.mem.indexOf(u8, result_label, "timeout") != null;
}

pub fn collectDurableTaskSnapshot(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    state_mgr: ?*zaki_state.Manager,
    numeric_user_id: ?i64,
    user_id: ?[]const u8,
    session_key: ?[]const u8,
) !?zaki_state.TaskSnapshot {
    const task_id = parseTaskIdFromSessionKey(session_key orelse return null) orelse return null;
    if (state_mgr) |mgr| {
        if (numeric_user_id) |resolved_user_id| {
            return try mgr.getTaskSnapshot(allocator, resolved_user_id, task_id);
        }
    }
    const ledger_path = try taskLedgerPath(allocator, cfg, user_id);
    defer allocator.free(ledger_path);
    return try collectTaskSnapshotFromFile(allocator, ledger_path, task_id);
}

pub fn collectExecutionTaskFocus(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    state_mgr: ?*zaki_state.Manager,
    numeric_user_id: ?i64,
    user_id: ?[]const u8,
    session_key: ?[]const u8,
) !ExecutionTaskFocus {
    const current_session_key = session_key orelse return .{};
    if (isTaskSessionKey(current_session_key)) {
        return .{
            .task_snapshot = try collectDurableTaskSnapshot(allocator, cfg, state_mgr, numeric_user_id, user_id, session_key),
            .selection_rule = "current_session",
        };
    }
    if (!isMainSurfaceSessionKey(current_session_key)) return .{};

    if (state_mgr) |mgr| {
        if (numeric_user_id) |resolved_user_id| {
            const snapshots = try mgr.listTaskSnapshots(allocator, resolved_user_id);
            defer {
                for (snapshots) |*snapshot| snapshot.deinit(allocator);
                allocator.free(snapshots);
            }
            if (selectFocusedTaskSnapshotIndex(snapshots, current_session_key)) |idx| {
                return .{
                    .task_snapshot = try dupeTaskSnapshot(allocator, &snapshots[idx]),
                    .task_session_key = try deriveTaskSnapshotRuntimeSessionKey(allocator, &snapshots[idx]),
                    .selection_rule = focusedTaskSelectionRule(&snapshots[idx]),
                };
            }
            return .{};
        }
    }

    const ledger_path = try taskLedgerPath(allocator, cfg, user_id);
    defer allocator.free(ledger_path);
    return try collectFocusedTaskSnapshotFromFile(allocator, ledger_path, current_session_key);
}

fn parseTaskIdFromSessionKey(session_key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, session_key, "task:") and session_key.len > "task:".len) {
        return session_key["task:".len..];
    }
    const marker = ":task:";
    const idx = std.mem.indexOf(u8, session_key, marker) orelse return null;
    const task_id = session_key[idx + marker.len ..];
    if (task_id.len == 0) return null;
    return task_id;
}

fn isTaskSessionKey(session_key: []const u8) bool {
    return std.mem.startsWith(u8, session_key, "task:") or std.mem.indexOf(u8, session_key, ":task:") != null;
}

fn isMainSurfaceSessionKey(session_key: []const u8) bool {
    return std.mem.eql(u8, session_key, "main") or std.mem.endsWith(u8, session_key, ":main");
}

fn deriveLegacyRuntimeSessionKey(allocator: std.mem.Allocator, request_session_key: []const u8, task_id: []const u8) !?[]u8 {
    const user_id = zaki_session.parseUserIdFromSessionKey(request_session_key) orelse return null;
    var session_buf: [128]u8 = undefined;
    const runtime_session_key = zaki_session.userTaskSessionKey(&session_buf, user_id, task_id);
    return @as(?[]u8, try allocator.dupe(u8, runtime_session_key));
}

fn taskLedgerPath(allocator: std.mem.Allocator, cfg: *const config_mod.Config, user_id: ?[]const u8) ![]u8 {
    if (cfg.tenant.enabled and cfg.tenant.data_root.len > 0 and user_id != null) {
        return std.fmt.allocPrint(allocator, "{s}/{s}/workspace/state/subagent_tasks.jsonl", .{ cfg.tenant.data_root, user_id.? });
    }
    return std.fs.path.join(allocator, &.{ cfg.workspace_dir, "state", "subagent_tasks.jsonl" });
}

fn collectTaskSnapshotFromFile(allocator: std.mem.Allocator, path: []const u8, task_id: []const u8) !?zaki_state.TaskSnapshot {
    const file = (if (std.fs.path.isAbsolute(path)) std.fs.openFileAbsolute(path, .{}) else std.fs.cwd().openFile(path, .{})) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(raw);

    var latest: ?zaki_state.TaskSnapshot = null;
    errdefer if (latest) |*snapshot| snapshot.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const snapshot = (try parseTaskSnapshotLedgerObject(allocator, parsed.value.object)) orelse continue;
        errdefer snapshot.deinit(allocator);
        if (!std.mem.eql(u8, snapshot.id, task_id)) {
            var discarded = snapshot;
            discarded.deinit(allocator);
            continue;
        }

        if (latest) |*value| value.deinit(allocator);
        latest = snapshot;
    }
    return latest;
}

fn collectFocusedTaskSnapshotFromFile(allocator: std.mem.Allocator, path: []const u8, request_session_key: []const u8) !ExecutionTaskFocus {
    const file = (if (std.fs.path.isAbsolute(path)) std.fs.openFileAbsolute(path, .{}) else std.fs.cwd().openFile(path, .{})) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(raw);

    var active: ?zaki_state.TaskSnapshot = null;
    var attention: ?zaki_state.TaskSnapshot = null;
    errdefer {
        if (active) |*snapshot| snapshot.deinit(allocator);
        if (attention) |*snapshot| snapshot.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        var snapshot = (try parseTaskSnapshotLedgerObject(allocator, parsed.value.object)) orelse continue;
        errdefer snapshot.deinit(allocator);
        const priority = focusedTaskPriority(&snapshot, request_session_key);
        if (priority == .ignore) {
            snapshot.deinit(allocator);
            continue;
        }

        if (priority == .active) {
            if (active) |*existing| {
                if (!isTaskSnapshotNewer(&snapshot, existing)) {
                    snapshot.deinit(allocator);
                    continue;
                }
                existing.deinit(allocator);
            }
            active = snapshot;
            continue;
        }

        if (attention) |*existing| {
            if (!isTaskSnapshotNewer(&snapshot, existing)) {
                snapshot.deinit(allocator);
                continue;
            }
            existing.deinit(allocator);
        }
        attention = snapshot;
    }

    if (active) |snapshot| {
        if (attention) |*value| value.deinit(allocator);
        return .{
            .task_session_key = try deriveTaskSnapshotRuntimeSessionKey(allocator, &snapshot),
            .task_snapshot = snapshot,
            .selection_rule = "main_active_task",
        };
    }
    if (attention) |snapshot| {
        return .{
            .task_session_key = try deriveTaskSnapshotRuntimeSessionKey(allocator, &snapshot),
            .task_snapshot = snapshot,
            .selection_rule = "main_attention_task",
        };
    }
    return .{};
}

fn parseTaskSnapshotLedgerObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?zaki_state.TaskSnapshot {
    const id_value = obj.get("id") orelse return null;
    const status_value = obj.get("status") orelse return null;
    const label_value = obj.get("label") orelse return null;
    const prompt_value = obj.get("task_prompt") orelse return null;
    const started_value = obj.get("started_at") orelse return null;
    if (id_value != .integer or status_value != .string or label_value != .string or prompt_value != .string or started_value != .integer) return null;

    var id_buf: [32]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{id_value.integer}) catch return null;
    const request_session_value = if (readObjectString(obj, "request_session_key")) |value|
        value
    else if (readObjectString(obj, "session_key")) |value|
        if (!isTaskSessionKey(value)) value else null
    else
        null;

    return .{
        .id = try allocator.dupe(u8, id_text),
        .session_id = if (readObjectString(obj, "runtime_session_key")) |value|
            try allocator.dupe(u8, value)
        else if (readObjectString(obj, "session_key")) |value|
            if (isTaskSessionKey(value))
                try allocator.dupe(u8, value)
            else
                try deriveLegacyRuntimeSessionKey(allocator, value, id_text)
        else
            null,
        .request_session_id = if (request_session_value) |value| try allocator.dupe(u8, value) else null,
        .label = try allocator.dupe(u8, label_value.string),
        .prompt = try allocator.dupe(u8, prompt_value.string),
        .status = try allocator.dupe(u8, status_value.string),
        .result = if (readObjectString(obj, "result")) |value| try allocator.dupe(u8, value) else null,
        .error_msg = if (readObjectString(obj, "error")) |value| try allocator.dupe(u8, value) else null,
        .created_at_ms = started_value.integer,
        .started_at_ms = started_value.integer,
        .completed_at_ms = if (obj.get("completed_at")) |value| switch (value) {
            .integer => value.integer,
            else => null,
        } else null,
    };
}

fn dupeTaskSnapshot(allocator: std.mem.Allocator, snapshot: *const zaki_state.TaskSnapshot) !zaki_state.TaskSnapshot {
    return .{
        .id = try allocator.dupe(u8, snapshot.id),
        .session_id = if (snapshot.session_id) |value| try allocator.dupe(u8, value) else null,
        .request_session_id = if (snapshot.request_session_id) |value| try allocator.dupe(u8, value) else null,
        .label = try allocator.dupe(u8, snapshot.label),
        .prompt = try allocator.dupe(u8, snapshot.prompt),
        .status = try allocator.dupe(u8, snapshot.status),
        .result = if (snapshot.result) |value| try allocator.dupe(u8, value) else null,
        .error_msg = if (snapshot.error_msg) |value| try allocator.dupe(u8, value) else null,
        .created_at_ms = snapshot.created_at_ms,
        .started_at_ms = snapshot.started_at_ms,
        .completed_at_ms = snapshot.completed_at_ms,
    };
}

const FocusedTaskPriority = enum {
    ignore,
    attention,
    active,
};

fn selectFocusedTaskSnapshotIndex(snapshots: []const zaki_state.TaskSnapshot, request_session_key: []const u8) ?usize {
    var active_idx: ?usize = null;
    var attention_idx: ?usize = null;
    for (snapshots, 0..) |*snapshot, idx| {
        const priority = focusedTaskPriority(snapshot, request_session_key);
        switch (priority) {
            .ignore => {},
            .active => {
                if (active_idx) |existing_idx| {
                    if (!isTaskSnapshotNewer(snapshot, &snapshots[existing_idx])) continue;
                }
                active_idx = idx;
            },
            .attention => {
                if (attention_idx) |existing_idx| {
                    if (!isTaskSnapshotNewer(snapshot, &snapshots[existing_idx])) continue;
                }
                attention_idx = idx;
            },
        }
    }
    return active_idx orelse attention_idx;
}

fn focusedTaskPriority(snapshot: *const zaki_state.TaskSnapshot, request_session_key: []const u8) FocusedTaskPriority {
    if (!taskSnapshotMatchesRequestSession(snapshot, request_session_key)) return .ignore;
    if (std.mem.eql(u8, snapshot.status, "running") or std.mem.eql(u8, snapshot.status, "queued")) return .active;
    if (std.mem.eql(u8, snapshot.status, "failed") or snapshot.error_msg != null) return .attention;
    return .ignore;
}

fn focusedTaskSelectionRule(snapshot: *const zaki_state.TaskSnapshot) []const u8 {
    return if (std.mem.eql(u8, snapshot.status, "running") or std.mem.eql(u8, snapshot.status, "queued"))
        "main_active_task"
    else
        "main_attention_task";
}

fn taskSnapshotMatchesRequestSession(snapshot: *const zaki_state.TaskSnapshot, request_session_key: []const u8) bool {
    if (snapshot.request_session_id) |value| return std.mem.eql(u8, value, request_session_key);
    if (snapshot.session_id) |value| {
        return !isTaskSessionKey(value) and std.mem.eql(u8, value, request_session_key);
    }
    return false;
}

fn taskSnapshotOrderingMs(snapshot: *const zaki_state.TaskSnapshot) i64 {
    return snapshot.completed_at_ms orelse snapshot.started_at_ms orelse snapshot.created_at_ms;
}

fn isTaskSnapshotNewer(candidate: *const zaki_state.TaskSnapshot, current: *const zaki_state.TaskSnapshot) bool {
    const candidate_ms = taskSnapshotOrderingMs(candidate);
    const current_ms = taskSnapshotOrderingMs(current);
    if (candidate_ms != current_ms) return candidate_ms > current_ms;
    return std.mem.order(u8, candidate.id, current.id) == .gt;
}

fn deriveTaskSnapshotRuntimeSessionKey(allocator: std.mem.Allocator, snapshot: *const zaki_state.TaskSnapshot) !?[]u8 {
    if (snapshot.session_id) |value| {
        if (snapshot.request_session_id == null and !isTaskSessionKey(value)) {
            return try deriveLegacyRuntimeSessionKey(allocator, value, snapshot.id);
        }
        return try allocator.dupe(u8, value);
    }
    if (snapshot.request_session_id) |value| {
        return try deriveLegacyRuntimeSessionKey(allocator, value, snapshot.id);
    }
    return null;
}

pub fn collectRuntimeSnapshot(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    user_id: ?[]const u8,
) !RuntimeSnapshot {
    return collectGatewayInternalSnapshot(allocator, cfg, user_id) catch
        collectLocalFallbackSnapshot(allocator, cfg, user_id);
}

fn collectGatewayInternalSnapshot(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    user_id: ?[]const u8,
) !RuntimeSnapshot {
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/internal/diagnostics", .{
        cfg.gateway.host,
        cfg.gateway.port,
    });
    defer allocator.free(url);

    var headers: [2][]const u8 = undefined;
    var header_count: usize = 0;
    var token_header_alloc: ?[]u8 = null;
    defer if (token_header_alloc) |h| allocator.free(h);
    var user_header_alloc: ?[]u8 = null;
    defer if (user_header_alloc) |h| allocator.free(h);

    if (cfg.gateway.internal_service_tokens.len > 0) {
        token_header_alloc = try std.fmt.allocPrint(allocator, "X-Internal-Token: {s}", .{
            cfg.gateway.internal_service_tokens[0],
        });
        headers[header_count] = token_header_alloc.?;
        header_count += 1;
    }
    if (user_id) |uid| {
        user_header_alloc = try std.fmt.allocPrint(allocator, "X-Zaki-User-Id: {s}", .{uid});
        headers[header_count] = user_header_alloc.?;
        header_count += 1;
    }

    const response = try http_util.request_with_mode(allocator, .{}, .{
        .subsystem = .system,
        .method = "GET",
        .url = url,
        .headers = headers[0..header_count],
        .timeout_ms = 2_000,
        .max_response_bytes = 512 * 1024,
    });
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.DiagnosticsUnavailable;

    var snapshot = try parseGatewayDiagnosticsPayload(allocator, response.body);
    errdefer snapshot.deinit(allocator);
    var provider_from_config = false;
    snapshot.scheduler_max_tasks_configured = cfg.scheduler.max_tasks;
    snapshot.scheduler_max_concurrent_configured = cfg.scheduler.max_concurrent;
    snapshot.scheduler_max_tasks_effective = cfg.scheduler.max_tasks;
    if (std.mem.eql(u8, snapshot.chat_provider_effective, "unknown")) {
        allocator.free(snapshot.chat_provider_effective);
        snapshot.chat_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.default_provider));
        provider_from_config = true;
    }
    if (std.mem.eql(u8, snapshot.chat_fallback_chain, "none") and cfg.reliability.fallback_providers.len > 0) {
        allocator.free(snapshot.chat_fallback_chain);
        snapshot.chat_fallback_chain = try allocNormalizedFallbackChain(allocator, cfg.reliability.fallback_providers);
        provider_from_config = true;
    }
    if (std.mem.eql(u8, snapshot.embedding_provider_effective, "none") and cfg.memory.search.provider.len > 0) {
        allocator.free(snapshot.embedding_provider_effective);
        snapshot.embedding_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.memory.search.provider));
        provider_from_config = true;
    }
    if (provider_from_config) {
        allocator.free(snapshot.provider_data_source);
        snapshot.provider_data_source = try allocator.dupe(u8, "config");
    }
    if (snapshot.telegram_configured == null and snapshot.telegram_data_source == null) {
        snapshot.telegram_configured = channel_catalog.configuredCount(cfg, .telegram) > 0;
    }
    return snapshot;
}

fn parseGatewayDiagnosticsPayload(allocator: std.mem.Allocator, body: []const u8) !RuntimeSnapshot {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDiagnosticsPayload;
    const startup_value = parsed.value.object.get("startup_self_check") orelse return error.InvalidDiagnosticsPayload;
    if (startup_value != .object) return error.InvalidDiagnosticsPayload;
    const startup = startup_value.object;

    const configured = readObjectString(startup, "state_backend_configured") orelse "unknown";
    const effective = readObjectString(startup, "state_backend_effective") orelse "unknown";
    const scheduler_backend = readObjectString(startup, "scheduler_backend") orelse "unknown";
    const degraded = readObjectBool(startup, "degraded") orelse false;
    const degraded_reason = readObjectString(startup, "degraded_reason") orelse "";
    const heartbeat_enabled = readObjectBool(startup, "heartbeat_enabled") orelse false;
    const heartbeat_interval_minutes = readObjectU32(startup, "heartbeat_interval_minutes") orelse 0;
    const tenant_enabled = readObjectBool(startup, "tenant_enabled") orelse false;
    const chat_provider_effective = normalizeProviderAlias(readObjectString(startup, "chat_provider_effective") orelse "unknown");
    const chat_fallback_chain = normalizeFallbackChain(readObjectString(startup, "chat_fallback_chain") orelse "none");
    const embedding_provider_effective = normalizeProviderAlias(readObjectString(startup, "embedding_provider_effective") orelse "none");
    const provider_data_source = readObjectString(startup, "provider_data_source") orelse "gateway_internal";

    var telegram_configured: ?bool = null;
    var telegram_connected: ?bool = null;
    var telegram_account_id: ?[]u8 = null;
    errdefer if (telegram_account_id) |value| allocator.free(value);
    var telegram_chat_id: ?i64 = null;
    var telegram_data_source: ?[]u8 = null;
    errdefer if (telegram_data_source) |value| allocator.free(value);
    var identity_mapped: ?u64 = null;
    var identity_unmapped: ?u64 = null;
    var identity_strict_rejected: ?u64 = null;
    var identity_degraded_compat: ?u64 = null;
    var identity_cache_hit: ?u64 = null;
    var identity_cache_miss: ?u64 = null;
    var identity_cache_stale: ?u64 = null;
    var identity_db_lookup_count: ?u64 = null;
    var identity_db_lookup_ms_total: ?u64 = null;
    var tenant_lock_conflicts_chat_stream_sse: ?u64 = null;
    var tenant_lock_conflicts_chat_stream_http: ?u64 = null;
    var tenant_lock_conflicts_webhook: ?u64 = null;
    var tenant_lock_conflicts_daemon: ?u64 = null;
    var tenant_lock_conflicts_api: ?u64 = null;
    var stt_transcriber_configured: ?u64 = null;
    var stt_transcription_attempted: ?u64 = null;
    var stt_transcription_succeeded: ?u64 = null;
    var stt_transcription_failed: ?u64 = null;
    var stt_transcription_skipped_no_transcriber: ?u64 = null;
    var multimodal_image_markers_detected: ?u64 = null;
    var multimodal_messages_with_image_markers: ?u64 = null;
    var multimodal_image_parts_prepared: ?u64 = null;
    var multimodal_image_parts_failed: ?u64 = null;
    var multimodal_image_markers_ignored: ?u64 = null;
    var proactive_last_status: ?[]u8 = null;
    errdefer if (proactive_last_status) |value| allocator.free(value);
    var proactive_last_reason: ?[]u8 = null;
    errdefer if (proactive_last_reason) |value| allocator.free(value);
    var proactive_policy_dedupe_window_secs: ?u64 = null;
    var proactive_policy_rate_window_secs: ?u64 = null;
    var proactive_policy_rate_limit_per_window: ?u64 = null;
    var heartbeat_runtime_available: ?bool = null;
    var heartbeat_runtime_last_run_s: ?i64 = null;
    var heartbeat_runtime_last_status: ?[]u8 = null;
    errdefer if (heartbeat_runtime_last_status) |value| allocator.free(value);
    var heartbeat_runtime_last_reason: ?[]u8 = null;
    errdefer if (heartbeat_runtime_last_reason) |value| allocator.free(value);
    var tenant_lease_probe_user_id: ?[]u8 = null;
    errdefer if (tenant_lease_probe_user_id) |value| allocator.free(value);
    var tenant_lease_probe_data_source: ?[]u8 = null;
    errdefer if (tenant_lease_probe_data_source) |value| allocator.free(value);
    var tenant_lease_probe_owner_id: ?[]u8 = null;
    errdefer if (tenant_lease_probe_owner_id) |value| allocator.free(value);
    var tenant_lease_probe_lease_until_s: ?i64 = null;
    var tenant_lease_probe_updated_at_s: ?i64 = null;

    if (parsed.value.object.get("integrations")) |integrations_value| {
        if (integrations_value == .object) {
            if (integrations_value.object.get("telegram")) |telegram_value| {
                if (telegram_value == .object) {
                    telegram_configured = readObjectBool(telegram_value.object, "configured");
                    telegram_connected = readObjectBool(telegram_value.object, "connected");
                    if (readObjectString(telegram_value.object, "account_id")) |value| {
                        if (!std.mem.eql(u8, value, "null")) {
                            telegram_account_id = try allocator.dupe(u8, value);
                        }
                    }
                    telegram_chat_id = readObjectI64(telegram_value.object, "chat_id");
                    if (readObjectString(telegram_value.object, "data_source")) |value| {
                        telegram_data_source = try allocator.dupe(u8, value);
                    }
                    if (telegram_data_source) |source| {
                        if (std.mem.eql(u8, source, "global") and telegram_connected == null and telegram_configured != true) {
                            telegram_configured = null;
                        }
                    }
                }
            }
        }
    }

    if (parsed.value.object.get("identity_mapping")) |identity_value| {
        if (identity_value == .object) {
            identity_mapped = readObjectU64(identity_value.object, "mapped");
            identity_unmapped = readObjectU64(identity_value.object, "unmapped");
            identity_strict_rejected = readObjectU64(identity_value.object, "strict_rejected");
            identity_degraded_compat = readObjectU64(identity_value.object, "degraded_compat");
            identity_cache_hit = readObjectU64(identity_value.object, "cache_hit");
            identity_cache_miss = readObjectU64(identity_value.object, "cache_miss");
            identity_cache_stale = readObjectU64(identity_value.object, "cache_stale");
            identity_db_lookup_count = readObjectU64(identity_value.object, "db_lookup_count");
            identity_db_lookup_ms_total = readObjectU64(identity_value.object, "db_lookup_ms_total");
        }
    }

    if (parsed.value.object.get("tenant_lock_conflicts_by_route")) |route_value| {
        if (route_value == .object) {
            tenant_lock_conflicts_chat_stream_sse = readObjectU64(route_value.object, "chat_stream_sse");
            tenant_lock_conflicts_chat_stream_http = readObjectU64(route_value.object, "chat_stream_http");
            tenant_lock_conflicts_webhook = readObjectU64(route_value.object, "webhook");
            tenant_lock_conflicts_daemon = readObjectU64(route_value.object, "daemon");
            tenant_lock_conflicts_api = readObjectU64(route_value.object, "api");
        }
    }
    if (parsed.value.object.get("stt")) |stt_value| {
        if (stt_value == .object) {
            stt_transcriber_configured = readObjectU64(stt_value.object, "transcriber_configured");
            stt_transcription_attempted = readObjectU64(stt_value.object, "transcription_attempted");
            stt_transcription_succeeded = readObjectU64(stt_value.object, "transcription_succeeded");
            stt_transcription_failed = readObjectU64(stt_value.object, "transcription_failed");
            stt_transcription_skipped_no_transcriber = readObjectU64(stt_value.object, "transcription_skipped_no_transcriber");
        }
    }
    if (parsed.value.object.get("multimodal")) |multimodal_value| {
        if (multimodal_value == .object) {
            multimodal_image_markers_detected = readObjectU64(multimodal_value.object, "image_markers_detected");
            multimodal_messages_with_image_markers = readObjectU64(multimodal_value.object, "messages_with_image_markers");
            multimodal_image_parts_prepared = readObjectU64(multimodal_value.object, "image_parts_prepared");
            multimodal_image_parts_failed = readObjectU64(multimodal_value.object, "image_parts_failed");
            multimodal_image_markers_ignored = readObjectU64(multimodal_value.object, "image_markers_ignored");
        }
    }
    if (parsed.value.object.get("ops_guard")) |ops_value| {
        if (ops_value == .object) {
            if (ops_value.object.get("last_event")) |last_event| {
                if (last_event == .object) {
                    if (readObjectString(last_event.object, "action")) |value| {
                        proactive_last_status = try allocator.dupe(u8, value);
                    }
                    if (readObjectString(last_event.object, "reason")) |value| {
                        proactive_last_reason = try allocator.dupe(u8, value);
                    }
                }
            }
            if (ops_value.object.get("proactive_policy")) |policy_value| {
                if (policy_value == .object) {
                    proactive_policy_dedupe_window_secs = readObjectU64(policy_value.object, "dedupe_window_secs");
                    proactive_policy_rate_window_secs = readObjectU64(policy_value.object, "rate_window_secs");
                    proactive_policy_rate_limit_per_window = readObjectU64(policy_value.object, "rate_limit_per_window");
                }
            }
        }
    }

    if (parsed.value.object.get("heartbeat_runtime")) |heartbeat_runtime_value| {
        if (heartbeat_runtime_value == .object) {
            heartbeat_runtime_available = readObjectBool(heartbeat_runtime_value.object, "available");
            if (readObjectU64(heartbeat_runtime_value.object, "last_run_s")) |value| {
                heartbeat_runtime_last_run_s = @intCast(value);
            }
            if (readObjectString(heartbeat_runtime_value.object, "last_status")) |value| {
                heartbeat_runtime_last_status = try allocator.dupe(u8, value);
            }
            if (readObjectString(heartbeat_runtime_value.object, "last_reason")) |value| {
                heartbeat_runtime_last_reason = try allocator.dupe(u8, value);
            }
        }
    }

    if (parsed.value.object.get("tenant_lease_probe")) |lease_probe_value| {
        if (lease_probe_value == .object) {
            if (readObjectString(lease_probe_value.object, "user_id")) |value| {
                tenant_lease_probe_user_id = try allocator.dupe(u8, value);
            }
            if (readObjectString(lease_probe_value.object, "data_source")) |value| {
                tenant_lease_probe_data_source = try allocator.dupe(u8, value);
            }
            if (readObjectString(lease_probe_value.object, "owner_id")) |value| {
                if (!std.mem.eql(u8, value, "null")) {
                    tenant_lease_probe_owner_id = try allocator.dupe(u8, value);
                }
            }
            tenant_lease_probe_lease_until_s = readObjectI64(lease_probe_value.object, "lease_until_s");
            tenant_lease_probe_updated_at_s = readObjectI64(lease_probe_value.object, "updated_at_s");
        }
    }

    return .{
        .source = .gateway_internal,
        .state_backend_configured = try allocator.dupe(u8, configured),
        .state_backend_effective = try allocator.dupe(u8, effective),
        .scheduler_backend = try allocator.dupe(u8, scheduler_backend),
        .degraded = degraded,
        .degraded_reason = try allocator.dupe(u8, degraded_reason),
        .heartbeat_enabled = heartbeat_enabled,
        .heartbeat_interval_minutes = heartbeat_interval_minutes,
        .tenant_enabled = tenant_enabled,
        .scheduler_max_tasks_configured = 0,
        .scheduler_max_concurrent_configured = 0,
        .chat_provider_effective = try allocator.dupe(u8, chat_provider_effective),
        .chat_fallback_chain = try allocator.dupe(u8, chat_fallback_chain),
        .embedding_provider_effective = try allocator.dupe(u8, embedding_provider_effective),
        .provider_data_source = try allocator.dupe(u8, provider_data_source),
        .telegram_configured = telegram_configured,
        .telegram_connected = telegram_connected,
        .telegram_account_id = telegram_account_id,
        .telegram_chat_id = telegram_chat_id,
        .telegram_data_source = telegram_data_source,
        .identity_mapped = identity_mapped,
        .identity_unmapped = identity_unmapped,
        .identity_strict_rejected = identity_strict_rejected,
        .identity_degraded_compat = identity_degraded_compat,
        .identity_cache_hit = identity_cache_hit,
        .identity_cache_miss = identity_cache_miss,
        .identity_cache_stale = identity_cache_stale,
        .identity_db_lookup_count = identity_db_lookup_count,
        .identity_db_lookup_ms_total = identity_db_lookup_ms_total,
        .tenant_lock_conflicts_chat_stream_sse = tenant_lock_conflicts_chat_stream_sse,
        .tenant_lock_conflicts_chat_stream_http = tenant_lock_conflicts_chat_stream_http,
        .tenant_lock_conflicts_webhook = tenant_lock_conflicts_webhook,
        .tenant_lock_conflicts_daemon = tenant_lock_conflicts_daemon,
        .tenant_lock_conflicts_api = tenant_lock_conflicts_api,
        .stt_transcriber_configured = stt_transcriber_configured,
        .stt_transcription_attempted = stt_transcription_attempted,
        .stt_transcription_succeeded = stt_transcription_succeeded,
        .stt_transcription_failed = stt_transcription_failed,
        .stt_transcription_skipped_no_transcriber = stt_transcription_skipped_no_transcriber,
        .multimodal_image_markers_detected = multimodal_image_markers_detected,
        .multimodal_messages_with_image_markers = multimodal_messages_with_image_markers,
        .multimodal_image_parts_prepared = multimodal_image_parts_prepared,
        .multimodal_image_parts_failed = multimodal_image_parts_failed,
        .multimodal_image_markers_ignored = multimodal_image_markers_ignored,
        .proactive_last_status = proactive_last_status,
        .proactive_last_reason = proactive_last_reason,
        .proactive_policy_dedupe_window_secs = proactive_policy_dedupe_window_secs,
        .proactive_policy_rate_window_secs = proactive_policy_rate_window_secs,
        .proactive_policy_rate_limit_per_window = proactive_policy_rate_limit_per_window,
        .heartbeat_runtime_available = heartbeat_runtime_available,
        .heartbeat_runtime_last_run_s = heartbeat_runtime_last_run_s,
        .heartbeat_runtime_last_status = heartbeat_runtime_last_status,
        .heartbeat_runtime_last_reason = heartbeat_runtime_last_reason,
        .tenant_lease_probe_user_id = tenant_lease_probe_user_id,
        .tenant_lease_probe_data_source = tenant_lease_probe_data_source,
        .tenant_lease_probe_owner_id = tenant_lease_probe_owner_id,
        .tenant_lease_probe_lease_until_s = tenant_lease_probe_lease_until_s,
        .tenant_lease_probe_updated_at_s = tenant_lease_probe_updated_at_s,
    };
}

fn collectLocalFallbackSnapshot(allocator: std.mem.Allocator, cfg: *const config_mod.Config, user_id: ?[]const u8) !RuntimeSnapshot {
    const configured = cfg.state.backend;
    const effective = blk: {
        if (!std.mem.eql(u8, configured, "postgres")) break :blk "file";
        if (!build_options.enable_postgres) break :blk "file";
        break :blk "unknown";
    };
    const scheduler_backend = blk: {
        if (!cfg.tenant.enabled) break :blk "file";
        if (std.mem.eql(u8, configured, "postgres") and build_options.enable_postgres) break :blk "unknown";
        break :blk "file";
    };
    const degraded_reason = if (std.mem.eql(u8, configured, "postgres") and !build_options.enable_postgres)
        "PostgresNotEnabled"
    else
        "";
    const context_incomplete = std.mem.eql(u8, effective, "unknown") or std.mem.eql(u8, scheduler_backend, "unknown");
    const heartbeat_cfg = try readEffectiveLocalHeartbeatConfig(allocator, cfg, user_id);

    return .{
        .source = .local_fallback,
        .state_backend_configured = try allocator.dupe(u8, configured),
        .state_backend_effective = try allocator.dupe(u8, effective),
        .scheduler_backend = try allocator.dupe(u8, scheduler_backend),
        .degraded = degraded_reason.len > 0,
        .degraded_reason = try allocator.dupe(u8, degraded_reason),
        .heartbeat_enabled = heartbeat_cfg.enabled,
        .heartbeat_interval_minutes = heartbeat_cfg.interval_minutes,
        .tenant_enabled = cfg.tenant.enabled,
        .scheduler_max_tasks_configured = cfg.scheduler.max_tasks,
        .scheduler_max_concurrent_configured = cfg.scheduler.max_concurrent,
        .scheduler_max_tasks_effective = if (std.mem.eql(u8, scheduler_backend, "unknown")) null else cfg.scheduler.max_tasks,
        .chat_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.default_provider)),
        .chat_fallback_chain = try allocNormalizedFallbackChain(allocator, cfg.reliability.fallback_providers),
        .embedding_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.memory.search.provider)),
        .provider_data_source = try allocator.dupe(u8, "config"),
        .telegram_configured = channel_catalog.configuredCount(cfg, .telegram) > 0,
        .telegram_connected = null,
        .telegram_account_id = null,
        .telegram_chat_id = null,
        .telegram_data_source = try allocator.dupe(u8, "local_fallback"),
        .context_incomplete = context_incomplete,
        .stt_transcriber_configured = null,
        .stt_transcription_attempted = null,
        .stt_transcription_succeeded = null,
        .stt_transcription_failed = null,
        .stt_transcription_skipped_no_transcriber = null,
    };
}

const LocalHeartbeatConfig = struct {
    enabled: bool,
    interval_minutes: u32,
};

fn parseHeartbeatSecondsToMinutes(value: i64) ?u32 {
    if (value <= 0) return null;
    const mins_i64 = @max(@as(i64, 1), @divFloor(value + 59, 60));
    const clamped = @min(mins_i64, @as(i64, std.math.maxInt(u32)));
    return @intCast(clamped);
}

fn applyHeartbeatConfigObject(enabled: *bool, interval_minutes: *u32, object: std.json.ObjectMap) void {
    if (object.get("enabled")) |value| {
        if (value == .bool) enabled.* = value.bool;
    }
    if (object.get("interval_minutes")) |value| {
        if (value == .integer and value.integer > 0) {
            const clamped = @min(value.integer, @as(i64, std.math.maxInt(u32)));
            interval_minutes.* = @intCast(clamped);
        }
    }
    // v1.14.23 WARN 3.C: canonical key is `interval_secs`; legacy aliases
    // kept for back-compat. Mirrors tools/runtime_info.zig.
    inline for ([_][]const u8{ "interval_secs", "intervalSec", "interval_seconds", "interval_sec" }) |field| {
        if (object.get(field)) |value| {
            if (value == .integer) {
                if (parseHeartbeatSecondsToMinutes(value.integer)) |mins| interval_minutes.* = mins;
            }
        }
    }
}

fn readEffectiveLocalHeartbeatConfig(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    user_id: ?[]const u8,
) !LocalHeartbeatConfig {
    var result = LocalHeartbeatConfig{
        .enabled = cfg.heartbeat.enabled,
        .interval_minutes = @max(@as(u32, 1), cfg.heartbeat.interval_minutes),
    };
    const scoped_user_id = user_id orelse return result;
    if (cfg.tenant.data_root.len == 0) return result;

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}/heartbeat.json", .{ cfg.tenant.data_root, scoped_user_id });
    defer allocator.free(path);
    const file = std.fs.openFileAbsolute(path, .{}) catch return result;
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(raw);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{}) catch return result;
    defer parsed.deinit();
    if (parsed.value != .object) return result;
    applyHeartbeatConfigObject(&result.enabled, &result.interval_minutes, parsed.value.object);
    if (parsed.value.object.get("heartbeat")) |nested| {
        if (nested == .object) applyHeartbeatConfigObject(&result.enabled, &result.interval_minutes, nested.object);
    }
    return result;
}

fn normalizeProviderAlias(provider_name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, provider_name, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "together-ai")) return "together";
    if (std.mem.eql(u8, trimmed, "google-gemini")) return "gemini";
    return trimmed;
}

fn normalizeFallbackChain(chain: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, chain, " \t\r\n");
    if (trimmed.len == 0) return "none";
    if (std.mem.eql(u8, trimmed, "together-ai")) return "together";
    return trimmed;
}

fn allocNormalizedFallbackChain(allocator: std.mem.Allocator, providers: []const []const u8) ![]u8 {
    if (providers.len == 0) return allocator.dupe(u8, "none");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var wrote_any = false;
    for (providers) |provider_name| {
        const normalized = normalizeProviderAlias(provider_name);
        if (normalized.len == 0) continue;
        if (wrote_any) try out.append(allocator, ',');
        try out.appendSlice(allocator, normalized);
        wrote_any = true;
    }
    if (!wrote_any) return allocator.dupe(u8, "none");
    return out.toOwnedSlice(allocator);
}

fn readObjectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn readObjectBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    if (v != .bool) return null;
    return v.bool;
}

fn readObjectU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => std.math.cast(u32, v.integer),
        .string => std.fmt.parseInt(u32, v.string, 10) catch null,
        else => null,
    };
}

fn readObjectU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => std.math.cast(u64, v.integer),
        .string => std.fmt.parseInt(u64, v.string, 10) catch null,
        else => null,
    };
}

fn readObjectI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .string => std.fmt.parseInt(i64, v.string, 10) catch null,
        else => null,
    };
}

test "parseGatewayDiagnosticsPayload reads startup self check" {
    const payload =
        \\{
        \\  "startup_self_check": {
        \\    "state_backend_configured": "postgres",
        \\    "state_backend_effective": "postgres",
        \\    "scheduler_backend": "postgres",
        \\    "degraded": false,
        \\    "degraded_reason": "",
        \\    "heartbeat_enabled": true,
        \\    "heartbeat_interval_minutes": 30,
        \\    "tenant_enabled": true
        \\  },
        \\  "integrations": {
        \\    "telegram": {
        \\      "configured": true,
        \\      "connected": true,
        \\      "account_id": "main",
        \\      "chat_id": 1110331014,
        \\      "data_source": "postgres"
        \\    }
        \\  },
        \\  "identity_mapping": {
        \\    "mapped": 11,
        \\    "unmapped": 2,
        \\    "strict_rejected": 1,
        \\    "degraded_compat": 3,
        \\    "cache_hit": 8,
        \\    "cache_miss": 5,
        \\    "cache_stale": 1,
        \\    "db_lookup_count": 5,
        \\    "db_lookup_ms_total": 41
        \\  },
        \\  "tenant_lock_conflicts_by_route": {
        \\    "chat_stream_sse": 4,
        \\    "chat_stream_http": 3,
        \\    "webhook": 2,
        \\    "daemon": 1,
        \\    "api": 5
        \\  },
        \\  "stt": {
        \\    "transcriber_configured": 2,
        \\    "transcription_attempted": 9,
        \\    "transcription_succeeded": 7,
        \\    "transcription_failed": 2,
        \\    "transcription_skipped_no_transcriber": 3
        \\  },
        \\  "multimodal": {
        \\    "image_markers_detected": 6,
        \\    "messages_with_image_markers": 4,
        \\    "image_parts_prepared": 5,
        \\    "image_parts_failed": 1,
        \\    "image_markers_ignored": 2
        \\  },
        \\  "ops_guard": {
        \\    "last_event": {
        \\      "action": "blocked_rate",
        \\      "reason": "rate_limit"
        \\    },
        \\    "proactive_policy": {
        \\      "dedupe_window_secs": 120,
        \\      "rate_window_secs": 300,
        \\      "rate_limit_per_window": 12
        \\    }
        \\  },
        \\  "heartbeat_runtime": {
        \\    "available": true,
        \\    "last_run_s": 1760001111,
        \\    "last_status": "sent",
        \\    "last_reason": "sent"
        \\  },
        \\  "tenant_lease_probe": {
        \\    "user_id": "7",
        \\    "data_source": "postgres_lease",
        \\    "owner_id": "node-a",
        \\    "lease_until_s": 1800000000,
        \\    "updated_at_s": 1799999990
        \\  }
        \\}
    ;
    var snapshot = try parseGatewayDiagnosticsPayload(std.testing.allocator, payload);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.gateway_internal, snapshot.source);
    try std.testing.expectEqualStrings("postgres", snapshot.state_backend_effective);
    try std.testing.expectEqualStrings("postgres", snapshot.scheduler_backend);
    try std.testing.expect(snapshot.heartbeat_enabled);
    try std.testing.expectEqual(@as(u32, 30), snapshot.heartbeat_interval_minutes);
    try std.testing.expectEqual(@as(?bool, true), snapshot.telegram_configured);
    try std.testing.expectEqual(@as(?bool, true), snapshot.telegram_connected);
    try std.testing.expectEqualStrings("main", snapshot.telegram_account_id.?);
    try std.testing.expectEqual(@as(?i64, 1110331014), snapshot.telegram_chat_id);
    try std.testing.expectEqualStrings("postgres", snapshot.telegram_data_source.?);
    try std.testing.expectEqualStrings("unknown", snapshot.chat_provider_effective);
    try std.testing.expectEqualStrings("none", snapshot.chat_fallback_chain);
    try std.testing.expectEqualStrings("none", snapshot.embedding_provider_effective);
    try std.testing.expectEqualStrings("gateway_internal", snapshot.provider_data_source);
    try std.testing.expectEqual(@as(?u64, 11), snapshot.identity_mapped);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.identity_unmapped);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.identity_strict_rejected);
    try std.testing.expectEqual(@as(?u64, 3), snapshot.identity_degraded_compat);
    try std.testing.expectEqual(@as(?u64, 8), snapshot.identity_cache_hit);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.identity_cache_miss);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.identity_cache_stale);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.identity_db_lookup_count);
    try std.testing.expectEqual(@as(?u64, 41), snapshot.identity_db_lookup_ms_total);
    try std.testing.expectEqual(@as(?u64, 4), snapshot.tenant_lock_conflicts_chat_stream_sse);
    try std.testing.expectEqual(@as(?u64, 3), snapshot.tenant_lock_conflicts_chat_stream_http);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.tenant_lock_conflicts_webhook);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.tenant_lock_conflicts_daemon);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.tenant_lock_conflicts_api);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.stt_transcriber_configured);
    try std.testing.expectEqual(@as(?u64, 9), snapshot.stt_transcription_attempted);
    try std.testing.expectEqual(@as(?u64, 7), snapshot.stt_transcription_succeeded);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.stt_transcription_failed);
    try std.testing.expectEqual(@as(?u64, 3), snapshot.stt_transcription_skipped_no_transcriber);
    try std.testing.expectEqual(@as(?u64, 6), snapshot.multimodal_image_markers_detected);
    try std.testing.expectEqual(@as(?u64, 4), snapshot.multimodal_messages_with_image_markers);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.multimodal_image_parts_prepared);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.multimodal_image_parts_failed);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.multimodal_image_markers_ignored);
    try std.testing.expectEqualStrings("blocked_rate", snapshot.proactive_last_status.?);
    try std.testing.expectEqualStrings("rate_limit", snapshot.proactive_last_reason.?);
    try std.testing.expectEqual(@as(?u64, 120), snapshot.proactive_policy_dedupe_window_secs);
    try std.testing.expectEqual(@as(?u64, 300), snapshot.proactive_policy_rate_window_secs);
    try std.testing.expectEqual(@as(?u64, 12), snapshot.proactive_policy_rate_limit_per_window);
    try std.testing.expectEqual(@as(?bool, true), snapshot.heartbeat_runtime_available);
    try std.testing.expectEqual(@as(?i64, 1760001111), snapshot.heartbeat_runtime_last_run_s);
    try std.testing.expectEqualStrings("sent", snapshot.heartbeat_runtime_last_status.?);
    try std.testing.expectEqualStrings("sent", snapshot.heartbeat_runtime_last_reason.?);
    try std.testing.expectEqualStrings("7", snapshot.tenant_lease_probe_user_id.?);
    try std.testing.expectEqualStrings("postgres_lease", snapshot.tenant_lease_probe_data_source.?);
    try std.testing.expectEqualStrings("node-a", snapshot.tenant_lease_probe_owner_id.?);
    try std.testing.expectEqual(@as(?i64, 1800000000), snapshot.tenant_lease_probe_lease_until_s);
    try std.testing.expectEqual(@as(?i64, 1799999990), snapshot.tenant_lease_probe_updated_at_s);
}

test "collectLocalFallbackSnapshot marks unknown effective backend when runtime probe is unavailable" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";
    cfg.scheduler.max_tasks = 64;
    cfg.scheduler.max_concurrent = 4;

    var snapshot = try collectLocalFallbackSnapshot(std.testing.allocator, &cfg, null);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.local_fallback, snapshot.source);
    try std.testing.expectEqualStrings("postgres", snapshot.state_backend_configured);
    if (build_options.enable_postgres) {
        try std.testing.expectEqualStrings("unknown", snapshot.state_backend_effective);
        try std.testing.expect(snapshot.context_incomplete);
    } else {
        try std.testing.expectEqualStrings("file", snapshot.state_backend_effective);
        try std.testing.expect(!snapshot.context_incomplete);
    }
    try std.testing.expectEqualStrings("openrouter", snapshot.chat_provider_effective);
    try std.testing.expectEqualStrings("none", snapshot.chat_fallback_chain);
    try std.testing.expectEqualStrings("none", snapshot.embedding_provider_effective);
    try std.testing.expectEqualStrings("config", snapshot.provider_data_source);
}

test "deriveExecutionTruth surfaces degraded local fallback compactly" {
    var snapshot = RuntimeSnapshot{
        .source = .local_fallback,
        .state_backend_configured = try std.testing.allocator.dupe(u8, "postgres"),
        .state_backend_effective = try std.testing.allocator.dupe(u8, "file"),
        .scheduler_backend = try std.testing.allocator.dupe(u8, "file"),
        .degraded = true,
        .degraded_reason = try std.testing.allocator.dupe(u8, "PostgresNotEnabled"),
        .heartbeat_enabled = false,
        .heartbeat_interval_minutes = 30,
        .tenant_enabled = true,
        .scheduler_max_tasks_configured = 64,
        .scheduler_max_concurrent_configured = 4,
        .chat_provider_effective = try std.testing.allocator.dupe(u8, "openrouter"),
        .chat_fallback_chain = try std.testing.allocator.dupe(u8, "anthropic"),
        .embedding_provider_effective = try std.testing.allocator.dupe(u8, "none"),
        .provider_data_source = try std.testing.allocator.dupe(u8, "config"),
        .tenant_lease_probe_owner_id = try std.testing.allocator.dupe(u8, "node-a"),
        .tenant_lease_probe_data_source = try std.testing.allocator.dupe(u8, "postgres_lease"),
        .heartbeat_runtime_last_status = try std.testing.allocator.dupe(u8, "send_failed"),
    };
    defer snapshot.deinit(std.testing.allocator);

    var truth = try deriveExecutionTruth(std.testing.allocator, &snapshot, null, "agent:test:user:1:task:ship", "1");
    defer truth.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("task", truth.task);
    try std.testing.expectEqualStrings("node-a", truth.owner);
    try std.testing.expectEqualStrings("degraded", truth.status);
    try std.testing.expectEqualStrings("send_failed", truth.result);
    try std.testing.expect(truth.degraded);
    try std.testing.expectEqualStrings("PostgresNotEnabled", truth.degraded_reason);
    try std.testing.expect(truth.fallback_active);
    try std.testing.expectEqualStrings("local_fallback", truth.fallback_reason);
    try std.testing.expectEqualStrings("anthropic", truth.fallback_chain);
}

test "deriveExecutionTruth keeps config-backed provider truth non-fallback and owner explicit" {
    var snapshot = RuntimeSnapshot{
        .source = .gateway_internal,
        .state_backend_configured = try std.testing.allocator.dupe(u8, "postgres"),
        .state_backend_effective = try std.testing.allocator.dupe(u8, "postgres"),
        .scheduler_backend = try std.testing.allocator.dupe(u8, "postgres"),
        .degraded = false,
        .degraded_reason = try std.testing.allocator.dupe(u8, ""),
        .heartbeat_enabled = true,
        .heartbeat_interval_minutes = 30,
        .tenant_enabled = true,
        .scheduler_max_tasks_configured = 64,
        .scheduler_max_concurrent_configured = 4,
        .chat_provider_effective = try std.testing.allocator.dupe(u8, "openrouter"),
        .chat_fallback_chain = try std.testing.allocator.dupe(u8, "anthropic"),
        .embedding_provider_effective = try std.testing.allocator.dupe(u8, "openai"),
        .provider_data_source = try std.testing.allocator.dupe(u8, "config"),
    };
    defer snapshot.deinit(std.testing.allocator);

    var truth = try deriveExecutionTruth(std.testing.allocator, &snapshot, null, "agent:test:user:7:main", "7");
    defer truth.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("active", truth.status);
    try std.testing.expectEqualStrings("in_progress", truth.result);
    try std.testing.expectEqualStrings("7", truth.owner);
    try std.testing.expectEqualStrings("scoped_user_id", truth.owner_source);
    try std.testing.expect(!truth.degraded);
    try std.testing.expect(!truth.fallback_active);
    try std.testing.expectEqualStrings("", truth.fallback_reason);
}

test "deriveExecutionTruth treats failed task as attention without degrading runtime" {
    var snapshot = RuntimeSnapshot{
        .source = .gateway_internal,
        .state_backend_configured = try std.testing.allocator.dupe(u8, "postgres"),
        .state_backend_effective = try std.testing.allocator.dupe(u8, "postgres"),
        .scheduler_backend = try std.testing.allocator.dupe(u8, "postgres"),
        .degraded = false,
        .degraded_reason = try std.testing.allocator.dupe(u8, ""),
        .heartbeat_enabled = true,
        .heartbeat_interval_minutes = 30,
        .tenant_enabled = true,
        .scheduler_max_tasks_configured = 64,
        .scheduler_max_concurrent_configured = 4,
        .chat_provider_effective = try std.testing.allocator.dupe(u8, "openrouter"),
        .chat_fallback_chain = try std.testing.allocator.dupe(u8, "anthropic"),
        .embedding_provider_effective = try std.testing.allocator.dupe(u8, "openai"),
        .provider_data_source = try std.testing.allocator.dupe(u8, "config"),
    };
    defer snapshot.deinit(std.testing.allocator);

    var task_snapshot = zaki_state.TaskSnapshot{
        .id = try std.testing.allocator.dupe(u8, "7"),
        .session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:task:7"),
        .request_session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .label = try std.testing.allocator.dupe(u8, "recover"),
        .prompt = try std.testing.allocator.dupe(u8, "recover prompt"),
        .status = try std.testing.allocator.dupe(u8, "failed"),
        .result = null,
        .error_msg = try std.testing.allocator.dupe(u8, "process_restarted_before_completion"),
        .created_at_ms = 42,
        .started_at_ms = 42,
        .completed_at_ms = 84,
    };
    defer task_snapshot.deinit(std.testing.allocator);

    var truth = try deriveExecutionTruth(std.testing.allocator, &snapshot, &task_snapshot, task_snapshot.session_id.?, "1");
    defer truth.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("attention", truth.status);
    try std.testing.expectEqualStrings("failed", truth.result);
    try std.testing.expectEqualStrings("process_restarted_before_completion", truth.failure);
    try std.testing.expect(!truth.degraded);
    try std.testing.expectEqualStrings("", truth.degraded_reason);
}

test "collectTaskSnapshotFromFile derives runtime lane for legacy requester-only ledger row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/subagent_tasks.jsonl", .{tmp_root});
    defer std.testing.allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(
        "{\"id\":7,\"status\":\"failed\",\"label\":\"recover\",\"task_summary\":\"recover\",\"task_prompt\":\"recover prompt\",\"session_key\":\"agent:zaki-bot:user:1:main\",\"origin_channel\":\"agent\",\"origin_chat_id\":\"session:recover\",\"result\":null,\"error\":\"process_restarted_before_completion\",\"started_at\":42,\"completed_at\":84}\n",
    );

    var snapshot = (try collectTaskSnapshotFromFile(std.testing.allocator, path, "7")) orelse return error.TestUnexpectedResult;
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", snapshot.request_session_id.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:task:7", snapshot.session_id.?);
}

test "collectExecutionTaskFocus from main prefers newest active task for that lane" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const state_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace, "state" });
    defer std.testing.allocator.free(state_dir);
    try std.fs.makeDirAbsolute(state_dir);
    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ state_dir, "subagent_tasks.jsonl" });
    defer std.testing.allocator.free(ledger_path);

    const file = try std.fs.createFileAbsolute(ledger_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(
        "{\"id\":4,\"status\":\"failed\",\"label\":\"older-failure\",\"task_summary\":\"older-failure\",\"task_prompt\":\"older-failure prompt\",\"request_session_key\":\"agent:zaki-bot:user:1:main\",\"runtime_session_key\":\"agent:zaki-bot:user:1:task:4\",\"error\":\"process_restarted_before_completion\",\"started_at\":42,\"completed_at\":84}\n" ++
            "{\"id\":5,\"status\":\"running\",\"label\":\"current-run\",\"task_summary\":\"current-run\",\"task_prompt\":\"current-run prompt\",\"request_session_key\":\"agent:zaki-bot:user:1:main\",\"runtime_session_key\":\"agent:zaki-bot:user:1:task:5\",\"started_at\":100}\n" ++
            "{\"id\":6,\"status\":\"running\",\"label\":\"other-session\",\"task_summary\":\"other-session\",\"task_prompt\":\"other prompt\",\"request_session_key\":\"agent:zaki-bot:user:2:main\",\"runtime_session_key\":\"agent:zaki-bot:user:2:task:6\",\"started_at\":200}\n",
    );

    var cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };

    var focus = try collectExecutionTaskFocus(
        std.testing.allocator,
        &cfg,
        null,
        null,
        "1",
        "agent:zaki-bot:user:1:main",
    );
    defer focus.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("main_active_task", focus.selection_rule);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:task:5", focus.task_session_key.?);
    try std.testing.expectEqualStrings("5", focus.task_snapshot.?.id);
    try std.testing.expectEqualStrings("running", focus.task_snapshot.?.status);
}
