//! OpenAPI module — Sprint 3 Universal API Connector.
//!
//! Pure parsing + request-building primitives for the `openapi` tool.
//! No I/O lives here: spec fetching, auth injection, and HTTP execution
//! all live in `tools/openapi.zig` so that everything in this module is
//! deterministic and unit-testable.

const std = @import("std");

pub const spec = @import("spec.zig");
pub const request = @import("request.zig");

pub const Spec = spec.Spec;
pub const Operation = spec.Operation;
pub const Parameter = spec.Parameter;
pub const RequestBody = spec.RequestBody;
pub const SecurityScheme = spec.SecurityScheme;
pub const SecuritySchemeKind = spec.SecuritySchemeKind;
pub const ParamLocation = spec.ParamLocation;

pub const parse = spec.parse;
pub const build = request.build;
pub const BuiltRequest = request.BuiltRequest;
pub const BuildInput = request.BuildInput;

test {
    std.testing.refAllDecls(@This());
}
