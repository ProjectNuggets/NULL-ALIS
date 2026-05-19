const std = @import("std");
const nullalis = @import("nullalis");
const schema = nullalis.tools.schema;
const provider_helpers = nullalis.providers.helpers;
const openrouter = nullalis.providers.openrouter;

const ToolSpec = nullalis.providers.ToolSpec;

fn expectMissing(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectPresent(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "cleanForProvider gemini removes restrictive unsupported keywords" {
    const cleaned = try schema.cleanForProvider(std.testing.allocator, .gemini,
        \\{"type":"object","properties":{"name":{"type":"string","minLength":1,"format":"email"}},"additionalProperties":false,"$schema":"draft-07","examples":["a"]}
    );
    defer std.testing.allocator.free(cleaned);

    try expectMissing(cleaned, "\"minLength\"");
    try expectMissing(cleaned, "\"format\"");
    try expectMissing(cleaned, "\"additionalProperties\"");
    try expectMissing(cleaned, "\"$schema\"");
    try expectMissing(cleaned, "\"examples\"");
    try expectPresent(cleaned, "\"type\"");
}

test "anthropic tool serialization strips refs but keeps supported constraints" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const tools = &[_]ToolSpec{.{
        .name = "lookup",
        .description = "Resolve an item",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"$ref":"#/$defs/Id"}},"$defs":{"Id":{"type":"string","minLength":1}}}
        ,
    }};

    try provider_helpers.convertToolsAnthropic(&buf, std.testing.allocator, tools);

    try expectMissing(buf.items, "\"$ref\"");
    try expectMissing(buf.items, "\"$defs\"");
    try expectPresent(buf.items, "\"minLength\"");
}

test "openai helper serialization resolves refs before output" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const tools = &[_]ToolSpec{.{
        .name = "lookup",
        .description = "Resolve an item",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"$ref":"#/$defs/Id"}},"$defs":{"Id":{"type":"string","const":"fixed"}}}
        ,
    }};

    try provider_helpers.convertToolsOpenAI(&buf, std.testing.allocator, tools);

    try expectMissing(buf.items, "\"$ref\"");
    try expectPresent(buf.items, "\"enum\"");
}

test "openrouter legacy tool serialization uses openai cleaning strategy" {
    const tools = &[_]ToolSpec{.{
        .name = "lookup",
        .description = "Resolve an item",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"$ref":"#/$defs/Id"}},"$defs":{"Id":{"type":"string","const":"fixed"}}}
        ,
    }};
    const body = try openrouter.OpenRouterProvider.convertTools(std.testing.allocator, tools);
    defer std.testing.allocator.free(body);

    try expectMissing(body, "\"$ref\"");
    try expectPresent(body, "\"enum\"");
}

test "cleanForProvider conservative strips refs and additionalProperties" {
    const cleaned = try schema.cleanForProvider(std.testing.allocator, .conservative,
        \\{"type":"object","properties":{"id":{"$ref":"#/$defs/Id"}},"$defs":{"Id":{"type":"string"}},"additionalProperties":false}
    );
    defer std.testing.allocator.free(cleaned);

    try expectMissing(cleaned, "\"$ref\"");
    try expectMissing(cleaned, "\"$defs\"");
    try expectMissing(cleaned, "\"additionalProperties\"");
    try expectPresent(cleaned, "\"string\"");
}
