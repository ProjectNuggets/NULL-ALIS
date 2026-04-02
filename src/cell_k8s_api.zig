const std = @import("std");
const platform = @import("platform.zig");
const cell_spec = @import("cell_spec.zig");

const SERVICE_ACCOUNT_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token";
const SERVICE_ACCOUNT_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";
const KUBE_REQUEST_TIMEOUT_SECS = "10";

pub const RuntimeConfig = struct {
    api_server_url: []const u8,
    bearer_token: []const u8,
    ca_cert_path: []const u8,
    cell_image: []const u8,
    controller_url: []const u8,
    cell_service_account_name: []const u8,
    cell_secret_name: []const u8,
    shared_workspace_claim: []const u8,
    workspace_subpath_root: []const u8,
    workspace_mount_path: []const u8,
    config_subpath: []const u8,
    config_mount_path: []const u8,
    cpu_request: []const u8,
    cpu_limit: []const u8,
    memory_request: []const u8,
    memory_limit: []const u8,
    run_as_user: u32,
    run_as_group: u32,
    fs_group: u32,

    pub fn deinit(self: *RuntimeConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.api_server_url);
        allocator.free(self.bearer_token);
        allocator.free(self.ca_cert_path);
        allocator.free(self.cell_image);
        allocator.free(self.controller_url);
        allocator.free(self.cell_service_account_name);
        allocator.free(self.cell_secret_name);
        allocator.free(self.shared_workspace_claim);
        allocator.free(self.workspace_subpath_root);
        allocator.free(self.workspace_mount_path);
        allocator.free(self.config_subpath);
        allocator.free(self.config_mount_path);
        allocator.free(self.cpu_request);
        allocator.free(self.cpu_limit);
        allocator.free(self.memory_request);
        allocator.free(self.memory_limit);
        self.* = undefined;
    }
};

const CurlResponse = struct {
    status_code: u16,
    body: []u8,

    fn deinit(self: *CurlResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const PodPhase = enum {
    missing,
    pending,
    running,
    succeeded,
    failed,
    unknown,
};

pub const CellObservation = struct {
    service_exists: bool = false,
    pod_exists: bool = false,
    pod_phase: PodPhase = .missing,
    pod_ready: bool = false,

    pub fn isWarm(self: CellObservation) bool {
        return self.service_exists and self.pod_exists and self.pod_phase == .running and self.pod_ready;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: RuntimeConfig,

    pub fn initFromEnv(allocator: std.mem.Allocator) !?Client {
        const service_host = platform.getEnvOrNull(allocator, "KUBERNETES_SERVICE_HOST") orelse return null;
        defer allocator.free(service_host);

        const service_port = platform.getEnvOrNull(allocator, "KUBERNETES_SERVICE_PORT") orelse return error.MissingKubernetesServicePort;
        defer allocator.free(service_port);
        const trimmed_port = std.mem.trim(u8, service_port, " \t\r\n");
        if (trimmed_port.len == 0) return error.MissingKubernetesServicePort;

        const cell_image = platform.getEnvOrNull(allocator, "NULLCLAW_CELL_IMAGE") orelse return error.MissingCellImage;
        errdefer allocator.free(cell_image);
        const trimmed_cell_image = std.mem.trim(u8, cell_image, " \t\r\n");
        if (trimmed_cell_image.len == 0) return error.MissingCellImage;
        if (trimmed_cell_image.ptr != cell_image.ptr or trimmed_cell_image.len != cell_image.len) {
            const normalized = try allocator.dupe(u8, trimmed_cell_image);
            allocator.free(cell_image);
            return .{
                .allocator = allocator,
                .config = try buildRuntimeConfig(
                    allocator,
                    service_host,
                    trimmed_port,
                    normalized,
                ),
            };
        }

        return .{
            .allocator = allocator,
            .config = try buildRuntimeConfig(
                allocator,
                service_host,
                trimmed_port,
                cell_image,
            ),
        };
    }

    pub fn deinit(self: *Client) void {
        self.config.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureCell(
        self: *const Client,
        allocator: std.mem.Allocator,
        desired: cell_spec.DesiredCellSpec,
        internal_service_token: ?[]const u8,
    ) !void {
        const service_path = try serviceResourcePath(allocator, desired);
        defer allocator.free(service_path);
        if (!(try resourceExists(self, allocator, service_path))) {
            const service_manifest = try buildServiceManifest(allocator, desired);
            defer allocator.free(service_manifest);
            const create_path = try serviceCreatePath(allocator, desired);
            defer allocator.free(create_path);
            try createResource(self, allocator, create_path, service_manifest);
        }

        const pod_path = try podResourcePath(allocator, desired);
        defer allocator.free(pod_path);
        if (!(try resourceExists(self, allocator, pod_path))) {
            const pod_manifest = try buildPodManifest(allocator, desired, self.config, internal_service_token);
            defer allocator.free(pod_manifest);
            const create_path = try podCreatePath(allocator, desired);
            defer allocator.free(create_path);
            try createResource(self, allocator, create_path, pod_manifest);
        }
    }

    pub fn drainCell(
        self: *const Client,
        allocator: std.mem.Allocator,
        desired: cell_spec.DesiredCellSpec,
    ) !void {
        const pod_path = try podResourcePath(allocator, desired);
        defer allocator.free(pod_path);
        try deleteResource(self, allocator, pod_path);

        const service_path = try serviceResourcePath(allocator, desired);
        defer allocator.free(service_path);
        try deleteResource(self, allocator, service_path);
    }

    pub fn observeCell(
        self: *const Client,
        allocator: std.mem.Allocator,
        desired: cell_spec.DesiredCellSpec,
    ) !CellObservation {
        const service_path = try serviceResourcePath(allocator, desired);
        defer allocator.free(service_path);
        const service_exists = try resourceExists(self, allocator, service_path);

        const pod_path = try podResourcePath(allocator, desired);
        defer allocator.free(pod_path);
        var observation = try observePod(self, allocator, pod_path);
        observation.service_exists = service_exists;
        return observation;
    }
};

fn readRequiredEnv(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const raw = platform.getEnvOrNull(allocator, name) orelse return error.MissingRequiredEnvironment;
    errdefer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.MissingRequiredEnvironment;
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const normalized = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return normalized;
}

fn buildRuntimeConfig(
    allocator: std.mem.Allocator,
    service_host: []const u8,
    service_port: []const u8,
    owned_cell_image: []const u8,
) !RuntimeConfig {
    errdefer allocator.free(owned_cell_image);

    const api_server_url = try std.fmt.allocPrint(allocator, "https://{s}:{s}", .{ service_host, service_port });
    errdefer allocator.free(api_server_url);
    const bearer_token = try readTrimmedFile(allocator, SERVICE_ACCOUNT_TOKEN_PATH);
    errdefer allocator.free(bearer_token);
    const ca_cert_path = try allocator.dupe(u8, SERVICE_ACCOUNT_CA_PATH);
    errdefer allocator.free(ca_cert_path);
    const controller_url = try readRequiredEnv(allocator, "NULLCLAW_CONTROLLER_URL");
    errdefer allocator.free(controller_url);
    const cell_service_account_name = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_SERVICE_ACCOUNT_NAME", "default");
    errdefer allocator.free(cell_service_account_name);
    const cell_secret_name = try readRequiredEnv(allocator, "NULLCLAW_CELL_SECRET_NAME");
    errdefer allocator.free(cell_secret_name);
    const shared_workspace_claim = try readRequiredEnv(allocator, "NULLCLAW_CELL_SHARED_WORKSPACE_CLAIM");
    errdefer allocator.free(shared_workspace_claim);
    const config_subpath = try readRequiredEnv(allocator, "NULLCLAW_CELL_CONFIG_SUBPATH");
    errdefer allocator.free(config_subpath);
    const workspace_subpath_root = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_WORKSPACE_SUBPATH_ROOT", "users");
    errdefer allocator.free(workspace_subpath_root);
    const workspace_mount_path = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_WORKSPACE_MOUNT_PATH", "/workspace");
    errdefer allocator.free(workspace_mount_path);
    const config_mount_path = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_CONFIG_MOUNT_PATH", "/etc/nullalis/config.json");
    errdefer allocator.free(config_mount_path);
    const cpu_request = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_CPU_REQUEST", "250m");
    errdefer allocator.free(cpu_request);
    const cpu_limit = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_CPU_LIMIT", "1000m");
    errdefer allocator.free(cpu_limit);
    const memory_request = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_MEMORY_REQUEST", "512Mi");
    errdefer allocator.free(memory_request);
    const memory_limit = try readOptionalEnvOrDefault(allocator, "NULLCLAW_CELL_MEMORY_LIMIT", "1Gi");
    errdefer allocator.free(memory_limit);
    const run_as_user = try readOptionalU32EnvOrDefault(allocator, "NULLCLAW_CELL_RUN_AS_USER", 1000);
    const run_as_group = try readOptionalU32EnvOrDefault(allocator, "NULLCLAW_CELL_RUN_AS_GROUP", 1000);
    const fs_group = try readOptionalU32EnvOrDefault(allocator, "NULLCLAW_CELL_FS_GROUP", 1000);

    return .{
        .api_server_url = api_server_url,
        .bearer_token = bearer_token,
        .ca_cert_path = ca_cert_path,
        .cell_image = owned_cell_image,
        .controller_url = controller_url,
        .cell_service_account_name = cell_service_account_name,
        .cell_secret_name = cell_secret_name,
        .shared_workspace_claim = shared_workspace_claim,
        .workspace_subpath_root = workspace_subpath_root,
        .workspace_mount_path = workspace_mount_path,
        .config_subpath = config_subpath,
        .config_mount_path = config_mount_path,
        .cpu_request = cpu_request,
        .cpu_limit = cpu_limit,
        .memory_request = memory_request,
        .memory_limit = memory_limit,
        .run_as_user = run_as_user,
        .run_as_group = run_as_group,
        .fs_group = fs_group,
    };
}

fn readOptionalEnvOrDefault(
    allocator: std.mem.Allocator,
    name: []const u8,
    default_value: []const u8,
) ![]const u8 {
    const raw = platform.getEnvOrNull(allocator, name) orelse return allocator.dupe(u8, default_value);
    errdefer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return allocator.dupe(u8, default_value);
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const normalized = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return normalized;
}

fn readOptionalU32EnvOrDefault(
    allocator: std.mem.Allocator,
    name: []const u8,
    default_value: u32,
) !u32 {
    const raw = platform.getEnvOrNull(allocator, name) orelse return default_value;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_value;
    return std.fmt.parseInt(u32, trimmed, 10) catch return error.InvalidKubernetesTemplateConfig;
}

fn workspaceSubpath(allocator: std.mem.Allocator, runtime: RuntimeConfig, desired: cell_spec.DesiredCellSpec) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}/workspace",
        .{ runtime.workspace_subpath_root, desired.user_id },
    );
}

fn readTrimmedFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 16 * 1024);
    errdefer allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyServiceAccountToken;
    if (trimmed.ptr == contents.ptr and trimmed.len == contents.len) return contents;
    const normalized = try allocator.dupe(u8, trimmed);
    allocator.free(contents);
    return normalized;
}

fn firstConfiguredInternalServiceToken(tokens: []const []const u8) ?[]const u8 {
    for (tokens) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn serviceCreatePath(allocator: std.mem.Allocator, desired: cell_spec.DesiredCellSpec) ![]u8 {
    return std.fmt.allocPrint(allocator, "/api/v1/namespaces/{s}/services", .{desired.namespace});
}

fn serviceResourcePath(allocator: std.mem.Allocator, desired: cell_spec.DesiredCellSpec) ![]u8 {
    return std.fmt.allocPrint(allocator, "/api/v1/namespaces/{s}/services/{s}", .{ desired.namespace, desired.service_name });
}

fn podCreatePath(allocator: std.mem.Allocator, desired: cell_spec.DesiredCellSpec) ![]u8 {
    return std.fmt.allocPrint(allocator, "/api/v1/namespaces/{s}/pods", .{desired.namespace});
}

fn podResourcePath(allocator: std.mem.Allocator, desired: cell_spec.DesiredCellSpec) ![]u8 {
    return std.fmt.allocPrint(allocator, "/api/v1/namespaces/{s}/pods/{s}", .{ desired.namespace, desired.pod_name });
}

fn resourceExists(self: *const Client, allocator: std.mem.Allocator, path: []const u8) !bool {
    var response = try kubeRequest(self, allocator, "GET", path, null);
    defer response.deinit(allocator);
    return switch (response.status_code) {
        200 => true,
        404 => false,
        else => error.KubernetesRequestFailed,
    };
}

fn createResource(self: *const Client, allocator: std.mem.Allocator, path: []const u8, body: []const u8) !void {
    var response = try kubeRequest(self, allocator, "POST", path, body);
    defer response.deinit(allocator);
    switch (response.status_code) {
        200, 201, 202, 409 => return,
        else => return error.KubernetesRequestFailed,
    }
}

fn deleteResource(self: *const Client, allocator: std.mem.Allocator, path: []const u8) !void {
    var response = try kubeRequest(self, allocator, "DELETE", path, null);
    defer response.deinit(allocator);
    switch (response.status_code) {
        200, 202, 404 => return,
        else => return error.KubernetesRequestFailed,
    }
}

fn observePod(self: *const Client, allocator: std.mem.Allocator, path: []const u8) !CellObservation {
    var response = try kubeRequest(self, allocator, "GET", path, null);
    defer response.deinit(allocator);
    return switch (response.status_code) {
        200 => parsePodObservationBody(allocator, response.body),
        404 => .{},
        else => error.KubernetesRequestFailed,
    };
}

fn parsePodObservationBody(allocator: std.mem.Allocator, body: []const u8) !CellObservation {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.KubernetesRequestFailed;

    var observation = CellObservation{ .pod_exists = true, .pod_phase = .unknown };
    const status_value = parsed.value.object.get("status") orelse return observation;
    if (status_value != .object) return error.KubernetesRequestFailed;

    if (status_value.object.get("phase")) |phase_value| {
        if (phase_value != .string) return error.KubernetesRequestFailed;
        if (std.mem.eql(u8, phase_value.string, "Pending")) {
            observation.pod_phase = .pending;
        } else if (std.mem.eql(u8, phase_value.string, "Running")) {
            observation.pod_phase = .running;
        } else if (std.mem.eql(u8, phase_value.string, "Succeeded")) {
            observation.pod_phase = .succeeded;
        } else if (std.mem.eql(u8, phase_value.string, "Failed")) {
            observation.pod_phase = .failed;
        } else {
            observation.pod_phase = .unknown;
        }
    }
    if (status_value.object.get("conditions")) |conditions_value| {
        if (conditions_value != .array) return error.KubernetesRequestFailed;
        for (conditions_value.array.items) |condition| {
            if (condition != .object) continue;
            const type_value = condition.object.get("type") orelse continue;
            const status_entry = condition.object.get("status") orelse continue;
            if (type_value != .string or status_entry != .string) continue;
            if (std.mem.eql(u8, type_value.string, "Ready") and std.mem.eql(u8, status_entry.string, "True")) {
                observation.pod_ready = true;
                break;
            }
        }
    }
    return observation;
}

fn kubeRequest(
    self: *const Client,
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
) !CurlResponse {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.config.api_server_url, path });
    defer allocator.free(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{self.config.bearer_token});
    defer allocator.free(auth_header);
    var headers_buf: [3][]const u8 = undefined;
    var header_count: usize = 0;
    headers_buf[header_count] = auth_header;
    header_count += 1;
    headers_buf[header_count] = "Accept: application/json";
    header_count += 1;
    if (body != null) {
        headers_buf[header_count] = "Content-Type: application/json";
        header_count += 1;
    }

    var argv_buf: [64][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-sS";
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = KUBE_REQUEST_TIMEOUT_SECS;
    argc += 1;
    argv_buf[argc] = "--cacert";
    argc += 1;
    argv_buf[argc] = self.config.ca_cert_path;
    argc += 1;
    argv_buf[argc] = "--request";
    argc += 1;
    argv_buf[argc] = method;
    argc += 1;
    argv_buf[argc] = "--write-out";
    argc += 1;
    argv_buf[argc] = "\n__NULLALIS_K8S_STATUS__:%{http_code}";
    argc += 1;

    for (headers_buf[0..header_count]) |header| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = header;
        argc += 1;
    }

    if (body != null) {
        argv_buf[argc] = "--data-binary";
        argc += 1;
        argv_buf[argc] = "@-";
        argc += 1;
    }

    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = if (body != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    if (body) |request_body| {
        if (child.stdin) |stdin_file| {
            try stdin_file.writeAll(request_body);
            stdin_file.close();
            child.stdin = null;
        } else {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.KubernetesRequestFailed;
        }
    }

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.KubernetesRequestFailed,
        else => return error.KubernetesRequestFailed,
    }

    const marker = "\n__NULLALIS_K8S_STATUS__:";
    const marker_index = std.mem.lastIndexOf(u8, stdout, marker) orelse return error.KubernetesRequestFailed;
    const status_slice = stdout[marker_index + marker.len ..];
    const status_code = std.fmt.parseInt(u16, std.mem.trim(u8, status_slice, " \t\r\n"), 10) catch return error.KubernetesRequestFailed;
    const body_copy = try allocator.dupe(u8, stdout[0..marker_index]);
    allocator.free(stdout);
    return .{
        .status_code = status_code,
        .body = body_copy,
    };
}

pub fn buildServiceManifest(allocator: std.mem.Allocator, desired: cell_spec.DesiredCellSpec) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"apiVersion\":\"v1\",\"kind\":\"Service\",\"metadata\":{{\"name\":{f},\"namespace\":{f},\"labels\":{{\"app.kubernetes.io/name\":\"nullalis-user-cell\",\"nullalis.ai/cell\":{f},\"app.kubernetes.io/managed-by\":\"nullalis-controller\"}}}},\"spec\":{{\"selector\":{{\"nullalis.ai/cell\":{f}}},\"ports\":[{{\"name\":\"http\",\"port\":{d},\"targetPort\":{d}}}]}}}}",
        .{
            std.json.fmt(desired.service_name, .{}),
            std.json.fmt(desired.namespace, .{}),
            std.json.fmt(desired.service_name, .{}),
            std.json.fmt(desired.service_name, .{}),
            desired.service_port,
            desired.service_port,
        },
    );
}

pub fn buildPodManifest(
    allocator: std.mem.Allocator,
    desired: cell_spec.DesiredCellSpec,
    runtime: RuntimeConfig,
    internal_service_token: ?[]const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    const port_arg = try std.fmt.allocPrint(allocator, "{d}", .{desired.service_port});
    defer allocator.free(port_arg);
    const home_path = try std.fmt.allocPrint(allocator, "{s}/.home", .{runtime.workspace_mount_path});
    defer allocator.free(home_path);
    const workspace_subpath = try workspaceSubpath(allocator, runtime, desired);
    defer allocator.free(workspace_subpath);

    try writer.print(
        "{{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{{\"name\":{f},\"namespace\":{f},\"labels\":{{\"app.kubernetes.io/name\":\"nullalis-user-cell\",\"nullalis.ai/cell\":{f},\"app.kubernetes.io/managed-by\":\"nullalis-controller\"}}}},\"spec\":{{\"restartPolicy\":\"Always\",\"serviceAccountName\":{f},\"automountServiceAccountToken\":false,\"securityContext\":{{\"fsGroup\":{d}}},\"containers\":[{{\"name\":\"nullalis\",\"image\":{f},\"imagePullPolicy\":\"IfNotPresent\",\"args\":[\"gateway\",\"--role\",\"user_cell\",\"--user-id\",{f},\"--controller-url\",{f},\"--advertise-url\",{f},\"--host\",\"0.0.0.0\",\"--port\",{f}],\"ports\":[{{\"name\":\"http\",\"containerPort\":{d}}}],\"env\":[{{\"name\":\"NULLALIS_CONFIG_PATH\",\"value\":{f}}},{{\"name\":\"NULLCLAW_WORKSPACE\",\"value\":{f}}},{{\"name\":\"HOME\",\"value\":{f}}},{{\"name\":\"NULLCLAW_ALLOW_PUBLIC_BIND\",\"value\":\"true\"}}",
        .{
            std.json.fmt(desired.pod_name, .{}),
            std.json.fmt(desired.namespace, .{}),
            std.json.fmt(desired.service_name, .{}),
            std.json.fmt(runtime.cell_service_account_name, .{}),
            runtime.fs_group,
            std.json.fmt(runtime.cell_image, .{}),
            std.json.fmt(desired.user_id, .{}),
            std.json.fmt(runtime.controller_url, .{}),
            std.json.fmt(desired.advertise_url, .{}),
            std.json.fmt(port_arg, .{}),
            desired.service_port,
            std.json.fmt(runtime.config_mount_path, .{}),
            std.json.fmt(runtime.workspace_mount_path, .{}),
            std.json.fmt(home_path, .{}),
        },
    );
    if (internal_service_token) |token| {
        try writer.print(
            ",{{\"name\":\"NULLCLAW_INTERNAL_SERVICE_TOKEN\",\"value\":{f}}}",
            .{std.json.fmt(token, .{})},
        );
    }
    try writer.writeAll("],\"envFrom\":[");
    try writer.print(
        "{{\"secretRef\":{{\"name\":{f}}}}}",
        .{std.json.fmt(runtime.cell_secret_name, .{})},
    );
    try writer.print(
        "],\"resources\":{{\"requests\":{{\"cpu\":{f},\"memory\":{f}}},\"limits\":{{\"cpu\":{f},\"memory\":{f}}}}},\"securityContext\":{{\"runAsNonRoot\":true,\"runAsUser\":{d},\"runAsGroup\":{d},\"allowPrivilegeEscalation\":false}},\"volumeMounts\":[{{\"name\":\"shared-workspace\",\"mountPath\":{f},\"subPath\":{f}}},{{\"name\":\"shared-workspace\",\"mountPath\":{f},\"subPath\":{f},\"readOnly\":true}},{{\"name\":\"tmp\",\"mountPath\":\"/tmp\"}}]}}],\"volumes\":[{{\"name\":\"shared-workspace\",\"persistentVolumeClaim\":{{\"claimName\":{f}}}}},{{\"name\":\"tmp\",\"emptyDir\":{{}}}}]}}}}",
        .{
            std.json.fmt(runtime.cpu_request, .{}),
            std.json.fmt(runtime.memory_request, .{}),
            std.json.fmt(runtime.cpu_limit, .{}),
            std.json.fmt(runtime.memory_limit, .{}),
            runtime.run_as_user,
            runtime.run_as_group,
            std.json.fmt(runtime.workspace_mount_path, .{}),
            std.json.fmt(workspace_subpath, .{}),
            std.json.fmt(runtime.config_mount_path, .{}),
            std.json.fmt(runtime.config_subpath, .{}),
            std.json.fmt(runtime.shared_workspace_claim, .{}),
        },
    );
    return out.toOwnedSlice(allocator);
}

test "buildServiceManifest renders stable service and selector" {
    var desired = try cell_spec.desiredSpec(std.testing.allocator, .{
        .namespace = "nullalis-cells-standard",
        .service_port = 3000,
    }, "42");
    defer desired.deinit(std.testing.allocator);

    const manifest = try buildServiceManifest(std.testing.allocator, desired);
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"kind\":\"Service\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\":\"nullalis-cell-42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"nullalis.ai/cell\":\"nullalis-cell-42\"") != null);
}

test "buildPodManifest includes controller and advertise args" {
    var desired = try cell_spec.desiredSpec(std.testing.allocator, .{
        .namespace = "nullalis-cells-standard",
        .service_port = 3000,
    }, "42");
    defer desired.deinit(std.testing.allocator);

    const runtime = RuntimeConfig{
        .api_server_url = try std.testing.allocator.dupe(u8, "https://10.0.0.1:443"),
        .bearer_token = try std.testing.allocator.dupe(u8, "token"),
        .ca_cert_path = try std.testing.allocator.dupe(u8, "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"),
        .cell_image = try std.testing.allocator.dupe(u8, "ghcr.io/projectnuggets/nullalis:test"),
        .controller_url = try std.testing.allocator.dupe(u8, "http://nullalis-controller.zaki.svc.cluster.local:3001"),
        .cell_service_account_name = try std.testing.allocator.dupe(u8, "nullclaw"),
        .cell_secret_name = try std.testing.allocator.dupe(u8, "nullclaw-runtime-secrets"),
        .shared_workspace_claim = try std.testing.allocator.dupe(u8, "nullclaw-data-rwx-v2"),
        .workspace_subpath_root = try std.testing.allocator.dupe(u8, "users"),
        .workspace_mount_path = try std.testing.allocator.dupe(u8, "/workspace"),
        .config_subpath = try std.testing.allocator.dupe(u8, ".nullalis/config.json"),
        .config_mount_path = try std.testing.allocator.dupe(u8, "/etc/nullalis/config.json"),
        .cpu_request = try std.testing.allocator.dupe(u8, "250m"),
        .cpu_limit = try std.testing.allocator.dupe(u8, "1000m"),
        .memory_request = try std.testing.allocator.dupe(u8, "512Mi"),
        .memory_limit = try std.testing.allocator.dupe(u8, "1Gi"),
        .run_as_user = 1000,
        .run_as_group = 1000,
        .fs_group = 1000,
    };
    var mutable_runtime = runtime;
    defer mutable_runtime.deinit(std.testing.allocator);

    const manifest = try buildPodManifest(
        std.testing.allocator,
        desired,
        mutable_runtime,
        "svc-prod-token-1234",
    );
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"kind\":\"Pod\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"--controller-url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"--advertise-url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"NULLCLAW_INTERNAL_SERVICE_TOKEN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"serviceAccountName\":\"nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"automountServiceAccountToken\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"secretRef\":{\"name\":\"nullclaw-runtime-secrets\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"NULLALIS_CONFIG_PATH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"claimName\":\"nullclaw-data-rwx-v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"subPath\":\"users/42/workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"runAsNonRoot\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"cpu\":\"250m\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "parsePodObservationBody detects ready running pod" {
    const body =
        \\{"status":{"phase":"Running","conditions":[{"type":"Initialized","status":"True"},{"type":"Ready","status":"True"}]}}
    ;
    const observation = try parsePodObservationBody(std.testing.allocator, body);
    try std.testing.expect(observation.pod_exists);
    try std.testing.expectEqual(PodPhase.running, observation.pod_phase);
    try std.testing.expect(observation.pod_ready);
    try std.testing.expect(!observation.service_exists);
    try std.testing.expect(!observation.isWarm());
}

test "parsePodObservationBody detects pending pod" {
    const body =
        \\{"status":{"phase":"Pending","conditions":[{"type":"Ready","status":"False"}]}}
    ;
    const observation = try parsePodObservationBody(std.testing.allocator, body);
    try std.testing.expect(observation.pod_exists);
    try std.testing.expectEqual(PodPhase.pending, observation.pod_phase);
    try std.testing.expect(!observation.pod_ready);
}

test "firstConfiguredInternalServiceToken skips blank entries" {
    const tokens = [_][]const u8{ "", "  ", "svc-prod-token-1234" };
    try std.testing.expectEqualStrings("svc-prod-token-1234", firstConfiguredInternalServiceToken(&tokens).?);
    try std.testing.expect(firstConfiguredInternalServiceToken(&[_][]const u8{ "", "  " }) == null);
}
