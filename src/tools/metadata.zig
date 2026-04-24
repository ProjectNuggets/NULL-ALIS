//! Tool metadata — structured per-tool attributes layered beside the Tool vtable.
//!
//! Each tool struct may declare `pub const tool_metadata: ToolMetadata = .{ ... }`
//! to specify its flags. Tools without declarations receive a conservative default
//! (mutating=true). MCP and dynamically registered tools are handled at runtime via
//! `lookupMetadata()` returning null — callers must apply conservative defaults for
//! unknown tools.
//!
//! This module does NOT modify the Tool.VTable interface. Metadata is resolved
//! by name at the dispatch site, not by function pointer in the vtable.

const std = @import("std");

// ── Core types ──────────────────────────────────────────────────────

/// Per-tool capability flags as a packed struct for efficient storage.
pub const ToolFlags = packed struct {
    read_only: bool = false,
    mutating: bool = false,
    background_safe: bool = false,
    operator_only: bool = false,
    concurrency_safe: bool = false,

    /// Validate that flags are not contradictory.
    pub fn validate(self: ToolFlags) error{ContradictoryFlags}!void {
        if (self.read_only and self.mutating) return error.ContradictoryFlags;
    }
};

/// Risk classification for approval policy integration.
pub const RiskLevel = enum {
    low,
    medium,
    high,
    critical,

    pub fn toSlice(self: RiskLevel) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .critical => "critical",
        };
    }
};

/// Billing cost class per plan-v02 §4.4 — metering input for entitlement
/// enforcement + CostTracker. Distinct from RiskLevel (approval) because
/// some risky tools are cheap (e.g. shell rm vs. list_files — both low/med
/// cost, both high risk) and some safe tools are expensive (e.g. web_search
/// against a paid provider, large composio payload).
///
/// Mapping intent:
///   .a = cheap — local reads, status, runtime_info, memory_* ops, schedule_* ops
///   .b = medium — web search, composio list/read small payload, http_fetch small
///   .c = expensive — large integration payloads, heavy model calls,
///                    image generation, voice synthesis, full-repo shell ops
///
/// Unknown / MCP / dynamic tools default to .b (conservative mid-tier) to
/// avoid accidentally billing as cheap or blocking as expensive when the
/// real profile is unknown.
pub const CostClass = enum {
    a,
    b,
    c,

    pub fn toSlice(self: CostClass) []const u8 {
        return switch (self) {
            .a => "a",
            .b => "b",
            .c => "c",
        };
    }

    /// Nominal weight for aggregating per-turn cost counters.
    /// Concrete $ translation lives on the entitlement side.
    pub fn weight(self: CostClass) u32 {
        return switch (self) {
            .a => 1,
            .b => 5,
            .c => 25,
        };
    }
};

/// Structured metadata for a single tool, resolved at compile time or runtime.
pub const ToolMetadata = struct {
    name: []const u8,
    flags: ToolFlags = .{},
    risk_level: RiskLevel = .low,
    cost_class: CostClass = .b,
    approval_hint: []const u8 = "",

    /// Create a conservative metadata entry for an unknown tool name.
    /// Used as fallback when `lookupMetadata()` returns null.
    pub fn conservative(name: []const u8) ToolMetadata {
        return .{
            .name = name,
            .flags = .{ .mutating = true },
            .risk_level = .high,
            .cost_class = .b,
            .approval_hint = "Unknown tool — conservative policy applied",
        };
    }
};

// ── Comptime metadata extraction ────────────────────────────────────

/// Extract metadata from a tool type at compile time.
/// If T declares `pub const tool_metadata: ToolMetadata`, returns it.
/// Otherwise, returns a conservative default keyed by T.tool_name.
pub fn metadataFor(comptime T: type) ToolMetadata {
    if (@hasDecl(T, "tool_metadata")) {
        return T.tool_metadata;
    }
    return ToolMetadata.conservative(T.tool_name);
}

// ── Runtime lookup ──────────────────────────────────────────────────

/// Look up metadata by tool name at runtime from a provided registry slice.
/// Returns null for tools not in the registry. Callers should use
/// `ToolMetadata.conservative(name)` as fallback when this returns null.
pub fn lookupMetadata(name: []const u8, registry: []const ToolMetadata) ?ToolMetadata {
    for (registry) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "ToolFlags defaults are all false" {
    const flags = ToolFlags{};
    try std.testing.expect(!flags.read_only);
    try std.testing.expect(!flags.mutating);
    try std.testing.expect(!flags.background_safe);
    try std.testing.expect(!flags.operator_only);
    try std.testing.expect(!flags.concurrency_safe);
}

test "ToolMetadata conservative default is mutating" {
    const m = ToolMetadata.conservative("x");
    try std.testing.expect(m.flags.mutating);
    try std.testing.expect(!m.flags.read_only);
    try std.testing.expect(!m.flags.background_safe);
    try std.testing.expectEqual(RiskLevel.high, m.risk_level);
}

test "metadataFor uses declared metadata" {
    const TestTool = struct {
        pub const tool_name = "test_tool";
        pub const tool_metadata: ToolMetadata = .{
            .name = "test_tool",
            .flags = .{ .read_only = true },
        };
    };
    const m = comptime metadataFor(TestTool);
    try std.testing.expect(m.flags.read_only);
    try std.testing.expect(!m.flags.mutating);
    try std.testing.expectEqualStrings("test_tool", m.name);
}

test "metadataFor falls back to conservative" {
    const NoMetaTool = struct {
        pub const tool_name = "bare_tool";
    };
    const m = comptime metadataFor(NoMetaTool);
    try std.testing.expect(m.flags.mutating);
    try std.testing.expect(!m.flags.read_only);
    try std.testing.expectEqualStrings("bare_tool", m.name);
}

test "lookupMetadata finds by name" {
    const reg = [_]ToolMetadata{
        .{ .name = "alpha", .flags = .{ .read_only = true } },
        .{ .name = "beta", .flags = .{ .mutating = true } },
    };
    const found = lookupMetadata("beta", &reg) orelse return error.TestUnexpectedResult;
    try std.testing.expect(found.flags.mutating);
    try std.testing.expectEqualStrings("beta", found.name);
}

test "lookupMetadata returns null for unknown" {
    const reg = [_]ToolMetadata{
        .{ .name = "alpha" },
    };
    try std.testing.expect(lookupMetadata("nonexistent", &reg) == null);
}

test "RiskLevel toSlice returns correct strings" {
    try std.testing.expectEqualStrings("low", RiskLevel.low.toSlice());
    try std.testing.expectEqualStrings("critical", RiskLevel.critical.toSlice());
}

test "CostClass defaults to .b" {
    const m = ToolMetadata{ .name = "x" };
    try std.testing.expectEqual(CostClass.b, m.cost_class);
}

test "CostClass conservative default is .b (mid-tier for unknown)" {
    const m = ToolMetadata.conservative("unknown");
    try std.testing.expectEqual(CostClass.b, m.cost_class);
}

test "CostClass weights reflect nominal ratios" {
    try std.testing.expectEqual(@as(u32, 1), CostClass.a.weight());
    try std.testing.expectEqual(@as(u32, 5), CostClass.b.weight());
    try std.testing.expectEqual(@as(u32, 25), CostClass.c.weight());
}

test "CostClass toSlice" {
    try std.testing.expectEqualStrings("a", CostClass.a.toSlice());
    try std.testing.expectEqualStrings("b", CostClass.b.toSlice());
    try std.testing.expectEqualStrings("c", CostClass.c.toSlice());
}
