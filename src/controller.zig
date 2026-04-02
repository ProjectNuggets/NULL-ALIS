const std = @import("std");
const builtin = @import("builtin");
const health = @import("health.zig");
const cell_spec = @import("cell_spec.zig");
const cell_k8s_api = @import("cell_k8s_api.zig");
const MAX_HTTP_REQUEST_SIZE: usize = 8 * 1024;
const REQUEST_TIMEOUT_SECS: i64 = 5;

const ControllerCellControlRoute = enum {
    resolve,
    ensure,
    status,
    drain,
};

const ControllerCellState = enum {
    pending,
    warm,
    draining,
};

const CellRecord = struct {
    user_id: []u8,
    cell_url: ?[]u8 = null,
    state: ControllerCellState,
    created_at_s: i64,
    updated_at_s: i64,
    last_ensured_at_s: i64,
    drain_requested_at_s: ?i64 = null,
    ensure_count: u32 = 1,
};

const CellSnapshot = struct {
    user_id: []u8,
    cell_url: ?[]u8 = null,
    state: ControllerCellState,
    created_at_s: i64,
    updated_at_s: i64,
    last_ensured_at_s: i64,
    drain_requested_at_s: ?i64 = null,
    ensure_count: u32 = 1,

    fn deinit(self: *CellSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        if (self.cell_url) |cell_url| allocator.free(cell_url);
        self.* = undefined;
    }
};

const CellEnsureResult = struct {
    snapshot: CellSnapshot,
    created: bool,

    fn deinit(self: *CellEnsureResult, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
    }
};

const CellResolveResult = struct {
    found: bool,
    snapshot: ?CellSnapshot = null,

    fn deinit(self: *CellResolveResult, allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(allocator);
    }
};

const CellStatusSummary = struct {
    cells: []CellSnapshot,
    storage: []CellSnapshot,
    pending_count: usize,
    warm_count: usize,
    draining_count: usize,

    fn deinit(self: *CellStatusSummary, allocator: std.mem.Allocator) void {
        for (self.cells) |*cell| cell.deinit(allocator);
        allocator.free(self.storage);
    }
};

const CellRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cells: std.StringHashMapUnmanaged(CellRecord) = .empty,

    fn init(allocator: std.mem.Allocator) CellRegistry {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CellRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.cells.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.cell_url) |cell_url| self.allocator.free(cell_url);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cells.deinit(self.allocator);
    }

    fn snapshotForRecord(allocator: std.mem.Allocator, record: *const CellRecord) !CellSnapshot {
        return .{
            .user_id = try allocator.dupe(u8, record.user_id),
            .cell_url = if (record.cell_url) |cell_url| try allocator.dupe(u8, cell_url) else null,
            .state = record.state,
            .created_at_s = record.created_at_s,
            .updated_at_s = record.updated_at_s,
            .last_ensured_at_s = record.last_ensured_at_s,
            .drain_requested_at_s = record.drain_requested_at_s,
            .ensure_count = record.ensure_count,
        };
    }

    fn resolve(self: *CellRegistry, allocator: std.mem.Allocator, user_id: []const u8) !CellResolveResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const record = self.cells.getPtr(user_id) orelse return .{ .found = false };
        return .{
            .found = true,
            .snapshot = try snapshotForRecord(allocator, record),
        };
    }

    fn ensure(
        self: *CellRegistry,
        allocator: std.mem.Allocator,
        user_id: []const u8,
        cell_url: ?[]const u8,
    ) !CellEnsureResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_s = std.time.timestamp();
        if (self.cells.getPtr(user_id)) |record| {
            if (cell_url) |value| {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, record.cell_url orelse "")) {
                    const owned_cell_url = try self.allocator.dupe(u8, trimmed);
                    errdefer self.allocator.free(owned_cell_url);
                    if (record.cell_url) |previous| self.allocator.free(previous);
                    record.cell_url = owned_cell_url;
                }
                record.state = if (record.state == .warm) .warm else .pending;
                record.drain_requested_at_s = null;
            }
            record.updated_at_s = now_s;
            record.last_ensured_at_s = now_s;
            record.ensure_count +%= 1;
            return .{
                .snapshot = try snapshotForRecord(allocator, record),
                .created = false,
            };
        }

        const owned_user_id = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(owned_user_id);

        const owned_cell_url = if (cell_url) |value|
            try self.allocator.dupe(u8, std.mem.trim(u8, value, " \t\r\n"))
        else
            null;
        errdefer if (owned_cell_url) |value| self.allocator.free(value);

        const record = CellRecord{
            .user_id = owned_user_id,
            .cell_url = owned_cell_url,
            .state = .pending,
            .created_at_s = now_s,
            .updated_at_s = now_s,
            .last_ensured_at_s = now_s,
            .drain_requested_at_s = null,
            .ensure_count = 1,
        };
        try self.cells.put(self.allocator, owned_user_id, record);
        return .{
            .snapshot = try snapshotForRecord(allocator, &record),
            .created = true,
        };
    }

    fn drain(self: *CellRegistry, allocator: std.mem.Allocator, user_id: []const u8) !CellResolveResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const record = self.cells.getPtr(user_id) orelse return .{ .found = false };
        const now_s = std.time.timestamp();
        record.state = .draining;
        record.updated_at_s = now_s;
        if (record.drain_requested_at_s == null) record.drain_requested_at_s = now_s;
        return .{
            .found = true,
            .snapshot = try snapshotForRecord(allocator, record),
        };
    }

    fn remove(self: *CellRegistry, user_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cells.fetchRemove(user_id)) |removed| {
            if (removed.value.cell_url) |cell_url| self.allocator.free(cell_url);
            self.allocator.free(@constCast(removed.key));
        }
    }

    fn statusAll(self: *CellRegistry, allocator: std.mem.Allocator) !CellStatusSummary {
        self.mutex.lock();
        defer self.mutex.unlock();

        var snapshots = try allocator.alloc(CellSnapshot, self.cells.count());
        var built_count: usize = 0;
        errdefer {
            var idx: usize = 0;
            while (idx < built_count) : (idx += 1) {
                snapshots[idx].deinit(allocator);
            }
            allocator.free(snapshots);
        }

        var pending_count: usize = 0;
        var warm_count: usize = 0;
        var draining_count: usize = 0;
        var idx: usize = 0;
        var iter = self.cells.iterator();
        while (iter.next()) |entry| {
            snapshots[idx] = try snapshotForRecord(allocator, entry.value_ptr);
            built_count = idx + 1;
            switch (entry.value_ptr.state) {
                .pending => pending_count += 1,
                .warm => warm_count += 1,
                .draining => draining_count += 1,
            }
            idx += 1;
        }

        return .{
            .cells = snapshots,
            .storage = snapshots,
            .pending_count = pending_count,
            .warm_count = warm_count,
            .draining_count = draining_count,
        };
    }
};

const ControllerState = struct {
    internal_service_tokens: []const []const u8 = &.{},
    internal_auth_required: bool = false,
    registry: ?*CellRegistry = null,
    cell_template: cell_spec.CellTemplate = .{},
    k8s_client: ?*const cell_k8s_api.Client = null,
};

const Response = struct {
    status: []const u8,
    body: []const u8,
    allocated: bool = false,
};

const ObservationReconciliation = enum {
    unchanged,
    updated,
    finalized,
};

const UserIdSelection = struct {
    user_id: []const u8,
    owned_user_id: ?[]u8 = null,

    fn deinit(self: *UserIdSelection, allocator: std.mem.Allocator) void {
        if (self.owned_user_id) |owned| allocator.free(owned);
    }
};

fn is_health_ok() bool {
    const snap = health.snapshot();
    var iter = snap.components.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.status, "ok")) return false;
    }
    return true;
}

fn handle_ready(allocator: std.mem.Allocator) Response {
    const readiness = health.checkRegistryReadiness(allocator) catch {
        return .{
            .status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
        };
    };
    const json_body = readiness.formatJson(allocator) catch {
        if (readiness.checks.len > 0) allocator.free(readiness.checks);
        return .{
            .status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
        };
    };
    if (readiness.checks.len > 0) allocator.free(readiness.checks);
    return .{
        .status = if (readiness.status == .ready) "200 OK" else "503 Service Unavailable",
        .body = json_body,
        .allocated = true,
    };
}

fn extract_header(raw: []const u8, name: []const u8) ?[]const u8 {
    const sep = "\r\n";
    var search_start: usize = 0;
    while (true) {
        const line_end_rel = std.mem.indexOfPos(u8, raw, search_start, sep) orelse return null;
        const line = raw[search_start..line_end_rel];
        if (line.len == 0) return null;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const header_name = std.mem.trimRight(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(header_name, name)) {
                return std.mem.trimLeft(u8, line[colon + 1 ..], " \t");
            }
        }
        search_start = line_end_rel + sep.len;
    }
}

fn extract_bearer_token(header_value: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (header_value.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(header_value[0..prefix.len], prefix)) return null;
    return std.mem.trim(u8, header_value[prefix.len..], " \t\r\n");
}

fn extract_internal_service_token(raw: []const u8) ?[]const u8 {
    if (extract_header(raw, "X-Internal-Token")) |hdr| {
        const token = std.mem.trim(u8, hdr, " \t\r\n");
        if (token.len > 0) return token;
    }
    if (extract_header(raw, "Authorization")) |hdr| {
        if (extract_bearer_token(std.mem.trim(u8, hdr, " \t\r\n"))) |token| {
            if (token.len > 0) return token;
        }
    }
    return null;
}

fn has_configured_internal_service_tokens(internal_service_tokens: []const []const u8) bool {
    for (internal_service_tokens) |expected| {
        if (std.mem.trim(u8, expected, " \t\r\n").len > 0) return true;
    }
    return false;
}

fn validate_internal_service_token(raw: []const u8, state: ControllerState) bool {
    const provided = extract_internal_service_token(raw);
    if (!has_configured_internal_service_tokens(state.internal_service_tokens)) {
        return !state.internal_auth_required;
    }
    const token = provided orelse return false;
    for (state.internal_service_tokens) |expected| {
        const trimmed = std.mem.trim(u8, expected, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, token)) return true;
    }
    return false;
}

fn controller_cell_control_route_name(route: ControllerCellControlRoute) []const u8 {
    return switch (route) {
        .resolve => "resolve",
        .ensure => "ensure",
        .status => "status",
        .drain => "drain",
    };
}

fn cell_state_name(state: ControllerCellState) []const u8 {
    return switch (state) {
        .pending => "pending",
        .warm => "warm",
        .draining => "draining",
    };
}

fn is_valid_identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        if (!(is_alnum or c == '-' or c == '_' or c == '.' or c == '@')) return false;
    }
    return true;
}

fn is_valid_cell_url(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 2048) return false;
    return std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://");
}

fn extract_body(raw: []const u8) ?[]const u8 {
    const header_end = header_end_offset(raw) orelse return null;
    if (header_end > raw.len) return null;
    return raw[header_end..];
}

fn extract_user_id(allocator: std.mem.Allocator, raw: []const u8) !?UserIdSelection {
    if (extract_header(raw, "X-Zaki-User-Id")) |hdr| {
        const user_id = std.mem.trim(u8, hdr, " \t\r\n");
        if (is_valid_identifier(user_id)) return .{ .user_id = user_id };
        return error.InvalidUserId;
    }

    const body = extract_body(raw) orelse return null;
    const trimmed_body = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed_body.len == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed_body, .{}) catch return error.InvalidPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const user_id_value = parsed.value.object.get("user_id") orelse return null;
    switch (user_id_value) {
        .string => |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (!is_valid_identifier(trimmed)) return error.InvalidUserId;
            const owned = try allocator.dupe(u8, trimmed);
            errdefer allocator.free(owned);
            return .{
                .user_id = owned,
                .owned_user_id = owned,
            };
        },
        .integer => |value| {
            const owned = try std.fmt.allocPrint(allocator, "{d}", .{value});
            errdefer allocator.free(owned);
            if (!is_valid_identifier(owned)) return error.InvalidUserId;
            return .{
                .user_id = owned,
                .owned_user_id = owned,
            };
        },
        else => return error.InvalidPayload,
    }
}

fn extract_cell_url(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const body = extract_body(raw) orelse return null;
    const trimmed_body = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed_body.len == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed_body, .{}) catch return error.InvalidPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const cell_url_value = parsed.value.object.get("cell_url") orelse return null;
    switch (cell_url_value) {
        .string => |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (!is_valid_cell_url(trimmed)) return error.InvalidCellUrl;
            return try allocator.dupe(u8, trimmed);
        },
        else => return error.InvalidPayload,
    }
}

fn append_cell_snapshot_json(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    snapshot: CellSnapshot,
    template: cell_spec.CellTemplate,
) !void {
    const writer = buf.writer(allocator);
    var desired = try cell_spec.desiredSpec(allocator, template, snapshot.user_id);
    defer desired.deinit(allocator);
    try writer.print(
        "{{\"user_id\":{f},\"cell_url\":",
        .{
            std.json.fmt(snapshot.user_id, .{}),
        },
    );
    if (snapshot.cell_url) |cell_url| {
        try writer.print("{f}", .{std.json.fmt(cell_url, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"state\":{f},\"created_at_s\":{d},\"updated_at_s\":{d},\"last_ensured_at_s\":{d},\"drain_requested_at_s\":",
        .{
            std.json.fmt(cell_state_name(snapshot.state), .{}),
            snapshot.created_at_s,
            snapshot.updated_at_s,
            snapshot.last_ensured_at_s,
        },
    );
    if (snapshot.drain_requested_at_s) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"ensure_count\":{d},\"desired\":{{\"namespace\":{f},\"pod_name\":{f},\"service_name\":{f},\"cell_url\":{f},\"service_port\":{d}}}}}",
        .{
            snapshot.ensure_count,
            std.json.fmt(desired.namespace, .{}),
            std.json.fmt(desired.pod_name, .{}),
            std.json.fmt(desired.service_name, .{}),
            std.json.fmt(desired.advertise_url, .{}),
            desired.service_port,
        },
    );
}

fn build_user_cell_response(
    allocator: std.mem.Allocator,
    operation: []const u8,
    user_id: []const u8,
    found: bool,
    created: ?bool,
    snapshot: ?CellSnapshot,
    template: cell_spec.CellTemplate,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.print(
        "{{\"status\":\"ok\",\"operation\":{f},\"user_id\":{f},\"found\":{s}",
        .{
            std.json.fmt(operation, .{}),
            std.json.fmt(user_id, .{}),
            if (found) "true" else "false",
        },
    );
    if (created) |was_created| {
        try writer.print(",\"created\":{s}", .{if (was_created) "true" else "false"});
    }
    if (snapshot) |cell| {
        try writer.writeAll(",\"cell\":");
        try append_cell_snapshot_json(&out, allocator, cell, template);
    }
    try writer.writeAll("}");
    return out.toOwnedSlice(allocator);
}

fn build_status_all_response(
    allocator: std.mem.Allocator,
    summary: CellStatusSummary,
    template: cell_spec.CellTemplate,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.print(
        "{{\"status\":\"ok\",\"operation\":\"status\",\"scope\":\"all\",\"count\":{d},\"pending_count\":{d},\"warm_count\":{d},\"draining_count\":{d},\"cells\":[",
        .{ summary.cells.len, summary.pending_count, summary.warm_count, summary.draining_count },
    );
    for (summary.cells, 0..) |cell, idx| {
        if (idx != 0) try writer.writeByte(',');
        try append_cell_snapshot_json(&out, allocator, cell, template);
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice(allocator);
}

fn observed_controller_cell_state(
    current_state: ControllerCellState,
    observation: cell_k8s_api.CellObservation,
) ControllerCellState {
    if (current_state == .draining) return .draining;
    return if (observation.isWarm()) .warm else .pending;
}

fn should_finalize_observed_cell(
    current_state: ControllerCellState,
    observation: cell_k8s_api.CellObservation,
) bool {
    return current_state == .draining and !observation.service_exists and !observation.pod_exists;
}

fn set_snapshot_cell_url(
    allocator: std.mem.Allocator,
    snapshot: *CellSnapshot,
    cell_url: ?[]const u8,
) !void {
    if (snapshot.cell_url) |existing| {
        allocator.free(existing);
        snapshot.cell_url = null;
    }
    if (cell_url) |value| {
        snapshot.cell_url = try allocator.dupe(u8, value);
    }
}

fn reconcile_observed_cell(
    registry: *CellRegistry,
    user_id: []const u8,
    state: ControllerCellState,
    cell_url: ?[]const u8,
) !void {
    registry.mutex.lock();
    defer registry.mutex.unlock();

    const record = registry.cells.getPtr(user_id) orelse return;
    const now_s = std.time.timestamp();
    record.state = state;
    if (record.cell_url) |existing| {
        registry.allocator.free(existing);
        record.cell_url = null;
    }
    if (cell_url) |value| {
        record.cell_url = try registry.allocator.dupe(u8, value);
    }
    record.updated_at_s = now_s;
}

fn recompute_status_summary_counts(summary: *CellStatusSummary) void {
    summary.pending_count = 0;
    summary.warm_count = 0;
    summary.draining_count = 0;
    for (summary.cells) |cell| {
        switch (cell.state) {
            .pending => summary.pending_count += 1,
            .warm => summary.warm_count += 1,
            .draining => summary.draining_count += 1,
        }
    }
}

fn apply_observation_to_snapshot(
    allocator: std.mem.Allocator,
    registry: *CellRegistry,
    user_id: []const u8,
    snapshot: *CellSnapshot,
    observation: cell_k8s_api.CellObservation,
    advertise_url: ?[]const u8,
) ObservationReconciliation {
    if (should_finalize_observed_cell(snapshot.state, observation)) {
        registry.remove(user_id);
        return .finalized;
    }

    const next_state = observed_controller_cell_state(snapshot.state, observation);
    const next_cell_url: ?[]const u8 = if (next_state == .warm) advertise_url else null;

    snapshot.state = next_state;
    set_snapshot_cell_url(allocator, snapshot, next_cell_url) catch return .unchanged;
    reconcile_observed_cell(registry, user_id, next_state, next_cell_url) catch return .unchanged;
    return .updated;
}

fn apply_kubernetes_observation(
    allocator: std.mem.Allocator,
    state: ControllerState,
    user_id: []const u8,
    snapshot: *CellSnapshot,
) ObservationReconciliation {
    const client = state.k8s_client orelse return .unchanged;
    const registry = state.registry orelse return .unchanged;

    var desired = cell_spec.desiredSpec(allocator, state.cell_template, user_id) catch return .unchanged;
    defer desired.deinit(allocator);

    const observation = client.observeCell(allocator, desired) catch return .unchanged;
    return apply_observation_to_snapshot(
        allocator,
        registry,
        user_id,
        snapshot,
        observation,
        desired.advertise_url,
    );
}

fn first_configured_internal_service_token(tokens: []const []const u8) ?[]const u8 {
    for (tokens) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn handle_controller_cell_control_route(
    allocator: std.mem.Allocator,
    state: ControllerState,
    raw: []const u8,
    method: []const u8,
    route: ControllerCellControlRoute,
) Response {
    const required_method = switch (route) {
        .status => "GET",
        .resolve, .ensure, .drain => "POST",
    };
    if (!std.mem.eql(u8, method, required_method)) {
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }
    if (!validate_internal_service_token(raw, state)) {
        return .{ .status = "401 Unauthorized", .body = "{\"error\":\"unauthorized\"}" };
    }
    const registry = state.registry orelse {
        return .{ .status = "503 Service Unavailable", .body = "{\"error\":\"registry_unavailable\"}" };
    };

    switch (route) {
        .status => {
            const selected_user_id = extract_user_id(allocator, raw) catch |err| switch (err) {
                error.InvalidPayload => return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_payload\"}" },
                error.InvalidUserId => return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_user_id\"}" },
                else => return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"request_parse_failed\"}" },
            };
            if (selected_user_id) |user_id_selection| {
                var mutable_selection = user_id_selection;
                defer mutable_selection.deinit(allocator);
                var result = registry.resolve(allocator, mutable_selection.user_id) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"registry_read_failed\"}" };
                };
                defer result.deinit(allocator);
                if (result.snapshot) |*snapshot| {
                    if (apply_kubernetes_observation(allocator, state, mutable_selection.user_id, snapshot) == .finalized) {
                        snapshot.deinit(allocator);
                        result.snapshot = null;
                        result.found = false;
                    }
                }
                const body = build_user_cell_response(
                    allocator,
                    controller_cell_control_route_name(route),
                    mutable_selection.user_id,
                    result.found,
                    null,
                    result.snapshot,
                    state.cell_template,
                ) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response_build_failed\"}" };
                return .{ .status = "200 OK", .body = body, .allocated = true };
            }

            var summary = registry.statusAll(allocator) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"registry_read_failed\"}" };
            };
            defer summary.deinit(allocator);
            var write_idx: usize = 0;
            for (summary.cells, 0..) |*cell, read_idx| {
                if (apply_kubernetes_observation(allocator, state, cell.user_id, cell) == .finalized) {
                    cell.deinit(allocator);
                    continue;
                }
                if (write_idx != read_idx) summary.cells[write_idx] = cell.*;
                write_idx += 1;
            }
            summary.cells = summary.cells[0..write_idx];
            recompute_status_summary_counts(&summary);
            const body = build_status_all_response(allocator, summary, state.cell_template) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response_build_failed\"}" };
            };
            return .{ .status = "200 OK", .body = body, .allocated = true };
        },
        .resolve, .ensure, .drain => {
            const selected_user_id = extract_user_id(allocator, raw) catch |err| switch (err) {
                error.InvalidPayload => return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_payload\"}" },
                error.InvalidUserId => return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_user_id\"}" },
                else => return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"request_parse_failed\"}" },
            };
            var user_id_selection = selected_user_id orelse return .{ .status = "400 Bad Request", .body = "{\"error\":\"missing_user_id\"}" };
            defer user_id_selection.deinit(allocator);

            switch (route) {
                .resolve => {
                    var result = registry.resolve(allocator, user_id_selection.user_id) catch {
                        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"registry_read_failed\"}" };
                    };
                    defer result.deinit(allocator);
                    if (result.snapshot) |*snapshot| {
                        if (apply_kubernetes_observation(allocator, state, user_id_selection.user_id, snapshot) == .finalized) {
                            snapshot.deinit(allocator);
                            result.snapshot = null;
                            result.found = false;
                        }
                    }
                    const body = build_user_cell_response(
                        allocator,
                        controller_cell_control_route_name(route),
                        user_id_selection.user_id,
                        result.found,
                        null,
                        result.snapshot,
                        state.cell_template,
                    ) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response_build_failed\"}" };
                    return .{ .status = "200 OK", .body = body, .allocated = true };
                },
                .ensure => {
                    const cell_url = extract_cell_url(allocator, raw) catch |err| switch (err) {
                        error.InvalidPayload => return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_payload\"}" },
                        error.InvalidCellUrl => return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_cell_url\"}" },
                        else => return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"request_parse_failed\"}" },
                    };
                    defer if (cell_url) |value| allocator.free(value);
                    if (cell_url == null) {
                        if (state.k8s_client) |client| {
                            var desired = cell_spec.desiredSpec(allocator, state.cell_template, user_id_selection.user_id) catch {
                                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"cell_spec_build_failed\"}" };
                            };
                            defer desired.deinit(allocator);
                            client.ensureCell(
                                allocator,
                                desired,
                                first_configured_internal_service_token(state.internal_service_tokens),
                            ) catch {
                                return .{ .status = "503 Service Unavailable", .body = "{\"error\":\"cell_apply_failed\"}" };
                            };
                        }
                    }
                    var result = registry.ensure(allocator, user_id_selection.user_id, cell_url) catch {
                        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"registry_write_failed\"}" };
                    };
                    defer result.deinit(allocator);
                    const body = build_user_cell_response(
                        allocator,
                        controller_cell_control_route_name(route),
                        user_id_selection.user_id,
                        true,
                        result.created,
                        result.snapshot,
                        state.cell_template,
                    ) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response_build_failed\"}" };
                    return .{ .status = "200 OK", .body = body, .allocated = true };
                },
                .drain => {
                    if (state.k8s_client) |client| {
                        var desired = cell_spec.desiredSpec(allocator, state.cell_template, user_id_selection.user_id) catch {
                            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"cell_spec_build_failed\"}" };
                        };
                        defer desired.deinit(allocator);
                        client.drainCell(allocator, desired) catch {
                            return .{ .status = "503 Service Unavailable", .body = "{\"error\":\"cell_delete_failed\"}" };
                        };
                    }
                    var result = registry.drain(allocator, user_id_selection.user_id) catch {
                        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"registry_write_failed\"}" };
                    };
                    defer result.deinit(allocator);
                    const body = build_user_cell_response(
                        allocator,
                        controller_cell_control_route_name(route),
                        user_id_selection.user_id,
                        result.found,
                        null,
                        result.snapshot,
                        state.cell_template,
                    ) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response_build_failed\"}" };
                    return .{ .status = "200 OK", .body = body, .allocated = true };
                },
                .status => unreachable,
            }
        },
    }
}

fn route_request(allocator: std.mem.Allocator, state: ControllerState, raw: []const u8, method: []const u8, target: []const u8) Response {
    const base_path = if (std.mem.indexOfScalar(u8, target, '?')) |query_index| target[0..query_index] else target;

    if (std.mem.eql(u8, base_path, "/health")) {
        if (!std.mem.eql(u8, method, "GET")) {
            return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
        }
        return .{
            .status = "200 OK",
            .body = if (is_health_ok()) "{\"status\":\"ok\"}" else "{\"status\":\"degraded\"}",
        };
    }
    if (std.mem.eql(u8, base_path, "/ready")) {
        if (!std.mem.eql(u8, method, "GET")) {
            return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
        }
        return handle_ready(allocator);
    }
    if (std.mem.eql(u8, base_path, "/internal/cells/resolve")) {
        return handle_controller_cell_control_route(allocator, state, raw, method, .resolve);
    }
    if (std.mem.eql(u8, base_path, "/internal/cells/ensure")) {
        return handle_controller_cell_control_route(allocator, state, raw, method, .ensure);
    }
    if (std.mem.eql(u8, base_path, "/internal/cells/status")) {
        return handle_controller_cell_control_route(allocator, state, raw, method, .status);
    }
    if (std.mem.eql(u8, base_path, "/internal/cells/drain")) {
        return handle_controller_cell_control_route(allocator, state, raw, method, .drain);
    }

    return .{ .status = "404 Not Found", .body = "{\"error\":\"not found\"}" };
}

fn send_http_response(stream: anytype, status: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, body.len },
    );
    try stream.writeAll(header);
    if (body.len > 0) try stream.writeAll(body);
}

fn configure_request_read_timeout(stream: std.net.Stream) void {
    if (builtin.os.tag == .macos) return;
    if (!@hasDecl(std.posix.SO, "RCVTIMEO")) return;

    const timeout = std.posix.timeval{
        .sec = REQUEST_TIMEOUT_SECS,
        .usec = 0,
    };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        &std.mem.toBytes(timeout),
    ) catch {};
}

fn header_end_offset(raw: []const u8) ?usize {
    const separator = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, raw, separator) orelse return null;
    return pos + separator.len;
}

fn expected_http_request_size(raw: []const u8) !?usize {
    const header_end = header_end_offset(raw) orelse return null;
    const header_slice = raw[0..header_end];
    const content_length_raw = extract_header(header_slice, "Content-Length") orelse return header_end;
    const trimmed = std.mem.trim(u8, content_length_raw, " \t");
    if (trimmed.len == 0) return error.InvalidContentLength;

    const content_length = std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidContentLength;
    const total = std.math.add(usize, header_end, content_length) catch return error.RequestTooLarge;
    if (total > MAX_HTTP_REQUEST_SIZE) return error.RequestTooLarge;
    return total;
}

fn read_simple_http_request(allocator: std.mem.Allocator, stream: anytype) ![]u8 {
    var request_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer request_buf.deinit(allocator);

    var expected_total: ?usize = null;
    var chunk: [2048]u8 = undefined;
    while (true) {
        const read_len = stream.read(&chunk) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionTimedOut => return error.RequestTimeout,
            else => return err,
        };
        if (read_len == 0) return error.IncompleteRequest;
        try request_buf.appendSlice(allocator, chunk[0..read_len]);
        if (request_buf.items.len > MAX_HTTP_REQUEST_SIZE) return error.RequestTooLarge;
        if (expected_total == null) {
            expected_total = try expected_http_request_size(request_buf.items);
        }
        if (expected_total) |total| {
            if (request_buf.items.len >= total) {
                request_buf.items.len = total;
                return request_buf.toOwnedSlice(allocator);
            }
        }
    }
}

fn handle_connection(allocator: std.mem.Allocator, state: ControllerState, conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    configure_request_read_timeout(conn.stream);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    const raw = read_simple_http_request(req_allocator, conn.stream) catch |err| {
        const status = switch (err) {
            error.RequestTooLarge => "413 Payload Too Large",
            error.InvalidContentLength => "400 Bad Request",
            error.RequestTimeout => "408 Request Timeout",
            else => "400 Bad Request",
        };
        send_http_response(conn.stream, status, "{\"error\":\"invalid request\"}") catch {};
        return;
    };

    const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse {
        send_http_response(conn.stream, "400 Bad Request", "{\"error\":\"malformed request\"}") catch {};
        return;
    };
    const first_line = raw[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse {
        send_http_response(conn.stream, "400 Bad Request", "{\"error\":\"malformed request\"}") catch {};
        return;
    };
    const target = parts.next() orelse {
        send_http_response(conn.stream, "400 Bad Request", "{\"error\":\"malformed request\"}") catch {};
        return;
    };

    const response = route_request(req_allocator, state, raw, method, target);
    defer if (response.allocated) req_allocator.free(@constCast(response.body));
    send_http_response(conn.stream, response.status, response.body) catch {};
}

pub fn run(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    cell_namespace: []const u8,
    cell_service_port: u16,
    internal_service_tokens: []const []const u8,
    internal_auth_required: bool,
) !void {
    health.markComponentOk("controller");

    var registry = CellRegistry.init(allocator);
    defer registry.deinit();

    var discovered_k8s = try cell_k8s_api.Client.initFromEnv(allocator);
    defer if (discovered_k8s) |*client| client.deinit();

    const state = ControllerState{
        .internal_service_tokens = internal_service_tokens,
        .internal_auth_required = internal_auth_required,
        .registry = &registry,
        .cell_template = .{
            .namespace = cell_namespace,
            .service_port = cell_service_port,
        },
        .k8s_client = if (discovered_k8s) |*client| client else null,
    };

    const addr = try std.net.Address.resolveIp(host, port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    var stdout_buf: [512]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    try bw.interface.print("Controller listening on {s}:{d}\n", .{ host, port });
    try bw.interface.flush();

    while (true) {
        const conn = try server.accept();
        handle_connection(allocator, state, conn);
    }
}

test "route_request health returns ok when all components are healthy" {
    health.reset();
    health.markComponentOk("controller");
    const response = route_request(std.testing.allocator, .{}, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n", "GET", "/health");
    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", response.body);
}

test "route_request ready returns 503 when a component is unhealthy" {
    health.reset();
    health.markComponentOk("controller");
    health.markComponentError("db", "down");
    const response = route_request(std.testing.allocator, .{}, "GET /ready HTTP/1.1\r\nHost: localhost\r\n\r\n", "GET", "/ready");
    defer if (response.allocated) std.testing.allocator.free(@constCast(response.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"status\":\"not_ready\"") != null);
}

test "route_request rejects non-get for health endpoints" {
    health.reset();
    const response = route_request(std.testing.allocator, .{}, "POST /health HTTP/1.1\r\nHost: localhost\r\n\r\n", "POST", "/health");
    try std.testing.expectEqualStrings("405 Method Not Allowed", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"method not allowed\"}", response.body);
}

test "route_request returns 404 for unknown path" {
    health.reset();
    const response = route_request(std.testing.allocator, .{}, "GET /internal/cells HTTP/1.1\r\nHost: localhost\r\n\r\n", "GET", "/internal/cells");
    try std.testing.expectEqualStrings("404 Not Found", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", response.body);
}

test "observed_controller_cell_state promotes ready pods to warm" {
    const observation = cell_k8s_api.CellObservation{
        .service_exists = true,
        .pod_exists = true,
        .pod_phase = .running,
        .pod_ready = true,
    };
    try std.testing.expectEqual(.warm, observed_controller_cell_state(.pending, observation));
}

test "observed_controller_cell_state keeps draining cells draining" {
    const observation = cell_k8s_api.CellObservation{
        .service_exists = true,
        .pod_exists = true,
        .pod_phase = .running,
        .pod_ready = true,
    };
    try std.testing.expectEqual(.draining, observed_controller_cell_state(.draining, observation));
}

test "should_finalize_observed_cell finalizes drained cells once pod and service are gone" {
    const observation = cell_k8s_api.CellObservation{};
    try std.testing.expect(should_finalize_observed_cell(.draining, observation));
    try std.testing.expect(!should_finalize_observed_cell(.pending, observation));
}

test "apply_observation_to_snapshot removes finalized drained cell from registry" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var ensured = try registry.ensure(std.testing.allocator, "42", "http://cell");
    defer ensured.deinit(std.testing.allocator);
    var drained = try registry.drain(std.testing.allocator, "42");
    defer drained.deinit(std.testing.allocator);

    var resolve_before = try registry.resolve(std.testing.allocator, "42");
    defer resolve_before.deinit(std.testing.allocator);
    try std.testing.expect(resolve_before.found);

    var snapshot_copy = resolve_before.snapshot.?;
    resolve_before.snapshot = null;
    defer snapshot_copy.deinit(std.testing.allocator);

    const reconciliation = apply_observation_to_snapshot(
        std.testing.allocator,
        &registry,
        "42",
        &snapshot_copy,
        .{},
        null,
    );
    try std.testing.expectEqual(.finalized, reconciliation);

    var resolve_after = try registry.resolve(std.testing.allocator, "42");
    defer resolve_after.deinit(std.testing.allocator);
    try std.testing.expect(!resolve_after.found);
}

test "controller ensure creates cell and resolve returns it" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"},
        .internal_auth_required = true,
        .registry = &registry,
    };

    const ensure_raw = "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\nContent-Length: 16\r\n\r\n{\"user_id\":\"42\"}";
    const ensure_response = route_request(std.testing.allocator, state, ensure_raw, "POST", "/internal/cells/ensure");
    defer if (ensure_response.allocated) std.testing.allocator.free(@constCast(ensure_response.body));
    try std.testing.expectEqualStrings("200 OK", ensure_response.status);
    try std.testing.expect(std.mem.indexOf(u8, ensure_response.body, "\"operation\":\"ensure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ensure_response.body, "\"created\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ensure_response.body, "\"state\":\"pending\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ensure_response.body, "\"desired\":") != null);

    const resolve_raw = "POST /internal/cells/resolve HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\nX-Zaki-User-Id: 42\r\n\r\n";
    const resolve_response = route_request(std.testing.allocator, state, resolve_raw, "POST", "/internal/cells/resolve");
    defer if (resolve_response.allocated) std.testing.allocator.free(@constCast(resolve_response.body));
    try std.testing.expectEqualStrings("200 OK", resolve_response.status);
    try std.testing.expect(std.mem.indexOf(u8, resolve_response.body, "\"found\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolve_response.body, "\"user_id\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolve_response.body, "\"service_name\":\"nullalis-cell-42\"") != null);
}

test "controller ensure stores cell_url and keeps cell pending until readiness" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"},
        .internal_auth_required = true,
        .registry = &registry,
    };

    const first_ensure_raw =
        "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\nContent-Length: 54\r\n\r\n{\"user_id\":\"42\",\"cell_url\":\"http://127.0.0.1:3100\"}";
    const first_response = route_request(std.testing.allocator, state, first_ensure_raw, "POST", "/internal/cells/ensure");
    defer if (first_response.allocated) std.testing.allocator.free(@constCast(first_response.body));
    try std.testing.expectEqualStrings("200 OK", first_response.status);
    try std.testing.expect(std.mem.indexOf(u8, first_response.body, "\"cell_url\":\"http://127.0.0.1:3100\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_response.body, "\"state\":\"pending\"") != null);

    const second_ensure_raw =
        "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\nContent-Length: 54\r\n\r\n{\"user_id\":\"42\",\"cell_url\":\"http://127.0.0.1:3200\"}";
    const second_response = route_request(std.testing.allocator, state, second_ensure_raw, "POST", "/internal/cells/ensure");
    defer if (second_response.allocated) std.testing.allocator.free(@constCast(second_response.body));
    try std.testing.expect(std.mem.indexOf(u8, second_response.body, "\"created\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_response.body, "\"cell_url\":\"http://127.0.0.1:3200\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_response.body, "\"state\":\"pending\"") != null);
}

test "controller ensure without cell_url creates pending cell" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var result = try registry.ensure(std.testing.allocator, "42", null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.created);
    try std.testing.expectEqual(ControllerCellState.pending, result.snapshot.state);
    try std.testing.expect(result.snapshot.cell_url == null);
}

test "controller ensure with cell_url creates pending cell until readiness" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var result = try registry.ensure(std.testing.allocator, "42", "http://127.0.0.1:3100");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.created);
    try std.testing.expectEqual(ControllerCellState.pending, result.snapshot.state);
    try std.testing.expectEqualStrings("http://127.0.0.1:3100", result.snapshot.cell_url.?);
}

test "controller ensure updates existing cell and drain marks draining" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"},
        .internal_auth_required = true,
        .registry = &registry,
    };

    const ensure_raw = "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\nX-Zaki-User-Id: 42\r\n\r\n";
    const first_response = route_request(std.testing.allocator, state, ensure_raw, "POST", "/internal/cells/ensure");
    defer if (first_response.allocated) std.testing.allocator.free(@constCast(first_response.body));
    const second_response = route_request(std.testing.allocator, state, ensure_raw, "POST", "/internal/cells/ensure");
    defer if (second_response.allocated) std.testing.allocator.free(@constCast(second_response.body));
    try std.testing.expect(std.mem.indexOf(u8, second_response.body, "\"created\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_response.body, "\"ensure_count\":2") != null);

    const drain_raw = "POST /internal/cells/drain HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\nX-Zaki-User-Id: 42\r\n\r\n";
    const drain_response = route_request(std.testing.allocator, state, drain_raw, "POST", "/internal/cells/drain");
    defer if (drain_response.allocated) std.testing.allocator.free(@constCast(drain_response.body));
    try std.testing.expectEqualStrings("200 OK", drain_response.status);
    try std.testing.expect(std.mem.indexOf(u8, drain_response.body, "\"found\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, drain_response.body, "\"state\":\"draining\"") != null);
}

test "controller status returns all cells summary" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"},
        .internal_auth_required = true,
        .registry = &registry,
    };

    var ensured_42 = registry.ensure(std.testing.allocator, "42", "http://127.0.0.1:3100") catch unreachable;
    defer ensured_42.deinit(std.testing.allocator);
    registry.mutex.lock();
    if (registry.cells.getPtr("42")) |record| record.state = .warm;
    registry.mutex.unlock();
    var ensured_77 = registry.ensure(std.testing.allocator, "77", null) catch unreachable;
    defer ensured_77.deinit(std.testing.allocator);
    var drained_77 = registry.drain(std.testing.allocator, "77") catch unreachable;
    defer drained_77.deinit(std.testing.allocator);

    const response = route_request(
        std.testing.allocator,
        state,
        "GET /internal/cells/status HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\n\r\n",
        "GET",
        "/internal/cells/status",
    );
    defer if (response.allocated) std.testing.allocator.free(@constCast(response.body));
    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"scope\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"warm_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"draining_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"pending_count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"namespace\":\"default\"") != null);
}

test "controller statusAll frees partial snapshots on allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();

    var registry = CellRegistry.init(alloc);
    defer registry.deinit();

    var ensured_42 = try registry.ensure(alloc, "42", null);
    defer ensured_42.deinit(alloc);
    var ensured_77 = try registry.ensure(alloc, "77", null);
    defer ensured_77.deinit(alloc);

    // statusAll allocates:
    // 1. snapshot slice
    // 2. first snapshot user_id dupe
    // 3. second snapshot user_id dupe
    // Fail on the third allocation to ensure the first snapshot is cleaned up.
    failing.fail_index = failing.alloc_index + 2;

    try std.testing.expectError(error.OutOfMemory, registry.statusAll(alloc));
}

test "controller ensure frees pending cell_url on create failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();

    var registry = CellRegistry.init(alloc);
    defer registry.deinit();

    failing.fail_index = failing.alloc_index + 2;
    try std.testing.expectError(error.OutOfMemory, registry.ensure(alloc, "42", "http://127.0.0.1:3100"));
}

test "controller cell control routes reject missing user id when required" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"},
        .internal_auth_required = true,
        .registry = &registry,
    };
    const response = route_request(
        std.testing.allocator,
        state,
        "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\n\r\n",
        "POST",
        "/internal/cells/ensure",
    );
    try std.testing.expectEqualStrings("400 Bad Request", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"missing_user_id\"}", response.body);
}

test "controller cell control routes require internal token when configured" {
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"},
        .internal_auth_required = true,
    };
    const raw = "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const response = route_request(std.testing.allocator, state, raw, "POST", "/internal/cells/ensure");
    try std.testing.expectEqualStrings("401 Unauthorized", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"unauthorized\"}", response.body);
}

test "controller cell control routes reject auth-required requests without configured tokens" {
    const state = ControllerState{
        .internal_service_tokens = &.{},
        .internal_auth_required = true,
    };
    const raw = "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\n\r\n";
    const response = route_request(std.testing.allocator, state, raw, "POST", "/internal/cells/ensure");
    try std.testing.expectEqualStrings("401 Unauthorized", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"unauthorized\"}", response.body);
}

test "controller cell control routes allow blank-only tokens when auth is not required" {
    var registry = CellRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{ "   ", "\t" },
        .internal_auth_required = false,
        .registry = &registry,
    };
    const raw = "GET /internal/cells/status HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const response = route_request(std.testing.allocator, state, raw, "GET", "/internal/cells/status");
    defer if (response.allocated) std.testing.allocator.free(@constCast(response.body));
    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"scope\":\"all\"") != null);
}

test "controller cell control routes require registry backing" {
    const state = ControllerState{
        .internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"},
        .internal_auth_required = true,
    };
    const raw = "GET /internal/cells/status HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\n\r\n";
    const response = route_request(std.testing.allocator, state, raw, "GET", "/internal/cells/status");
    try std.testing.expectEqualStrings("503 Service Unavailable", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"registry_unavailable\"}", response.body);
}

test "read_simple_http_request assembles fragmented post body" {
    const ChunkedReader = struct {
        chunks: []const []const u8,
        chunk_idx: usize = 0,
        offset_in_chunk: usize = 0,

        fn read(self: *@This(), out: []u8) !usize {
            while (self.chunk_idx < self.chunks.len and self.offset_in_chunk >= self.chunks[self.chunk_idx].len) {
                self.chunk_idx += 1;
                self.offset_in_chunk = 0;
            }
            if (self.chunk_idx >= self.chunks.len) return 0;

            const chunk = self.chunks[self.chunk_idx];
            const remaining = chunk[self.offset_in_chunk..];
            const n = @min(out.len, remaining.len);
            std.mem.copyForwards(u8, out[0..n], remaining[0..n]);
            self.offset_in_chunk += n;
            return n;
        }
    };

    const expected = "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nContent-Length: 16\r\n\r\n{\"user_id\":\"42\"}";
    const chunks = [_][]const u8{
        "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nContent-Length: 16\r\n\r\n",
        "{\"user_id\":\"42\"}",
    };
    var reader = ChunkedReader{ .chunks = chunks[0..] };

    const raw = try read_simple_http_request(std.testing.allocator, &reader);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(expected, raw);
}

test "configure_request_read_timeout is safe to call" {
    const listener = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();

    const client = try std.net.tcpConnectToAddress(server.listen_address);
    defer client.close();

    const conn = try server.accept();
    defer conn.stream.close();

    configure_request_read_timeout(conn.stream);
}
