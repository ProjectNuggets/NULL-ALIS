//! OpenAPI tool — Sprint 3 Universal API Connector.
//!
//! ONE `Tool` that gives the agent structured, governed access to every
//! operator-registered OpenAPI 3.x spec. It is NOT a per-endpoint tool
//! explosion: a single `openapi` tool with an `operation` argument exposes
//! three modes —
//!
//!   - `list`     → registered spec ids + their operations (discovery)
//!   - `describe` → one operation's parameters + body shape
//!   - `invoke`   → resolve, build, auth, gate, and execute one operation
//!
//! Layering:
//!   - `src/openapi/` (parser + request builder) is pure + deterministic.
//!   - This file owns all I/O: spec fetching, lazy caching, credential
//!     resolution + injection, the approval / read-only-mode gates, and
//!     the HTTP execution.
//!
//! Security posture:
//!   - Specs are NEVER ingested from agent input — only from the operator's
//!     `config.api_specs`. The agent picks a spec by its declared `id`.
//!   - The static credential (`auth_ref` → env var) is resolved here and
//!     injected into the request. It never appears in the tool's args,
//!     output, logs, or the model's context.
//!   - Egress goes through SSRF-safe DNS pinning (`net_security`) +
//!     `http_util.request_with_mode` exactly like `http_request.zig`.
//!   - A spec declared `mode = .read_only` HARD-REFUSES every write
//!     operation (POST/PUT/PATCH/DELETE) regardless of agent autonomy.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const net_security = @import("../root.zig").net_security;
const http_util = @import("../root.zig").http_util;
const openapi = @import("../openapi/root.zig");
const config_types = @import("../config_types.zig");
const metadata = @import("metadata.zig");
const ApiSpecConfig = config_types.ApiSpecConfig;
const appendJsonEscaped = @import("../util.zig").appendJsonEscaped;

const log = std.log.scoped(.openapi_tool);

/// Hard ceiling on a fetched spec document. A spec larger than this is
/// almost certainly not a spec — refuse rather than OOM.
const MAX_SPEC_BYTES: usize = 4 * 1024 * 1024;
/// Hard ceiling on a response body surfaced back to the model.
const MAX_RESPONSE_BYTES: usize = 256 * 1024;
/// Default HTTP timeout for spec fetch + invoke.
const HTTP_TIMEOUT_MS: u32 = 30_000;

// ── Spec registry (Step 3) ──────────────────────────────────────────
//
// One cache slot per registered spec id. The parsed `Spec` and every
// slice it points into live in a per-slot `ArenaAllocator` owned by the
// tool struct, so the cache survives across turns and is freed once when
// the tool is deinit'd. Fetch + parse happen lazily on the first
// `describe`/`invoke` that touches a given spec id.

const SpecSlot = struct {
    /// Arena holding the parsed `Spec` and all its backing bytes.
    arena: std.heap.ArenaAllocator,
    /// Populated on a successful parse; null until first lazy load.
    spec: ?openapi.Spec = null,
    /// True once a load attempt completed (success OR failure). A failed
    /// load is NOT retried within the process — the operator must fix the
    /// config and restart. This keeps a broken spec from hammering an
    /// unreachable URL on every tool call.
    loaded: bool = false,
    /// On a failed load, a human-readable reason for the tool error.
    load_error: ?[]const u8 = null,
};

// ── The tool (Steps 4–6) ────────────────────────────────────────────

pub const OpenApiTool = struct {
    /// Operator-registered specs. Borrowed from `Config` — not owned.
    specs: []const ApiSpecConfig = &.{},
    /// Lazy per-id parse cache. Heap-allocated parallel to `specs`,
    /// owned by this struct, freed in `deinitState`.
    slots: []SpecSlot = &.{},
    /// Allocator used to create `slots` + each slot's error string.
    slot_allocator: ?std.mem.Allocator = null,

    pub const tool_name = "openapi";

    pub const tool_description_struct = metadata.ToolDescription{
        .what = "Call operator-registered REST APIs from their OpenAPI specs.",
        .use_when = &.{
            "Discovering or calling a specific operation on a registered API spec",
            "The operator has declared an api_specs entry the task needs",
        },
        .do_not_use_for = &.{
            "http_request — for arbitrary one-off calls to unregistered endpoints",
            "composio — for managed OAuth integrations like Gmail or Slack",
        },
        .cost_note = "Makes a live external HTTP call on invoke; quota of the target API applies.",
        .completion_hint = "Returns the API response body and HTTP status.",
        .see_also = &.{
            "http_request — for ad-hoc unregistered endpoints",
            "composio — for managed OAuth app integrations",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("openapi", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description = "Access operator-registered REST APIs via their OpenAPI specs. " ++
        "Use operation='list' to see registered specs and their operations, " ++
        "operation='describe' with spec/operation_id for one operation's parameters, " ++
        "or operation='invoke' with spec/operation_id (+ path_params/query/body) to call it.";

    pub const tool_params =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["list","describe","invoke"],"description":"What to do: list specs, describe an operation, or invoke one"},"spec":{"type":"string","description":"Registered spec id (required for describe/invoke)"},"operation_id":{"type":"string","description":"operationId within the spec (required for describe/invoke)"},"path_params":{"type":"object","description":"Path parameter values for invoke, keyed by name"},"query":{"type":"object","description":"Query (and spec-declared header) parameter values for invoke"},"body":{"type":"object","description":"Request body object for invoke; serialized to JSON"}},"required":["operation"]}
    ;

    // The OpenAPI tool owns heap state (the slot cache) beyond its struct,
    // so it cannot use the default `ToolVTable` deinit (which only does
    // `destroy(self)`). A bespoke vtable frees the cache first.
    const vtable = Tool.VTable{
        .execute = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
                const self: *OpenApiTool = @ptrCast(@alignCast(ptr));
                return self.execute(allocator, args);
            }
        }.f,
        .name = &struct {
            fn f(_: *anyopaque) []const u8 {
                return tool_name;
            }
        }.f,
        .description = &struct {
            fn f(_: *anyopaque) []const u8 {
                return metadata.renderDescriptionComptime(tool_description_struct);
            }
        }.f,
        .parameters_json = &struct {
            fn f(_: *anyopaque) []const u8 {
                return tool_params;
            }
        }.f,
        .deinit = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *OpenApiTool = @ptrCast(@alignCast(ptr));
                self.deinitState();
                allocator.destroy(self);
            }
        }.f,
    };

    pub fn tool(self: *OpenApiTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Allocate the lazy-load slot cache. Call once after setting `specs`.
    /// Each slot owns an arena; nothing is parsed until first use.
    pub fn initSlots(self: *OpenApiTool, allocator: std.mem.Allocator) !void {
        const slots = try allocator.alloc(SpecSlot, self.specs.len);
        for (slots) |*s| {
            s.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        }
        self.slots = slots;
        self.slot_allocator = allocator;
    }

    /// Free the slot cache. Idempotent.
    pub fn deinitState(self: *OpenApiTool) void {
        const alloc = self.slot_allocator orelse return;
        for (self.slots) |*s| {
            if (s.load_error) |e| alloc.free(e);
            s.arena.deinit();
        }
        if (self.slots.len > 0) alloc.free(self.slots);
        self.slots = &.{};
        self.slot_allocator = null;
    }

    pub fn execute(self: *OpenApiTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const operation = root.getString(args, "operation") orelse
            return ToolResult.fail("Missing 'operation' parameter (use 'list', 'describe', or 'invoke')");

        if (std.mem.eql(u8, operation, "list")) {
            return self.opList(allocator);
        } else if (std.mem.eql(u8, operation, "describe")) {
            return self.opDescribe(allocator, args);
        } else if (std.mem.eql(u8, operation, "invoke")) {
            return self.opInvoke(allocator, args);
        }
        const msg = try std.fmt.allocPrint(
            allocator,
            "Unknown operation '{s}'. Use 'list', 'describe', or 'invoke'.",
            .{operation},
        );
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    // ── list ────────────────────────────────────────────────────────

    /// Discovery surface: every registered spec id plus its operations
    /// (id, method, path, summary). Lazy-loads each spec so the agent
    /// sees real operations; a spec that fails to load is listed with
    /// its error instead of being silently dropped.
    fn opList(self: *OpenApiTool, allocator: std.mem.Allocator) !ToolResult {
        if (self.specs.len == 0) {
            return ToolResult.ok("No API specs are registered. The operator declares them under config.api_specs.");
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"specs\":[");
        for (self.specs, 0..) |cfg, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"id\":\"");
            try appendJsonEscaped(&buf, allocator, cfg.id);
            try buf.appendSlice(allocator, "\",\"mode\":\"");
            try buf.appendSlice(allocator, cfg.mode.toSlice());
            try buf.append(allocator, '"');

            const loaded = self.loadSpec(idx);
            if (loaded.spec) |spec| {
                try buf.appendSlice(allocator, ",\"title\":\"");
                try appendJsonEscaped(&buf, allocator, spec.title);
                try buf.appendSlice(allocator, "\",\"operations\":[");
                for (spec.operations, 0..) |op, op_idx| {
                    if (op_idx > 0) try buf.append(allocator, ',');
                    try buf.appendSlice(allocator, "{\"operation_id\":\"");
                    try appendJsonEscaped(&buf, allocator, op.operation_id);
                    try buf.appendSlice(allocator, "\",\"method\":\"");
                    try appendJsonEscaped(&buf, allocator, op.method);
                    try buf.appendSlice(allocator, "\",\"path\":\"");
                    try appendJsonEscaped(&buf, allocator, op.path);
                    try buf.appendSlice(allocator, "\",\"summary\":\"");
                    try appendJsonEscaped(&buf, allocator, op.summary);
                    try buf.appendSlice(allocator, "\",\"read_only\":");
                    try buf.appendSlice(allocator, if (op.isReadOnly()) "true" else "false");
                    try buf.append(allocator, '}');
                }
                try buf.append(allocator, ']');
            } else {
                try buf.appendSlice(allocator, ",\"error\":\"");
                try appendJsonEscaped(&buf, allocator, loaded.load_error orelse "spec failed to load");
                try buf.append(allocator, '"');
            }
            try buf.append(allocator, '}');
        }
        try buf.appendSlice(allocator, "]}");

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    // ── describe ────────────────────────────────────────────────────

    /// Describe one operation: its parameters (name, location, required,
    /// type) and request-body property shape.
    fn opDescribe(self: *OpenApiTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const spec_id = root.getString(args, "spec") orelse
            return failOwned(allocator, "Missing 'spec' parameter for describe");
        const op_id = root.getString(args, "operation_id") orelse
            return failOwned(allocator, "Missing 'operation_id' parameter for describe");

        const idx = self.findSpecIndex(spec_id) orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "No registered spec with id '{s}'. Use operation='list' to see registered specs.",
                .{spec_id},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        const loaded = self.loadSpec(idx);
        const spec = loaded.spec orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Spec '{s}' could not be loaded: {s}",
                .{ spec_id, loaded.load_error orelse "unknown error" },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        const op = spec.findOperation(op_id) orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Spec '{s}' has no operation '{s}'.",
                .{ spec_id, op_id },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"spec\":\"");
        try appendJsonEscaped(&buf, allocator, spec_id);
        try buf.appendSlice(allocator, "\",\"operation_id\":\"");
        try appendJsonEscaped(&buf, allocator, op.operation_id);
        try buf.appendSlice(allocator, "\",\"method\":\"");
        try appendJsonEscaped(&buf, allocator, op.method);
        try buf.appendSlice(allocator, "\",\"path\":\"");
        try appendJsonEscaped(&buf, allocator, op.path);
        try buf.appendSlice(allocator, "\",\"summary\":\"");
        try appendJsonEscaped(&buf, allocator, op.summary);
        try buf.appendSlice(allocator, "\",\"description\":\"");
        try appendJsonEscaped(&buf, allocator, op.description);
        try buf.appendSlice(allocator, "\",\"read_only\":");
        try buf.appendSlice(allocator, if (op.isReadOnly()) "true" else "false");

        // parameters
        try buf.appendSlice(allocator, ",\"parameters\":[");
        for (op.parameters, 0..) |p, p_idx| {
            if (p_idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"name\":\"");
            try appendJsonEscaped(&buf, allocator, p.name);
            try buf.appendSlice(allocator, "\",\"in\":\"");
            try buf.appendSlice(allocator, p.location.toSlice());
            try buf.appendSlice(allocator, "\",\"required\":");
            try buf.appendSlice(allocator, if (p.required) "true" else "false");
            try buf.appendSlice(allocator, ",\"type\":\"");
            try appendJsonEscaped(&buf, allocator, p.schema_type);
            try buf.appendSlice(allocator, "\",\"description\":\"");
            try appendJsonEscaped(&buf, allocator, p.description);
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');

        // request body
        if (op.request_body) |rb| {
            try buf.appendSlice(allocator, ",\"request_body\":{\"required\":");
            try buf.appendSlice(allocator, if (rb.required) "true" else "false");
            try buf.appendSlice(allocator, ",\"media_type\":\"");
            try appendJsonEscaped(&buf, allocator, rb.media_type);
            try buf.appendSlice(allocator, "\",\"properties\":[");
            for (rb.properties, 0..) |prop, prop_idx| {
                if (prop_idx > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "{\"name\":\"");
                try appendJsonEscaped(&buf, allocator, prop.name);
                try buf.appendSlice(allocator, "\",\"type\":\"");
                try appendJsonEscaped(&buf, allocator, prop.schema_type);
                try buf.appendSlice(allocator, "\",\"required\":");
                try buf.appendSlice(allocator, if (prop.required) "true" else "false");
                try buf.appendSlice(allocator, ",\"description\":\"");
                try appendJsonEscaped(&buf, allocator, prop.description);
                try buf.append(allocator, '}');
            }
            try buf.appendSlice(allocator, "]}");
        } else {
            try buf.appendSlice(allocator, ",\"request_body\":null");
        }

        try buf.append(allocator, '}');
        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    // ── invoke ──────────────────────────────────────────────────────

    /// Resolve, build, auth, gate, and execute one operation.
    fn opInvoke(self: *OpenApiTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const spec_id = root.getString(args, "spec") orelse
            return failOwned(allocator, "Missing 'spec' parameter for invoke");
        const op_id = root.getString(args, "operation_id") orelse
            return failOwned(allocator, "Missing 'operation_id' parameter for invoke");

        const idx = self.findSpecIndex(spec_id) orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "No registered spec with id '{s}'. Use operation='list' to see registered specs.",
                .{spec_id},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        const cfg = self.specs[idx];

        const loaded = self.loadSpec(idx);
        const spec = loaded.spec orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Spec '{s}' could not be loaded: {s}",
                .{ spec_id, loaded.load_error orelse "unknown error" },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        const op = spec.findOperation(op_id) orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Spec '{s}' has no operation '{s}'.",
                .{ spec_id, op_id },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        // ── Step 6: read-only-mode HARD GATE ─────────────────────────
        // A spec declared `mode = .read_only` refuses EVERY write op
        // regardless of agent autonomy. This sits ABOVE the approval
        // engine — it is not negotiable by a `confirm_once` prompt.
        if (cfg.mode == .read_only and !op.isReadOnly()) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Operation '{s}' is a write ({s}) but spec '{s}' is registered read_only. " ++
                    "Write operations are refused regardless of autonomy. The operator must set mode=read_write to allow this.",
                .{ op_id, op.method, spec_id },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Runtime classification: this drives the same approval posture
        // MCP/dynamic tools use. `classifyInvoke` builds the per-call
        // `ToolMetadata`; the dispatcher's `canonicalMetadataForCall`
        // already gives `invoke` a conservative mutating base (so a write
        // gets `confirm_once` in supervised), and this classification is
        // surfaced in the result for observability + parity.
        const call_meta = classifyInvoke(op);

        // ── base URL ─────────────────────────────────────────────────
        const base_url = if (cfg.base_url.len > 0) cfg.base_url else spec.server_url;
        if (base_url.len == 0) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Spec '{s}' has no server URL and no base_url override; cannot build a request.",
                .{spec_id},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        if (!std.mem.startsWith(u8, base_url, "https://")) {
            return failOwned(allocator, "Only https:// base URLs are allowed for OpenAPI invoke");
        }

        // ── serialize the body object → JSON ─────────────────────────
        var body_json: ?[]const u8 = null;
        defer if (body_json) |b| allocator.free(b);
        if (root.getValue(args, "body")) |body_val| {
            if (body_val == .object) {
                body_json = std.json.Stringify.valueAlloc(allocator, body_val, .{}) catch
                    return failOwned(allocator, "Failed to serialize 'body' to JSON");
            }
        }

        // ── build the un-authenticated request skeleton ──────────────
        const path_params: ?std.json.ObjectMap = blk: {
            const v = root.getValue(args, "path_params") orelse break :blk null;
            break :blk if (v == .object) v.object else null;
        };
        const query: ?std.json.ObjectMap = blk: {
            const v = root.getValue(args, "query") orelse break :blk null;
            break :blk if (v == .object) v.object else null;
        };

        const built = openapi.build(allocator, op, .{
            .base_url = base_url,
            .path_params = path_params,
            .query = query,
            .body_json = body_json,
        }) catch |err| {
            const msg = try buildErrorMessage(allocator, op_id, err);
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer built.deinit(allocator);

        // ── Step 5: resolve + inject auth (BEFORE any network I/O) ───
        // Auth resolution is pure (env-var read + string construction).
        // Doing it before SSRF resolution means an unsupported scheme or
        // a missing credential fails fast — no DNS lookup, no HTTP. The
        // credential material lives only in the constructed header /
        // query value; it is NEVER written to tool output, logs, or the
        // model context.
        var header_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (header_list.items) |h| allocator.free(h);
            header_list.deinit(allocator);
        }
        // Copy the builder's (non-secret) headers first.
        for (built.headers) |h| {
            try header_list.append(allocator, try allocator.dupe(u8, h));
        }

        // The URL may need an auth query parameter appended.
        var final_url: []const u8 = built.url;
        var final_url_owned: ?[]const u8 = null;
        defer if (final_url_owned) |u| allocator.free(u);

        if (cfg.auth_ref.len > 0) {
            const auth_result = try applyAuth(allocator, spec, op, cfg, &header_list, built.url);
            switch (auth_result) {
                .ok => |maybe_url| {
                    if (maybe_url) |u| {
                        final_url_owned = u;
                        final_url = u;
                    }
                },
                .err => |msg| return ToolResult{ .success = false, .output = "", .error_msg = msg },
            }
        }

        // ── SSRF-safe egress: resolve + pin DNS exactly like http_request ─
        const uri = std.Uri.parse(final_url) catch
            return failOwned(allocator, "Built an invalid request URL");
        const resolved_port: u16 = uri.port orelse 443;
        const host = net_security.extractHost(final_url) orelse
            return failOwned(allocator, "Built request URL has no extractable host");
        const connect_host = net_security.resolveConnectHost(allocator, host, resolved_port) catch |err| switch (err) {
            error.LocalAddressBlocked => return failOwned(allocator, "Blocked: built request resolves to a local/private host"),
            else => return failOwned(allocator, "Unable to verify request host safety"),
        };
        defer allocator.free(connect_host);
        const authority_host = stripBrackets(host);

        // ── execute the HTTP request ─────────────────────────────────
        const response = http_util.request_with_mode(
            allocator,
            .{ .mode = .curl_only },
            .{
                .method = built.method,
                .url = final_url,
                .headers = header_list.items,
                .body = built.body,
                .timeout_ms = HTTP_TIMEOUT_MS,
                .subsystem = .tools,
                .resolve_host = authority_host,
                .resolve_port = resolved_port,
                .connect_host = connect_host,
            },
        ) catch |err| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "OpenAPI invoke of '{s}' failed: {s}",
                .{ op_id, @errorName(err) },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(response.body);

        // ── build the response (capped) ──────────────────────────────
        const truncated = response.body.len > MAX_RESPONSE_BYTES;
        const body_view = if (truncated) response.body[0..MAX_RESPONSE_BYTES] else response.body;
        const status_ok = response.status_code >= 200 and response.status_code < 300;

        const classification = if (call_meta.flags.read_only) "read_only" else "mutating";
        const output = try std.fmt.allocPrint(
            allocator,
            "Spec: {s}\nOperation: {s} ({s} {s})\nClassification: {s}\nStatus: {d}{s}\n\nResponse Body:\n{s}",
            .{
                spec_id,
                op_id,
                built.method,
                op.path,
                classification,
                response.status_code,
                if (truncated) " (response truncated)" else "",
                body_view,
            },
        );

        if (status_ok) {
            return ToolResult{ .success = true, .output = output };
        }
        const err_msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{response.status_code});
        return ToolResult{ .success = false, .output = output, .error_msg = err_msg };
    }

    // ── Step 5 helpers: auth resolution + injection ──────────────────

    const AuthResult = union(enum) {
        /// Auth applied. Carries an optional rewritten URL (when the
        /// credential goes in a query parameter).
        ok: ?[]const u8,
        /// Auth could not be applied. Carries an owned error message.
        err: []const u8,
    };

    /// Resolve the credential for `cfg.auth_ref` from the environment and
    /// inject it per the operation's effective security scheme.
    ///
    /// The credential is read into a buffer that is freed before this
    /// returns; only the *constructed header / query value* (which the
    /// builder anyway needs to send) carries it onward. It is never
    /// logged and never placed in tool output.
    fn applyAuth(
        allocator: std.mem.Allocator,
        spec: openapi.Spec,
        op: openapi.Operation,
        cfg: ApiSpecConfig,
        header_list: *std.ArrayListUnmanaged([]const u8),
        url: []const u8,
    ) !AuthResult {
        // Pick the operation's effective security scheme. V1 uses the
        // first scheme the operation declares that the spec defines.
        var scheme: ?openapi.SecurityScheme = null;
        for (op.security_scheme_names) |name| {
            if (spec.findSecurityScheme(name)) |s| {
                scheme = s;
                break;
            }
        }
        const sec = scheme orelse {
            // Operation declares no usable scheme. The operator set an
            // auth_ref anyway — fall back to a bearer token, the most
            // common default for unspecified-scheme APIs.
            return applyBearerFallback(allocator, cfg.auth_ref, header_list);
        };

        if (!sec.isSupported()) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Security scheme '{s}' (kind={s}) is not supported in V1: OAuth2 not supported. " ++
                    "Use an api_key or http bearer/basic scheme.",
                .{ sec.name, @tagName(sec.kind) },
            );
            return .{ .err = msg };
        }

        // Resolve the credential from the env var named by auth_ref.
        const cred = std.process.getEnvVarOwned(allocator, cfg.auth_ref) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Credential env var '{s}' (auth_ref) is not set. The operator must export it before invoke.",
                    .{cfg.auth_ref},
                );
                return .{ .err = msg };
            },
            else => return .{ .err = try allocator.dupe(u8, "Failed to read credential env var") },
        };
        defer freeSecret(allocator, cred);

        switch (sec.kind) {
            .api_key => {
                if (sec.api_key_name.len == 0) {
                    return .{ .err = try allocator.dupe(u8, "apiKey scheme has no key name in the spec") };
                }
                switch (sec.api_key_in) {
                    .header => {
                        const hdr = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ sec.api_key_name, cred });
                        try header_list.append(allocator, hdr);
                        return .{ .ok = null };
                    },
                    .query => {
                        const new_url = try appendQueryParam(allocator, url, sec.api_key_name, cred);
                        return .{ .ok = new_url };
                    },
                    .cookie => {
                        const hdr = try std.fmt.allocPrint(allocator, "Cookie: {s}={s}", .{ sec.api_key_name, cred });
                        try header_list.append(allocator, hdr);
                        return .{ .ok = null };
                    },
                    .path => {
                        return .{ .err = try allocator.dupe(u8, "apiKey in 'path' is not supported") };
                    },
                }
            },
            .http => {
                if (std.ascii.eqlIgnoreCase(sec.http_scheme, "bearer")) {
                    const hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{cred});
                    try header_list.append(allocator, hdr);
                    return .{ .ok = null };
                } else if (std.ascii.eqlIgnoreCase(sec.http_scheme, "basic")) {
                    const encoder = std.base64.standard.Encoder;
                    const enc_len = encoder.calcSize(cred.len);
                    const enc_buf = try allocator.alloc(u8, enc_len);
                    defer freeSecret(allocator, enc_buf);
                    _ = encoder.encode(enc_buf, cred);
                    const hdr = try std.fmt.allocPrint(allocator, "Authorization: Basic {s}", .{enc_buf});
                    try header_list.append(allocator, hdr);
                    return .{ .ok = null };
                }
                return .{ .err = try allocator.dupe(u8, "http scheme is neither bearer nor basic") };
            },
            else => {
                return .{ .err = try std.fmt.allocPrint(
                    allocator,
                    "Security scheme kind '{s}' is not supported in V1: OAuth2 not supported.",
                    .{@tagName(sec.kind)},
                ) };
            },
        }
    }

    /// When an operation declares no usable scheme but the operator set an
    /// auth_ref, default to bearer (the dominant convention).
    fn applyBearerFallback(
        allocator: std.mem.Allocator,
        auth_ref: []const u8,
        header_list: *std.ArrayListUnmanaged([]const u8),
    ) !AuthResult {
        const cred = std.process.getEnvVarOwned(allocator, auth_ref) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Credential env var '{s}' (auth_ref) is not set. The operator must export it before invoke.",
                    .{auth_ref},
                );
                return .{ .err = msg };
            },
            else => return .{ .err = try allocator.dupe(u8, "Failed to read credential env var") },
        };
        defer freeSecret(allocator, cred);

        const hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{cred});
        try header_list.append(allocator, hdr);
        return .{ .ok = null };
    }

    // ── Step 3 helpers: lazy registry ────────────────────────────────

    fn findSpecIndex(self: *OpenApiTool, id: []const u8) ?usize {
        for (self.specs, 0..) |cfg, idx| {
            if (std.mem.eql(u8, cfg.id, id)) return idx;
        }
        return null;
    }

    /// Lazy-load + cache the spec for slot `idx`. On the first call it
    /// fetches (URL or file), parses, and caches the `Spec` in the slot
    /// arena. Subsequent calls return the cached slot. A failed load is
    /// recorded once and not retried — `loaded` stays true.
    fn loadSpec(self: *OpenApiTool, idx: usize) *SpecSlot {
        const slot = &self.slots[idx];
        if (slot.loaded) return slot;
        slot.loaded = true;

        const cfg = self.specs[idx];
        const arena_alloc = slot.arena.allocator();

        // Exactly one of spec_url / spec_path must be set.
        if (cfg.spec_url.len == 0 and cfg.spec_path.len == 0) {
            slot.load_error = self.dupeSlotError("spec config sets neither spec_url nor spec_path");
            return slot;
        }
        if (cfg.spec_url.len > 0 and cfg.spec_path.len > 0) {
            slot.load_error = self.dupeSlotError("spec config sets both spec_url and spec_path; exactly one is allowed");
            return slot;
        }

        const json_bytes: []const u8 = if (cfg.spec_url.len > 0)
            fetchSpecUrl(arena_alloc, cfg.spec_url) catch |err| {
                slot.load_error = self.dupeSlotErrorFmt("failed to fetch spec_url: {s}", .{@errorName(err)});
                return slot;
            }
        else
            readSpecFile(arena_alloc, cfg.spec_path) catch |err| {
                slot.load_error = self.dupeSlotErrorFmt("failed to read spec_path: {s}", .{@errorName(err)});
                return slot;
            };

        const parsed = openapi.parse(arena_alloc, json_bytes) catch |err| {
            slot.load_error = self.dupeSlotErrorFmt("failed to parse OpenAPI spec: {s}", .{@errorName(err)});
            return slot;
        };
        slot.spec = parsed;
        log.info("loaded OpenAPI spec id='{s}' operations={d}", .{ cfg.id, parsed.operations.len });
        return slot;
    }

    fn dupeSlotError(self: *OpenApiTool, msg: []const u8) ?[]const u8 {
        const alloc = self.slot_allocator orelse return null;
        return alloc.dupe(u8, msg) catch null;
    }

    fn dupeSlotErrorFmt(self: *OpenApiTool, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        const alloc = self.slot_allocator orelse return null;
        return std.fmt.allocPrint(alloc, fmt, args) catch null;
    }
};

// ── Free-standing helpers ────────────────────────────────────────────

/// Runtime read/write classification of an `invoke` call (Step 6). GET /
/// HEAD / OPTIONS → a `read_only` metadata; everything else → `mutating`.
/// Mirrors the per-tool metadata MCP/dynamic tools feed to
/// `ApprovalPolicy.forTool`.
pub fn classifyInvoke(op: openapi.Operation) metadata.ToolMetadata {
    if (op.isReadOnly()) {
        return .{
            .name = "openapi",
            .flags = .{ .read_only = true, .concurrency_safe = true },
            .risk_level = .low,
            .cost_class = .b,
        };
    }
    return .{
        .name = "openapi",
        .flags = .{ .mutating = true },
        .risk_level = .high,
        .cost_class = .c,
    };
}

/// Build a failure `ToolResult` whose `error_msg` is heap-allocated (owned
/// by the caller). The `invoke` path uses this everywhere instead of
/// `ToolResult.fail` so callers can free `error_msg` unconditionally —
/// `ToolResult.fail` returns a non-owned literal which is unsafe to free.
fn failOwned(allocator: std.mem.Allocator, msg: []const u8) !ToolResult {
    return ToolResult{
        .success = false,
        .output = "",
        .error_msg = try allocator.dupe(u8, msg),
    };
}

/// Overwrite a credential buffer before freeing so it does not linger in
/// freed heap memory.
fn freeSecret(allocator: std.mem.Allocator, secret: []const u8) void {
    const mutable = @constCast(secret);
    @memset(mutable, 0);
    allocator.free(mutable);
}

fn stripBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

/// Append `name=value` (percent-encoded) to a URL's query string.
fn appendQueryParam(
    allocator: std.mem.Allocator,
    url: []const u8,
    name: []const u8,
    value: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, url);
    try buf.append(allocator, if (std.mem.indexOfScalar(u8, url, '?') != null) '&' else '?');
    try percentEncode(allocator, &buf, name);
    try buf.append(allocator, '=');
    try percentEncode(allocator, &buf, value);
    return buf.toOwnedSlice(allocator);
}

fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        }
    }
}

fn buildErrorMessage(allocator: std.mem.Allocator, op_id: []const u8, err: openapi.request.BuildError) ![]u8 {
    const detail = switch (err) {
        error.MissingRequiredPathParam => "a required path parameter is missing",
        error.MissingRequiredQueryParam => "a required query parameter is missing",
        error.MissingRequiredBody => "the operation requires a request body",
        error.InvalidBaseUrl => "the base URL is invalid",
        error.UnresolvedPathTemplate => "the path template is malformed",
        error.OutOfMemory => "out of memory while building the request",
    };
    return std.fmt.allocPrint(allocator, "Cannot build request for '{s}': {s}", .{ op_id, detail });
}

/// Fetch an OpenAPI spec from an HTTPS URL with SSRF-safe DNS pinning.
fn fetchSpecUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, "https://")) return error.NotHttps;

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const resolved_port: u16 = uri.port orelse 443;
    const host = net_security.extractHost(url) orelse return error.NoHost;
    const connect_host = net_security.resolveConnectHost(allocator, host, resolved_port) catch
        return error.HostUnsafe;
    defer allocator.free(connect_host);
    const authority_host = stripBrackets(host);

    const headers = [_][]const u8{"Accept: application/json"};
    const response = try http_util.request_with_mode(
        allocator,
        .{ .mode = .curl_only },
        .{
            .method = "GET",
            .url = url,
            .headers = &headers,
            .timeout_ms = HTTP_TIMEOUT_MS,
            .subsystem = .tools,
            .resolve_host = authority_host,
            .resolve_port = resolved_port,
            .connect_host = connect_host,
        },
    );
    errdefer allocator.free(response.body);

    if (response.status_code < 200 or response.status_code >= 300) {
        allocator.free(response.body);
        return error.SpecHttpError;
    }
    if (response.body.len > MAX_SPEC_BYTES) {
        allocator.free(response.body);
        return error.SpecTooLarge;
    }
    return response.body;
}

/// Read an OpenAPI spec from a local file.
fn readSpecFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileOpenFailed;
    defer file.close();
    const bytes = file.readToEndAlloc(allocator, MAX_SPEC_BYTES) catch |err| switch (err) {
        error.FileTooBig => return error.SpecTooLarge,
        else => return error.FileReadFailed,
    };
    return bytes;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// libc env-var setters — `std.c` in Zig 0.15.2 does not surface these.
// Used only by the auth tests to install a credential hermetically so
// `applyAuth`'s `getEnvVarOwned` path is exercised end to end.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const TEST_SPEC =
    \\{
    \\  "openapi": "3.0.3",
    \\  "info": { "title": "Test API", "version": "1.0.0" },
    \\  "servers": [ { "url": "https://api.example.com/v1" } ],
    \\  "security": [ { "ApiKeyAuth": [] } ],
    \\  "components": {
    \\    "securitySchemes": {
    \\      "ApiKeyAuth": { "type": "apiKey", "in": "header", "name": "X-Api-Key" },
    \\      "BearerAuth": { "type": "http", "scheme": "bearer" },
    \\      "BasicAuth": { "type": "http", "scheme": "basic" },
    \\      "QueryKey": { "type": "apiKey", "in": "query", "name": "api_key" },
    \\      "OAuthScheme": { "type": "oauth2", "flows": {} }
    \\    }
    \\  },
    \\  "paths": {
    \\    "/items/{id}": {
    \\      "get": {
    \\        "operationId": "getItem",
    \\        "summary": "Fetch an item",
    \\        "parameters": [
    \\          { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "responses": { "200": { "description": "ok" } }
    \\      },
    \\      "delete": {
    \\        "operationId": "deleteItem",
    \\        "parameters": [
    \\          { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "responses": { "204": { "description": "gone" } }
    \\      }
    \\    },
    \\    "/items": {
    \\      "post": {
    \\        "operationId": "createItem",
    \\        "security": [ { "BearerAuth": [] } ],
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": { "application/json": { "schema": {
    \\            "type": "object",
    \\            "required": ["name"],
    \\            "properties": { "name": { "type": "string" } }
    \\          } } }
    \\        },
    \\        "responses": { "201": { "description": "created" } }
    \\      }
    \\    }
    \\  }
    \\}
;

/// Build a tool over an in-memory spec file written to a temp path.
fn writeTempSpec(dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    try dir.dir.writeFile(.{ .sub_path = name, .data = TEST_SPEC });
    return name;
}

test "tool name and schema" {
    var t = OpenApiTool{};
    const tl = t.tool();
    try testing.expectEqualStrings("openapi", tl.name());
    try testing.expect(tl.description().len > 0);
    const schema = tl.parametersJson();
    try testing.expect(std.mem.indexOf(u8, schema, "operation") != null);
    try testing.expect(std.mem.indexOf(u8, schema, "invoke") != null);
}

test "list with no specs returns clear message" {
    var t = OpenApiTool{};
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const tl = t.tool();
    const parsed = try root.parseTestArgs("{\"operation\":\"list\"}");
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    try testing.expect(res.success);
    try testing.expect(std.mem.indexOf(u8, res.output, "No API specs") != null);
}

test "unknown operation is rejected" {
    var t = OpenApiTool{};
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const tl = t.tool();
    const parsed = try root.parseTestArgs("{\"operation\":\"bogus\"}");
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    defer if (res.output.len > 0) testing.allocator.free(res.output);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.error_msg.?, "Unknown operation") != null);
}

test "lazy load + cache from spec_path; list shows operations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = try writeTempSpec(tmp, "spec.json");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, name);
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "testapi", .spec_path = abs_path, .mode = .read_only },
    };
    var t = OpenApiTool{ .specs = &specs };
    try t.initSlots(testing.allocator);
    defer t.deinitState();

    // First load triggers a parse.
    const slot1 = t.loadSpec(0);
    try testing.expect(slot1.spec != null);
    try testing.expect(slot1.loaded);
    const ptr_after_first = slot1.spec.?.operations.ptr;

    // Second load returns the SAME cached slot (no re-parse).
    const slot2 = t.loadSpec(0);
    try testing.expectEqual(ptr_after_first, slot2.spec.?.operations.ptr);

    const tl = t.tool();
    const parsed = try root.parseTestArgs("{\"operation\":\"list\"}");
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    defer testing.allocator.free(res.output);
    try testing.expect(res.success);
    try testing.expect(std.mem.indexOf(u8, res.output, "testapi") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "getItem") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "createItem") != null);
}

test "describe surfaces parameters and body shape" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = try writeTempSpec(tmp, "spec.json");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, name);
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "testapi", .spec_path = abs_path, .mode = .read_write },
    };
    var t = OpenApiTool{ .specs = &specs };
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const tl = t.tool();

    const parsed = try root.parseTestArgs(
        "{\"operation\":\"describe\",\"spec\":\"testapi\",\"operation_id\":\"createItem\"}",
    );
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    defer testing.allocator.free(res.output);
    try testing.expect(res.success);
    try testing.expect(std.mem.indexOf(u8, res.output, "createItem") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "request_body") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "\"read_only\":false") != null);
}

test "describe of unknown spec id errors clearly" {
    var t = OpenApiTool{};
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const tl = t.tool();
    const parsed = try root.parseTestArgs(
        "{\"operation\":\"describe\",\"spec\":\"nope\",\"operation_id\":\"x\"}",
    );
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.error_msg.?, "No registered spec") != null);
}

test "bad spec path fails soft, never crashes" {
    const specs = [_]ApiSpecConfig{
        .{ .id = "broken", .spec_path = "/nonexistent/path/to/spec.json", .mode = .read_only },
    };
    var t = OpenApiTool{ .specs = &specs };
    try t.initSlots(testing.allocator);
    defer t.deinitState();

    const slot = t.loadSpec(0);
    try testing.expect(slot.spec == null);
    try testing.expect(slot.loaded);
    try testing.expect(slot.load_error != null);

    // describe over the broken spec returns a clean tool error.
    const tl = t.tool();
    const parsed = try root.parseTestArgs(
        "{\"operation\":\"describe\",\"spec\":\"broken\",\"operation_id\":\"x\"}",
    );
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.error_msg.?, "could not be loaded") != null);
}

test "spec config with both spec_url and spec_path fails soft" {
    const specs = [_]ApiSpecConfig{
        .{ .id = "ambig", .spec_url = "https://x.test/s.json", .spec_path = "/tmp/s.json" },
    };
    var t = OpenApiTool{ .specs = &specs };
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const slot = t.loadSpec(0);
    try testing.expect(slot.spec == null);
    try testing.expect(slot.load_error != null);
    try testing.expect(std.mem.indexOf(u8, slot.load_error.?, "both") != null);
}

test "read_only mode HARD-GATES write operations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = try writeTempSpec(tmp, "spec.json");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, name);
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "ro", .spec_path = abs_path, .mode = .read_only },
    };
    var t = OpenApiTool{ .specs = &specs };
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const tl = t.tool();

    // DELETE on a read_only spec must be refused BEFORE any HTTP.
    const parsed = try root.parseTestArgs(
        "{\"operation\":\"invoke\",\"spec\":\"ro\",\"operation_id\":\"deleteItem\"," ++
            "\"path_params\":{\"id\":\"abc\"}}",
    );
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    defer if (res.output.len > 0) testing.allocator.free(res.output);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.error_msg.?, "read_only") != null);
    try testing.expect(std.mem.indexOf(u8, res.error_msg.?, "refused") != null);
}

test "classifyInvoke read vs write" {
    const get_op = openapi.Operation{ .operation_id = "g", .method = "GET", .path = "/x" };
    const post_op = openapi.Operation{ .operation_id = "p", .method = "POST", .path = "/x" };
    const head_op = openapi.Operation{ .operation_id = "h", .method = "HEAD", .path = "/x" };

    const gm = classifyInvoke(get_op);
    try testing.expect(gm.flags.read_only);
    try testing.expect(!gm.flags.mutating);

    const pm = classifyInvoke(post_op);
    try testing.expect(pm.flags.mutating);
    try testing.expect(!pm.flags.read_only);

    const hm = classifyInvoke(head_op);
    try testing.expect(hm.flags.read_only);
}

/// Build an OpenApiTool over an in-memory spec for an auth test, returning
/// the loaded `Spec`. Caller must `t.deinitState()`.
fn loadTestSpecTool(t: *OpenApiTool, tmp: std.testing.TmpDir, specs: []const ApiSpecConfig) !openapi.Spec {
    _ = tmp;
    t.* = .{ .specs = specs };
    try t.initSlots(testing.allocator);
    const slot = t.loadSpec(0);
    return slot.spec orelse error.SpecLoadFailed;
}

test "applyAuth — api_key in header injects the key header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = try writeTempSpec(tmp, "spec.json");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, name);
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "api", .spec_path = abs_path, .auth_ref = "OPENAPI_AUTH_TEST_HDR", .mode = .read_only },
    };
    var t: OpenApiTool = undefined;
    const spec = try loadTestSpecTool(&t, tmp, &specs);
    defer t.deinitState();

    _ = setenv("OPENAPI_AUTH_TEST_HDR", "secret-cred", 1);
    defer _ = unsetenv("OPENAPI_AUTH_TEST_HDR");

    const op = spec.findOperation("getItem").?; // doc-level ApiKeyAuth (header)
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (headers.items) |h| testing.allocator.free(h);
        headers.deinit(testing.allocator);
    }
    const res = try OpenApiTool.applyAuth(testing.allocator, spec, op, specs[0], &headers, "https://api.example.com/v1/items/x");
    switch (res) {
        .ok => |url| try testing.expect(url == null), // header mode — no URL rewrite
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqual(@as(usize, 1), headers.items.len);
    try testing.expectEqualStrings("X-Api-Key: secret-cred", headers.items[0]);
}

test "applyAuth — http bearer injects Authorization: Bearer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = try writeTempSpec(tmp, "spec.json");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, name);
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "api", .spec_path = abs_path, .auth_ref = "OPENAPI_AUTH_TEST_BEARER", .mode = .read_write },
    };
    var t: OpenApiTool = undefined;
    const spec = try loadTestSpecTool(&t, tmp, &specs);
    defer t.deinitState();

    _ = setenv("OPENAPI_AUTH_TEST_BEARER", "tok-123", 1);
    defer _ = unsetenv("OPENAPI_AUTH_TEST_BEARER");

    const op = spec.findOperation("createItem").?; // operation override → BearerAuth
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (headers.items) |h| testing.allocator.free(h);
        headers.deinit(testing.allocator);
    }
    const res = try OpenApiTool.applyAuth(testing.allocator, spec, op, specs[0], &headers, "https://api.example.com/v1/items");
    switch (res) {
        .ok => {},
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqual(@as(usize, 1), headers.items.len);
    try testing.expectEqualStrings("Authorization: Bearer tok-123", headers.items[0]);
}

test "applyAuth — http basic base64-encodes the credential" {
    // A spec whose operation's only scheme is BasicAuth.
    const basic_spec =
        \\{
        \\  "openapi": "3.0.0",
        \\  "servers": [ { "url": "https://api.example.com" } ],
        \\  "security": [ { "BasicAuth": [] } ],
        \\  "components": { "securitySchemes": {
        \\    "BasicAuth": { "type": "http", "scheme": "basic" }
        \\  }},
        \\  "paths": { "/x": { "get": { "operationId": "getX", "responses": {} } } }
        \\}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "basic.json", .data = basic_spec });
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "basic.json");
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "basicapi", .spec_path = abs_path, .auth_ref = "OPENAPI_AUTH_TEST_BASIC", .mode = .read_only },
    };
    var t: OpenApiTool = undefined;
    const spec = try loadTestSpecTool(&t, tmp, &specs);
    defer t.deinitState();

    _ = setenv("OPENAPI_AUTH_TEST_BASIC", "user:pass", 1);
    defer _ = unsetenv("OPENAPI_AUTH_TEST_BASIC");

    const op = spec.findOperation("getX").?;
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (headers.items) |h| testing.allocator.free(h);
        headers.deinit(testing.allocator);
    }
    const res = try OpenApiTool.applyAuth(testing.allocator, spec, op, specs[0], &headers, "https://api.example.com/x");
    switch (res) {
        .ok => {},
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    }
    // base64("user:pass") == "dXNlcjpwYXNz"
    try testing.expectEqualStrings("Authorization: Basic dXNlcjpwYXNz", headers.items[0]);
}

test "applyAuth — api_key in query rewrites the URL" {
    // A spec whose operation scheme puts the key in the query string.
    const query_spec =
        \\{
        \\  "openapi": "3.0.0",
        \\  "servers": [ { "url": "https://api.example.com" } ],
        \\  "security": [ { "QueryKey": [] } ],
        \\  "components": { "securitySchemes": {
        \\    "QueryKey": { "type": "apiKey", "in": "query", "name": "api_key" }
        \\  }},
        \\  "paths": { "/x": { "get": { "operationId": "getX", "responses": {} } } }
        \\}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "query.json", .data = query_spec });
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "query.json");
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "queryapi", .spec_path = abs_path, .auth_ref = "OPENAPI_AUTH_TEST_QUERY", .mode = .read_only },
    };
    var t: OpenApiTool = undefined;
    const spec = try loadTestSpecTool(&t, tmp, &specs);
    defer t.deinitState();

    _ = setenv("OPENAPI_AUTH_TEST_QUERY", "qk-9", 1);
    defer _ = unsetenv("OPENAPI_AUTH_TEST_QUERY");

    const op = spec.findOperation("getX").?;
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (headers.items) |h| testing.allocator.free(h);
        headers.deinit(testing.allocator);
    }
    const res = try OpenApiTool.applyAuth(testing.allocator, spec, op, specs[0], &headers, "https://api.example.com/x");
    switch (res) {
        .ok => |maybe_url| {
            const url = maybe_url orelse return error.TestUnexpectedResult;
            defer testing.allocator.free(url);
            try testing.expectEqualStrings("https://api.example.com/x?api_key=qk-9", url);
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    }
    // No header was added — the key went in the query string.
    try testing.expectEqual(@as(usize, 0), headers.items.len);
}

test "applyAuth — missing credential env var yields a clear error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = try writeTempSpec(tmp, "spec.json");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, name);
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "api", .spec_path = abs_path, .auth_ref = "OPENAPI_AUTH_TEST_MISSING_XYZ", .mode = .read_only },
    };
    var t: OpenApiTool = undefined;
    const spec = try loadTestSpecTool(&t, tmp, &specs);
    defer t.deinitState();

    // Ensure the var is genuinely absent.
    _ = unsetenv("OPENAPI_AUTH_TEST_MISSING_XYZ");

    const op = spec.findOperation("getItem").?;
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (headers.items) |h| testing.allocator.free(h);
        headers.deinit(testing.allocator);
    }
    const res = try OpenApiTool.applyAuth(testing.allocator, spec, op, specs[0], &headers, "https://api.example.com/v1/items/x");
    switch (res) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "not set") != null);
        },
    }
}

test "appendQueryParam adds api key to query string" {
    const url1 = try appendQueryParam(testing.allocator, "https://api.test/x", "api_key", "k v");
    defer testing.allocator.free(url1);
    try testing.expectEqualStrings("https://api.test/x?api_key=k%20v", url1);

    const url2 = try appendQueryParam(testing.allocator, "https://api.test/x?page=1", "api_key", "abc");
    defer testing.allocator.free(url2);
    try testing.expectEqualStrings("https://api.test/x?page=1&api_key=abc", url2);
}

test "invoke rejects unsupported oauth2 scheme" {
    // A spec where the operation's only scheme is oauth2.
    const oauth_spec =
        \\{
        \\  "openapi": "3.0.0",
        \\  "servers": [ { "url": "https://api.example.com" } ],
        \\  "security": [ { "OAuthScheme": [] } ],
        \\  "components": { "securitySchemes": {
        \\    "OAuthScheme": { "type": "oauth2", "flows": {} }
        \\  }},
        \\  "paths": { "/x": { "get": { "operationId": "getX", "responses": {} } } }
        \\}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "oauth.json", .data = oauth_spec });
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "oauth.json");
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "oauthapi", .spec_path = abs_path, .auth_ref = "OPENAPI_TEST_KEY", .mode = .read_only },
    };
    var t = OpenApiTool{ .specs = &specs };
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const tl = t.tool();

    const parsed = try root.parseTestArgs(
        "{\"operation\":\"invoke\",\"spec\":\"oauthapi\",\"operation_id\":\"getX\"}",
    );
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    defer if (res.output.len > 0) testing.allocator.free(res.output);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.error_msg.?, "OAuth2 not supported") != null);
}

test "invoke of unknown operation id errors clearly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = try writeTempSpec(tmp, "spec.json");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, name);
    defer testing.allocator.free(abs_path);

    const specs = [_]ApiSpecConfig{
        .{ .id = "api", .spec_path = abs_path, .mode = .read_write },
    };
    var t = OpenApiTool{ .specs = &specs };
    try t.initSlots(testing.allocator);
    defer t.deinitState();
    const tl = t.tool();

    const parsed = try root.parseTestArgs(
        "{\"operation\":\"invoke\",\"spec\":\"api\",\"operation_id\":\"doesNotExist\"}",
    );
    defer parsed.deinit();
    const res = try tl.execute(testing.allocator, parsed.value.object);
    defer if (res.error_msg) |e| testing.allocator.free(e);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.error_msg.?, "no operation") != null);
}

test "deinitState is idempotent" {
    var t = OpenApiTool{};
    try t.initSlots(testing.allocator);
    t.deinitState();
    t.deinitState(); // second call must be a no-op, not a double-free
}
