//! OpenAPI 3.x spec model + parser.
//!
//! Sprint 3 — Universal API Connector. This module parses an OpenAPI 3.x
//! JSON document into a pragmatic subset of structured types that the
//! `openapi` tool consumes to build, describe, and invoke HTTP requests.
//!
//! Scope (V1):
//!   - OpenAPI 3.x JSON only (Swagger 2.0 rejected with an explicit error).
//!   - Intra-document `$ref` resolution (`#/components/...`). External
//!     refs are not followed.
//!   - A pragmatic schema subset: enough type info to build + describe
//!     requests, NOT full JSON Schema validation.
//!   - `apiKey` (header/query) and `http` (bearer/basic) security schemes.
//!     `oauth2` / `openIdConnect` are recorded but flagged unsupported so
//!     the tool layer can emit a precise V1-limitation error.
//!
//! Memory ownership: `parse` takes an `std.mem.Allocator` that MUST be an
//! arena (or otherwise bulk-freed). Every slice in the returned `Spec`
//! points into that allocator. The caller frees the whole arena to release
//! the spec — there is no per-field deinit.

const std = @import("std");

// ── Model ───────────────────────────────────────────────────────────

/// Where a parameter is carried in the HTTP request.
pub const ParamLocation = enum {
    path,
    query,
    header,
    cookie,

    pub fn fromSlice(s: []const u8) ?ParamLocation {
        if (std.mem.eql(u8, s, "path")) return .path;
        if (std.mem.eql(u8, s, "query")) return .query;
        if (std.mem.eql(u8, s, "header")) return .header;
        if (std.mem.eql(u8, s, "cookie")) return .cookie;
        return null;
    }

    pub fn toSlice(self: ParamLocation) []const u8 {
        return switch (self) {
            .path => "path",
            .query => "query",
            .header => "header",
            .cookie => "cookie",
        };
    }
};

/// A single operation parameter (path / query / header / cookie).
pub const Parameter = struct {
    name: []const u8,
    location: ParamLocation,
    required: bool = false,
    /// JSON Schema `type` of the parameter, e.g. "string", "integer".
    /// Empty when the spec omitted it.
    schema_type: []const u8 = "",
    description: []const u8 = "",
};

/// Pragmatic request-body descriptor. We do not model the full schema —
/// only enough for the agent to know a body is expected, its media type,
/// and a flattened list of top-level object properties when available.
pub const RequestBody = struct {
    required: bool = false,
    media_type: []const u8 = "application/json",
    /// Top-level properties of an `object` body schema, when the spec
    /// provides them inline or via an intra-document `$ref`. May be empty
    /// for free-form bodies.
    properties: []const Parameter = &.{},
};

/// One HTTP operation extracted from `paths`.
pub const Operation = struct {
    operation_id: []const u8,
    /// Uppercased HTTP method: GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS.
    method: []const u8,
    /// The templated path, e.g. `/users/{id}`.
    path: []const u8,
    summary: []const u8 = "",
    description: []const u8 = "",
    parameters: []const Parameter = &.{},
    request_body: ?RequestBody = null,
    /// Names of security schemes that apply to this operation (the operation
    /// `security` override, else the document-level `security`). Empty means
    /// the operation is unauthenticated.
    security_scheme_names: []const []const u8 = &.{},

    /// True for side-effect-free HTTP methods. Drives read/write
    /// classification at invoke-time.
    pub fn isReadOnly(self: Operation) bool {
        return std.mem.eql(u8, self.method, "GET") or
            std.mem.eql(u8, self.method, "HEAD") or
            std.mem.eql(u8, self.method, "OPTIONS");
    }
};

/// Security scheme kind. Only `api_key` and `http` are usable in V1.
pub const SecuritySchemeKind = enum {
    api_key,
    http,
    oauth2,
    open_id_connect,
    unknown,
};

/// A `components.securitySchemes` entry.
pub const SecurityScheme = struct {
    /// The key under `components.securitySchemes`.
    name: []const u8,
    kind: SecuritySchemeKind,
    /// For `api_key`: where the key is carried (`header` or `query`).
    api_key_in: ParamLocation = .header,
    /// For `api_key`: the header / query parameter name.
    api_key_name: []const u8 = "",
    /// For `http`: the scheme, lowercased — `bearer` or `basic`.
    http_scheme: []const u8 = "",

    /// True when V1 can resolve + inject this scheme.
    pub fn isSupported(self: SecurityScheme) bool {
        return switch (self.kind) {
            .api_key => true,
            .http => std.ascii.eqlIgnoreCase(self.http_scheme, "bearer") or
                std.ascii.eqlIgnoreCase(self.http_scheme, "basic"),
            else => false,
        };
    }
};

/// A fully-parsed OpenAPI 3.x document.
pub const Spec = struct {
    /// The `openapi` version string from the document, e.g. "3.0.3".
    version: []const u8,
    title: []const u8 = "",
    /// The first `servers[].url`, used as the default base URL. Empty when
    /// the spec omits `servers`; the operator-supplied `base_url` overrides.
    server_url: []const u8 = "",
    operations: []const Operation = &.{},
    security_schemes: []const SecurityScheme = &.{},

    /// Find an operation by its `operationId` (case-sensitive).
    pub fn findOperation(self: Spec, operation_id: []const u8) ?Operation {
        for (self.operations) |op| {
            if (std.mem.eql(u8, op.operation_id, operation_id)) return op;
        }
        return null;
    }

    /// Find a security scheme by name.
    pub fn findSecurityScheme(self: Spec, name: []const u8) ?SecurityScheme {
        for (self.security_schemes) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

pub const ParseError = error{
    InvalidJson,
    NotAnObject,
    MissingOpenApiVersion,
    /// The document declares Swagger 2.0 (`swagger: "2.0"`), which V1 does
    /// not support.
    SwaggerV2NotSupported,
    /// The `openapi` field is present but not a 3.x version.
    UnsupportedOpenApiVersion,
    NoOperations,
} || std.mem.Allocator.Error;

// ── Parser ──────────────────────────────────────────────────────────

const HTTP_METHODS = [_][]const u8{
    "get", "put", "post", "delete", "patch", "head", "options", "trace",
};

/// Parse an OpenAPI 3.x JSON document.
///
/// `allocator` must be an arena: every slice in the returned `Spec` is
/// allocated from it and is freed only by freeing the arena. `parse`
/// itself uses a scratch parse of the raw JSON internally and frees that
/// scratch before returning.
pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) ParseError!Spec {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    // Reject Swagger 2.0 explicitly — it has a different document shape.
    if (root.get("swagger")) |sw| {
        if (sw == .string) return error.SwaggerV2NotSupported;
    }

    const version_val = root.get("openapi") orelse return error.MissingOpenApiVersion;
    const version_str = switch (version_val) {
        .string => |s| s,
        else => return error.MissingOpenApiVersion,
    };
    if (!std.mem.startsWith(u8, version_str, "3.")) {
        return error.UnsupportedOpenApiVersion;
    }

    var spec = Spec{
        .version = try allocator.dupe(u8, version_str),
    };

    // info.title
    if (objGet(root, "info")) |info| {
        if (strField(info, "title")) |t| spec.title = try allocator.dupe(u8, t);
    }

    // servers[0].url
    if (root.get("servers")) |srv| {
        if (srv == .array and srv.array.items.len > 0) {
            const first = srv.array.items[0];
            if (first == .object) {
                if (strField(first.object, "url")) |u| {
                    spec.server_url = try allocator.dupe(u8, u);
                }
            }
        }
    }

    // components.securitySchemes
    var schemes: std.ArrayListUnmanaged(SecurityScheme) = .empty;
    if (objGet(root, "components")) |components| {
        if (objGet(components, "securitySchemes")) |ss| {
            var it = ss.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .object) continue;
                const scheme = try parseSecurityScheme(
                    allocator,
                    entry.key_ptr.*,
                    entry.value_ptr.object,
                );
                try schemes.append(allocator, scheme);
            }
        }
    }
    spec.security_schemes = try schemes.toOwnedSlice(allocator);

    // Document-level default security requirement (list of scheme names).
    const doc_security = try parseSecurityRequirement(allocator, root);

    // paths
    var operations: std.ArrayListUnmanaged(Operation) = .empty;
    if (objGet(root, "paths")) |paths| {
        var path_it = paths.iterator();
        while (path_it.next()) |path_entry| {
            const path_str = path_entry.key_ptr.*;
            if (path_entry.value_ptr.* != .object) continue;
            const path_item = path_entry.value_ptr.object;

            // Path-level parameters apply to every operation under this path.
            const path_params = try parseParameters(allocator, root, path_item);

            for (HTTP_METHODS) |method_lower| {
                const op_val = path_item.get(method_lower) orelse continue;
                if (op_val != .object) continue;
                const op_obj = op_val.object;

                const op = try parseOperation(
                    allocator,
                    root,
                    path_str,
                    method_lower,
                    op_obj,
                    path_params,
                    doc_security,
                );
                try operations.append(allocator, op);
            }
        }
    }
    spec.operations = try operations.toOwnedSlice(allocator);

    if (spec.operations.len == 0) return error.NoOperations;

    return spec;
}

fn parseSecurityScheme(
    allocator: std.mem.Allocator,
    name: []const u8,
    obj: std.json.ObjectMap,
) !SecurityScheme {
    var scheme = SecurityScheme{
        .name = try allocator.dupe(u8, name),
        .kind = .unknown,
    };

    const type_str = strField(obj, "type") orelse "";
    if (std.mem.eql(u8, type_str, "apiKey")) {
        scheme.kind = .api_key;
        if (strField(obj, "in")) |loc| {
            scheme.api_key_in = ParamLocation.fromSlice(loc) orelse .header;
        }
        if (strField(obj, "name")) |n| {
            scheme.api_key_name = try allocator.dupe(u8, n);
        }
    } else if (std.mem.eql(u8, type_str, "http")) {
        scheme.kind = .http;
        if (strField(obj, "scheme")) |s| {
            scheme.http_scheme = try allocator.dupe(u8, s);
        }
    } else if (std.mem.eql(u8, type_str, "oauth2")) {
        scheme.kind = .oauth2;
    } else if (std.mem.eql(u8, type_str, "openIdConnect")) {
        scheme.kind = .open_id_connect;
    }

    return scheme;
}

/// Parse a `security` array (document- or operation-level) into a flat
/// list of scheme names. Each array element is an object whose keys are
/// scheme names; we collect all keys across all alternatives. (V1 does not
/// model OR-alternatives — it just needs the set of schemes that may apply.)
fn parseSecurityRequirement(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) ![]const []const u8 {
    const sec = obj.get("security") orelse return &.{};
    if (sec != .array) return &.{};

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (sec.array.items) |req| {
        if (req != .object) continue;
        var it = req.object.iterator();
        while (it.next()) |entry| {
            // Deduplicate.
            var seen = false;
            for (names.items) |n| {
                if (std.mem.eql(u8, n, entry.key_ptr.*)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        }
    }
    return try names.toOwnedSlice(allocator);
}

fn parseOperation(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    path: []const u8,
    method_lower: []const u8,
    op_obj: std.json.ObjectMap,
    path_params: []const Parameter,
    doc_security: []const []const u8,
) !Operation {
    // operationId: fall back to a synthesized `method_path` id when absent.
    const operation_id = if (strField(op_obj, "operationId")) |id|
        try allocator.dupe(u8, id)
    else
        try synthesizeOperationId(allocator, method_lower, path);

    var method_buf: [16]u8 = undefined;
    const method = try allocator.dupe(u8, std.ascii.upperString(&method_buf, method_lower));

    var op = Operation{
        .operation_id = operation_id,
        .method = method,
        .path = try allocator.dupe(u8, path),
    };

    if (strField(op_obj, "summary")) |s| op.summary = try allocator.dupe(u8, s);
    if (strField(op_obj, "description")) |d| op.description = try allocator.dupe(u8, d);

    // Merge path-level + operation-level parameters. Operation-level wins
    // on (name, location) collision.
    const op_params = try parseParameters(allocator, root, op_obj);
    op.parameters = try mergeParameters(allocator, path_params, op_params);

    // requestBody
    if (op_obj.get("requestBody")) |rb_val| {
        const rb_resolved = try resolveRef(root, rb_val);
        if (rb_resolved == .object) {
            op.request_body = try parseRequestBody(allocator, root, rb_resolved.object);
        }
    }

    // security: operation override, else document-level default.
    const op_security = try parseSecurityRequirement(allocator, op_obj);
    op.security_scheme_names = if (op_obj.get("security") != null)
        op_security
    else
        doc_security;

    return op;
}

fn synthesizeOperationId(
    allocator: std.mem.Allocator,
    method_lower: []const u8,
    path: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(allocator, method_lower);
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buf.append(allocator, c);
        } else if (c == '/' or c == '{' or c == '}' or c == '-' or c == '_') {
            // Collapse separators into a single underscore.
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '_') {
                try buf.append(allocator, '_');
            }
        }
    }
    // Trim a trailing underscore.
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') {
        _ = buf.pop();
    }
    return try buf.toOwnedSlice(allocator);
}

/// Parse a `parameters` array. Each element may be an inline parameter or
/// an intra-document `$ref`.
fn parseParameters(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    obj: std.json.ObjectMap,
) ![]const Parameter {
    const params_val = obj.get("parameters") orelse return &.{};
    if (params_val != .array) return &.{};

    var list: std.ArrayListUnmanaged(Parameter) = .empty;
    for (params_val.array.items) |raw| {
        const resolved = try resolveRef(root, raw);
        if (resolved != .object) continue;
        const p = resolved.object;

        const name = strField(p, "name") orelse continue;
        const loc_str = strField(p, "in") orelse continue;
        const loc = ParamLocation.fromSlice(loc_str) orelse continue;

        var param = Parameter{
            .name = try allocator.dupe(u8, name),
            .location = loc,
            .required = boolField(p, "required") orelse (loc == .path),
        };
        if (strField(p, "description")) |d| param.description = try allocator.dupe(u8, d);

        // Schema type — resolve a $ref'd schema if present.
        if (p.get("schema")) |schema_val| {
            const schema_resolved = try resolveRef(root, schema_val);
            if (schema_resolved == .object) {
                if (strField(schema_resolved.object, "type")) |t| {
                    param.schema_type = try allocator.dupe(u8, t);
                }
            }
        }

        try list.append(allocator, param);
    }
    return try list.toOwnedSlice(allocator);
}

/// Merge path-level params with operation-level params. Operation-level
/// entries win on (name, location) collisions.
fn mergeParameters(
    allocator: std.mem.Allocator,
    path_params: []const Parameter,
    op_params: []const Parameter,
) ![]const Parameter {
    if (path_params.len == 0) return op_params;
    if (op_params.len == 0) return path_params;

    var list: std.ArrayListUnmanaged(Parameter) = .empty;
    try list.appendSlice(allocator, op_params);
    for (path_params) |pp| {
        var overridden = false;
        for (op_params) |op| {
            if (std.mem.eql(u8, op.name, pp.name) and op.location == pp.location) {
                overridden = true;
                break;
            }
        }
        if (!overridden) try list.append(allocator, pp);
    }
    return try list.toOwnedSlice(allocator);
}

fn parseRequestBody(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    rb_obj: std.json.ObjectMap,
) !RequestBody {
    var body = RequestBody{
        .required = boolField(rb_obj, "required") orelse false,
    };

    const content = objGet(rb_obj, "content") orelse return body;

    // Prefer application/json; otherwise take the first media type.
    var media_obj: ?std.json.ObjectMap = null;
    if (content.get("application/json")) |mj| {
        if (mj == .object) {
            media_obj = mj.object;
            body.media_type = "application/json";
        }
    }
    if (media_obj == null) {
        var it = content.iterator();
        if (it.next()) |first| {
            if (first.value_ptr.* == .object) {
                media_obj = first.value_ptr.object;
                body.media_type = try allocator.dupe(u8, first.key_ptr.*);
            }
        }
    }

    const mo = media_obj orelse return body;
    const schema_val = mo.get("schema") orelse return body;
    const schema_resolved = try resolveRef(root, schema_val);
    if (schema_resolved != .object) return body;

    body.properties = try parseSchemaProperties(allocator, root, schema_resolved.object);
    return body;
}

/// Flatten the top-level `properties` of an `object` schema into a list of
/// `Parameter` records (location is meaningless here — we reuse the struct
/// for its name/type/required/description shape).
fn parseSchemaProperties(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    schema: std.json.ObjectMap,
) ![]const Parameter {
    const props_val = schema.get("properties") orelse return &.{};
    if (props_val != .object) return &.{};

    // Required property names.
    var required_names: []const std.json.Value = &.{};
    if (schema.get("required")) |req| {
        if (req == .array) required_names = req.array.items;
    }

    var list: std.ArrayListUnmanaged(Parameter) = .empty;
    var it = props_val.object.iterator();
    while (it.next()) |entry| {
        const prop_resolved = try resolveRef(root, entry.value_ptr.*);
        var param = Parameter{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .location = .query, // unused for body props; placeholder
            .required = false,
        };
        if (prop_resolved == .object) {
            if (strField(prop_resolved.object, "type")) |t| {
                param.schema_type = try allocator.dupe(u8, t);
            }
            if (strField(prop_resolved.object, "description")) |d| {
                param.description = try allocator.dupe(u8, d);
            }
        }
        for (required_names) |rn| {
            if (rn == .string and std.mem.eql(u8, rn.string, entry.key_ptr.*)) {
                param.required = true;
                break;
            }
        }
        try list.append(allocator, param);
    }
    return try list.toOwnedSlice(allocator);
}

// ── $ref resolution ─────────────────────────────────────────────────

/// Resolve an intra-document `$ref`. If `value` is an object with a
/// `$ref` key pointing at `#/...`, walk the JSON pointer from `root` and
/// return the target. External refs (anything not starting with `#/`)
/// and broken pointers return `value` unchanged so the caller degrades
/// gracefully. Bounded to a small depth to defeat ref cycles.
fn resolveRef(root: std.json.ObjectMap, value: std.json.Value) ParseError!std.json.Value {
    var current = value;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        if (current != .object) return current;
        const ref_val = current.object.get("$ref") orelse return current;
        if (ref_val != .string) return current;
        const ref = ref_val.string;
        if (!std.mem.startsWith(u8, ref, "#/")) return current; // external ref — leave as-is

        const target = walkJsonPointer(root, ref[2..]) orelse return current;
        current = target;
    }
    return current; // depth exceeded — likely a cycle; return what we have
}

/// Walk a `/`-separated JSON pointer (already stripped of the leading
/// `#/`) from the document root. Returns null if any segment is missing.
fn walkJsonPointer(root: std.json.ObjectMap, pointer: []const u8) ?std.json.Value {
    var current: std.json.Value = .{ .object = root };
    var it = std.mem.splitScalar(u8, pointer, '/');
    while (it.next()) |raw_segment| {
        if (raw_segment.len == 0) continue;
        // JSON Pointer escaping: ~1 → /, ~0 → ~.
        var seg_buf: [256]u8 = undefined;
        const segment = decodePointerSegment(raw_segment, &seg_buf);
        if (current != .object) return null;
        current = current.object.get(segment) orelse return null;
    }
    return current;
}

fn decodePointerSegment(raw: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw, '~') == null) return raw;
    if (raw.len > buf.len) return raw;
    var i: usize = 0;
    var o: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '~' and i + 1 < raw.len) {
            if (raw[i + 1] == '1') {
                buf[o] = '/';
                i += 2;
                o += 1;
                continue;
            } else if (raw[i + 1] == '0') {
                buf[o] = '~';
                i += 2;
                o += 1;
                continue;
            }
        }
        buf[o] = raw[i];
        i += 1;
        o += 1;
    }
    return buf[0..o];
}

// ── small JSON helpers ──────────────────────────────────────────────

fn objGet(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const SAMPLE_SPEC =
    \\{
    \\  "openapi": "3.0.3",
    \\  "info": { "title": "Pet Store", "version": "1.0.0" },
    \\  "servers": [ { "url": "https://api.example.com/v1" } ],
    \\  "security": [ { "ApiKeyAuth": [] } ],
    \\  "components": {
    \\    "securitySchemes": {
    \\      "ApiKeyAuth": { "type": "apiKey", "in": "header", "name": "X-Api-Key" },
    \\      "BearerAuth": { "type": "http", "scheme": "bearer" }
    \\    },
    \\    "schemas": {
    \\      "Pet": {
    \\        "type": "object",
    \\        "required": ["name"],
    \\        "properties": {
    \\          "name": { "type": "string", "description": "Pet name" },
    \\          "age": { "type": "integer" }
    \\        }
    \\      }
    \\    }
    \\  },
    \\  "paths": {
    \\    "/pets/{petId}": {
    \\      "parameters": [
    \\        { "name": "petId", "in": "path", "required": true, "schema": { "type": "string" } }
    \\      ],
    \\      "get": {
    \\        "operationId": "getPet",
    \\        "summary": "Fetch one pet",
    \\        "responses": { "200": { "description": "ok" } }
    \\      },
    \\      "delete": {
    \\        "operationId": "deletePet",
    \\        "responses": { "204": { "description": "gone" } }
    \\      }
    \\    },
    \\    "/pets": {
    \\      "post": {
    \\        "operationId": "createPet",
    \\        "security": [ { "BearerAuth": [] } ],
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/json": {
    \\              "schema": { "$ref": "#/components/schemas/Pet" }
    \\            }
    \\          }
    \\        },
    \\        "parameters": [
    \\          { "name": "dryRun", "in": "query", "schema": { "type": "boolean" } }
    \\        ],
    \\        "responses": { "201": { "description": "created" } }
    \\      }
    \\    }
    \\  }
    \\}
;

test "parse extracts version, title, server URL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parse(arena.allocator(), SAMPLE_SPEC);
    try testing.expectEqualStrings("3.0.3", spec.version);
    try testing.expectEqualStrings("Pet Store", spec.title);
    try testing.expectEqualStrings("https://api.example.com/v1", spec.server_url);
}

test "parse extracts all operations with methods" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parse(arena.allocator(), SAMPLE_SPEC);
    try testing.expectEqual(@as(usize, 3), spec.operations.len);

    const get_pet = spec.findOperation("getPet") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("GET", get_pet.method);
    try testing.expectEqualStrings("/pets/{petId}", get_pet.path);
    try testing.expect(get_pet.isReadOnly());

    const del = spec.findOperation("deletePet") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("DELETE", del.method);
    try testing.expect(!del.isReadOnly());
}

test "path-level parameters merge into operation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parse(arena.allocator(), SAMPLE_SPEC);
    const get_pet = spec.findOperation("getPet") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), get_pet.parameters.len);
    try testing.expectEqualStrings("petId", get_pet.parameters[0].name);
    try testing.expectEqual(ParamLocation.path, get_pet.parameters[0].location);
    try testing.expect(get_pet.parameters[0].required);
    try testing.expectEqualStrings("string", get_pet.parameters[0].schema_type);
}

test "operation-level parameters parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parse(arena.allocator(), SAMPLE_SPEC);
    const create = spec.findOperation("createPet") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), create.parameters.len);
    try testing.expectEqualStrings("dryRun", create.parameters[0].name);
    try testing.expectEqual(ParamLocation.query, create.parameters[0].location);
    try testing.expect(!create.parameters[0].required);
}

test "requestBody $ref resolves to schema properties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parse(arena.allocator(), SAMPLE_SPEC);
    const create = spec.findOperation("createPet") orelse return error.TestUnexpectedResult;
    const rb = create.request_body orelse return error.TestUnexpectedResult;
    try testing.expect(rb.required);
    try testing.expectEqualStrings("application/json", rb.media_type);
    try testing.expectEqual(@as(usize, 2), rb.properties.len);

    var saw_name_required = false;
    for (rb.properties) |p| {
        if (std.mem.eql(u8, p.name, "name")) {
            try testing.expect(p.required);
            try testing.expectEqualStrings("string", p.schema_type);
            saw_name_required = true;
        }
        if (std.mem.eql(u8, p.name, "age")) {
            try testing.expect(!p.required);
        }
    }
    try testing.expect(saw_name_required);
}

test "security schemes parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parse(arena.allocator(), SAMPLE_SPEC);
    try testing.expectEqual(@as(usize, 2), spec.security_schemes.len);

    const api_key = spec.findSecurityScheme("ApiKeyAuth") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(SecuritySchemeKind.api_key, api_key.kind);
    try testing.expectEqual(ParamLocation.header, api_key.api_key_in);
    try testing.expectEqualStrings("X-Api-Key", api_key.api_key_name);
    try testing.expect(api_key.isSupported());

    const bearer = spec.findSecurityScheme("BearerAuth") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(SecuritySchemeKind.http, bearer.kind);
    try testing.expectEqualStrings("bearer", bearer.http_scheme);
    try testing.expect(bearer.isSupported());
}

test "operation security override beats document default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parse(arena.allocator(), SAMPLE_SPEC);

    // getPet inherits the document-level ApiKeyAuth.
    const get_pet = spec.findOperation("getPet") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), get_pet.security_scheme_names.len);
    try testing.expectEqualStrings("ApiKeyAuth", get_pet.security_scheme_names[0]);

    // createPet overrides with BearerAuth.
    const create = spec.findOperation("createPet") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), create.security_scheme_names.len);
    try testing.expectEqualStrings("BearerAuth", create.security_scheme_names[0]);
}

test "rejects Swagger 2.0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const swagger =
        \\{ "swagger": "2.0", "info": { "title": "old" }, "paths": {} }
    ;
    try testing.expectError(error.SwaggerV2NotSupported, parse(arena.allocator(), swagger));
}

test "rejects missing openapi version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad =
        \\{ "info": { "title": "x" }, "paths": {} }
    ;
    try testing.expectError(error.MissingOpenApiVersion, parse(arena.allocator(), bad));
}

test "rejects non-3.x openapi version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad =
        \\{ "openapi": "4.0.0", "paths": { "/x": { "get": { "operationId": "x" } } } }
    ;
    try testing.expectError(error.UnsupportedOpenApiVersion, parse(arena.allocator(), bad));
}

test "rejects invalid JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidJson, parse(arena.allocator(), "{not json"));
}

test "rejects spec with no operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty =
        \\{ "openapi": "3.0.0", "paths": {} }
    ;
    try testing.expectError(error.NoOperations, parse(arena.allocator(), empty));
}

test "synthesizes operationId when absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec_json =
        \\{ "openapi": "3.0.0", "paths": { "/users/{id}/posts": { "get": { "responses": {} } } } }
    ;
    const spec = try parse(arena.allocator(), spec_json);
    try testing.expectEqual(@as(usize, 1), spec.operations.len);
    try testing.expectEqualStrings("get_users_id_posts", spec.operations[0].operation_id);
}

test "oauth2 scheme parsed but flagged unsupported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec_json =
        \\{
        \\  "openapi": "3.0.0",
        \\  "components": { "securitySchemes": {
        \\    "OAuth": { "type": "oauth2", "flows": {} }
        \\  }},
        \\  "paths": { "/x": { "get": { "operationId": "x" } } }
        \\}
    ;
    const spec = try parse(arena.allocator(), spec_json);
    const oauth = spec.findSecurityScheme("OAuth") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(SecuritySchemeKind.oauth2, oauth.kind);
    try testing.expect(!oauth.isSupported());
}

test "$ref parameter resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec_json =
        \\{
        \\  "openapi": "3.0.0",
        \\  "components": { "parameters": {
        \\    "PageParam": { "name": "page", "in": "query", "schema": { "type": "integer" } }
        \\  }},
        \\  "paths": { "/items": { "get": {
        \\    "operationId": "listItems",
        \\    "parameters": [ { "$ref": "#/components/parameters/PageParam" } ]
        \\  }}}
        \\}
    ;
    const spec = try parse(arena.allocator(), spec_json);
    const op = spec.findOperation("listItems") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), op.parameters.len);
    try testing.expectEqualStrings("page", op.parameters[0].name);
    try testing.expectEqual(ParamLocation.query, op.parameters[0].location);
    try testing.expectEqualStrings("integer", op.parameters[0].schema_type);
}

test "ParamLocation roundtrip" {
    try testing.expectEqual(ParamLocation.path, ParamLocation.fromSlice("path").?);
    try testing.expectEqual(ParamLocation.query, ParamLocation.fromSlice("query").?);
    try testing.expect(ParamLocation.fromSlice("bogus") == null);
    try testing.expectEqualStrings("header", ParamLocation.header.toSlice());
}

test "decodePointerSegment unescapes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a/b", decodePointerSegment("a~1b", &buf));
    try testing.expectEqualStrings("a~b", decodePointerSegment("a~0b", &buf));
    try testing.expectEqualStrings("plain", decodePointerSegment("plain", &buf));
}
