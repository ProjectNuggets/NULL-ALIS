const std = @import("std");

pub const Mode = enum {
    native_with_xml_fallback,
    native_strict_canary,
    xml_full,
    no_tools,

    pub fn toSlice(self: Mode) []const u8 {
        return switch (self) {
            .native_with_xml_fallback => "native_with_xml_fallback",
            .native_strict_canary => "native_strict_canary",
            .xml_full => "xml_full",
            .no_tools => "no_tools",
        };
    }
};

pub const Plan = struct {
    mode: Mode = .no_tools,
    provider_supports_native_tools: bool = false,
    native_tool_count: usize = 0,
    prompt_tool_catalog_present: bool = false,
    xml_tool_catalog_present: bool = false,
    xml_fallback_protocol_present: bool = false,
    native_tool_schemas_present: bool = false,
    native_strict_canary: bool = false,

    pub fn sendsNativeTools(self: Plan) bool {
        return self.native_tool_schemas_present and self.native_tool_count > 0;
    }

    pub fn hasXmlInstructions(self: Plan) bool {
        return self.xml_tool_catalog_present or self.xml_fallback_protocol_present;
    }
};

pub fn select(provider_supports_native_tools: bool, tool_count: usize) Plan {
    if (tool_count == 0) {
        return .{
            .mode = .no_tools,
            .provider_supports_native_tools = provider_supports_native_tools,
        };
    }

    if (provider_supports_native_tools) {
        if (nativeStrictCanaryEnabled()) {
            return .{
                .mode = .native_strict_canary,
                .provider_supports_native_tools = true,
                .native_tool_count = tool_count,
                .native_tool_schemas_present = true,
                .native_strict_canary = true,
            };
        }
        return .{
            .mode = .native_with_xml_fallback,
            .provider_supports_native_tools = true,
            .native_tool_count = tool_count,
            .xml_fallback_protocol_present = true,
            .native_tool_schemas_present = true,
        };
    }

    return .{
        .mode = .xml_full,
        .provider_supports_native_tools = false,
        .native_tool_count = 0,
        .xml_tool_catalog_present = true,
    };
}

pub fn nativeStrictCanaryEnabled() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "NULLALIS_KIMI_NATIVE_STRICT_CANARY") catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len > 0 and value[0] != '0';
}

test "select chooses no_tools when catalog is empty" {
    const plan = select(true, 0);
    try std.testing.expectEqual(Mode.no_tools, plan.mode);
    try std.testing.expect(!plan.sendsNativeTools());
    try std.testing.expect(!plan.hasXmlInstructions());
}

test "select chooses native with XML fallback for native-capable providers" {
    const plan = select(true, 3);
    try std.testing.expectEqual(Mode.native_with_xml_fallback, plan.mode);
    try std.testing.expect(plan.sendsNativeTools());
    try std.testing.expect(plan.xml_fallback_protocol_present);
    try std.testing.expect(!plan.xml_tool_catalog_present);
    try std.testing.expect(!plan.prompt_tool_catalog_present);
}

test "select chooses full XML for providers without native tools" {
    const plan = select(false, 3);
    try std.testing.expectEqual(Mode.xml_full, plan.mode);
    try std.testing.expect(!plan.sendsNativeTools());
    try std.testing.expect(plan.xml_tool_catalog_present);
    try std.testing.expect(!plan.xml_fallback_protocol_present);
    try std.testing.expect(!plan.prompt_tool_catalog_present);
}

test "select maps provider matrix to provider-bound tool surfaces" {
    const providers = @import("../providers/root.zig");
    const Matrix = struct {
        fn expectPlanForProvider(provider: providers.Provider, expected_mode: Mode) !void {
            const plan = select(provider.supportsNativeTools(), 2);
            try std.testing.expectEqual(expected_mode, plan.mode);
            switch (expected_mode) {
                .native_with_xml_fallback => {
                    try std.testing.expect(plan.provider_supports_native_tools);
                    try std.testing.expect(plan.sendsNativeTools());
                    try std.testing.expect(plan.native_tool_schemas_present);
                    try std.testing.expect(plan.xml_fallback_protocol_present);
                    try std.testing.expect(!plan.xml_tool_catalog_present);
                    try std.testing.expect(!plan.prompt_tool_catalog_present);
                },
                .native_strict_canary => {
                    try std.testing.expect(plan.provider_supports_native_tools);
                    try std.testing.expect(plan.sendsNativeTools());
                    try std.testing.expect(plan.native_tool_schemas_present);
                    try std.testing.expect(!plan.xml_fallback_protocol_present);
                    try std.testing.expect(!plan.xml_tool_catalog_present);
                    try std.testing.expect(!plan.prompt_tool_catalog_present);
                },
                .xml_full => {
                    try std.testing.expect(!plan.provider_supports_native_tools);
                    try std.testing.expect(!plan.sendsNativeTools());
                    try std.testing.expect(!plan.native_tool_schemas_present);
                    try std.testing.expect(!plan.xml_fallback_protocol_present);
                    try std.testing.expect(plan.xml_tool_catalog_present);
                    try std.testing.expect(!plan.prompt_tool_catalog_present);
                },
                .no_tools => return error.UnexpectedProviderMatrixMode,
            }
        }

        const StaticProvider = struct {
            name: []const u8,
            native_tools: bool,

            fn provider(self: *StaticProvider) providers.Provider {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }

            const vtable = providers.Provider.VTable{
                .chatWithSystem = chatWithSystem,
                .chat = chat,
                .supportsNativeTools = supportsNativeTools,
                .getName = getName,
                .deinit = deinit,
            };

            fn chatWithSystem(_: *anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
                return error.NotSupported;
            }

            fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
                return error.NotSupported;
            }

            fn supportsNativeTools(ptr: *anyopaque) bool {
                const self: *StaticProvider = @ptrCast(@alignCast(ptr));
                return self.native_tools;
            }

            fn getName(ptr: *anyopaque) []const u8 {
                const self: *StaticProvider = @ptrCast(@alignCast(ptr));
                return self.name;
            }

            fn deinit(_: *anyopaque) void {}
        };
    };
    const allocator = std.testing.allocator;

    var kimi = providers.compatible.OpenAiCompatibleProvider.init(
        allocator,
        "moonshot",
        "https://api.moonshot.ai/v1",
        "sk-test",
        .bearer,
    );
    kimi.emit_kimi_thinking = true;
    try Matrix.expectPlanForProvider(kimi.provider(), .native_with_xml_fallback);

    var openai = providers.openai.OpenAiProvider.init(allocator, "sk-test");
    try Matrix.expectPlanForProvider(openai.provider(), .native_with_xml_fallback);

    var openrouter = providers.openrouter.OpenRouterProvider.init(allocator, "sk-or-test");
    try Matrix.expectPlanForProvider(openrouter.provider(), .native_with_xml_fallback);

    var anthropic = providers.anthropic.AnthropicProvider.init(allocator, "sk-ant-test", null);
    try Matrix.expectPlanForProvider(anthropic.provider(), .native_with_xml_fallback);

    var ollama = providers.ollama.OllamaProvider.init(allocator, "http://127.0.0.1:11434");
    try Matrix.expectPlanForProvider(ollama.provider(), .xml_full);

    var gemini = providers.gemini.GeminiProvider.init(allocator, "gemini-test");
    try Matrix.expectPlanForProvider(gemini.provider(), .xml_full);

    var cli_provider = Matrix.StaticProvider{ .name = "claude_cli", .native_tools = false };
    try Matrix.expectPlanForProvider(cli_provider.provider(), .xml_full);

    var codex_cli_provider = Matrix.StaticProvider{ .name = "codex_cli", .native_tools = false };
    try Matrix.expectPlanForProvider(codex_cli_provider.provider(), .xml_full);

    var router_native_default = try providers.router.RouterProvider.init(
        allocator,
        &.{"openai"},
        &.{openai.provider()},
        &.{},
        "gpt-4o",
    );
    defer router_native_default.deinit();
    try Matrix.expectPlanForProvider(router_native_default.provider(), .native_with_xml_fallback);

    var router_xml_default = try providers.router.RouterProvider.init(
        allocator,
        &.{"ollama"},
        &.{ollama.provider()},
        &.{},
        "llama3",
    );
    defer router_xml_default.deinit();
    try Matrix.expectPlanForProvider(router_xml_default.provider(), .xml_full);

    var reliable_native = providers.reliable.ReliableProvider.initWithProvider(openai.provider(), 1, 50);
    try Matrix.expectPlanForProvider(reliable_native.provider(), .native_with_xml_fallback);

    var reliable_xml = providers.reliable.ReliableProvider.initWithProvider(ollama.provider(), 1, 50);
    try Matrix.expectPlanForProvider(reliable_xml.provider(), .xml_full);

    const no_tools = select(openai.provider().supportsNativeTools(), 0);
    try std.testing.expectEqual(Mode.no_tools, no_tools.mode);
    try std.testing.expect(!no_tools.sendsNativeTools());
    try std.testing.expect(!no_tools.hasXmlInstructions());
}
