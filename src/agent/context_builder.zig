const std = @import("std");
const compaction = @import("compaction.zig");
const context_cache = @import("context_cache.zig");
const context_estimator = @import("context_estimator.zig");
const model_capabilities = @import("model_capabilities.zig");
const prompt = @import("prompt.zig");
const providers = @import("../providers/root.zig");
const tool_surface = @import("tool_surface.zig");

pub const RoleCounts = struct {
    system: usize = 0,
    user: usize = 0,
    assistant: usize = 0,
    tool: usize = 0,
};

pub const ProviderUsage = struct {
    available: bool = false,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,
    total_tokens: u32 = 0,
    cached_prompt_tokens: u32 = 0,
    cache_hit_percent: u8 = 0,
};

pub const ProviderPreflightUsage = struct {
    available: bool = false,
    active: bool = false,
    prompt_tokens: u32 = 0,
    source: []const u8 = "provider_preflight",
};

pub const PressureTokenSource = enum {
    provider_last_usage,
    provider_preflight,
    local_estimate,

    pub fn toSlice(self: PressureTokenSource) []const u8 {
        return switch (self) {
            .provider_last_usage => "provider_last_usage",
            .provider_preflight => "provider_preflight",
            .local_estimate => "local_estimate",
        };
    }
};

pub const PressureSelection = struct {
    token_count: u64,
    source: PressureTokenSource,
};

pub const LastTurnDelta = struct {
    bytes: u64 = 0,
    token_estimate: u64 = 0,
    pressure_points: u8 = 0,
};

pub const PROMPT_BLOCK_LIMIT: usize = 48;
pub const TOOL_SCHEMA_DIAGNOSTIC_LIMIT: usize = 8;
pub const TOOL_SCHEMA_NAME_LIMIT: usize = 64;

pub const PromptBlock = struct {
    name: []const u8 = "",
    bucket: []const u8 = "",
    bytes: u64 = 0,
    token_estimate: u64 = 0,
    hash: u64 = 0,
    active: bool = false,
};

pub const ToolSchemaDiagnostic = struct {
    name: [TOOL_SCHEMA_NAME_LIMIT]u8 = [_]u8{0} ** TOOL_SCHEMA_NAME_LIMIT,
    name_len: usize = 0,
    description_bytes: u64 = 0,
    parameters_bytes: u64 = 0,
    bytes: u64 = 0,
    hash: u64 = 0,
    active: bool = false,

    pub fn nameSlice(self: *const ToolSchemaDiagnostic) []const u8 {
        const limit = @min(self.name_len, self.name.len);
        var end: usize = 0;
        while (end < limit) : (end += 1) {
            if (self.name[end] == 0) break;
        }
        return self.name[0..end];
    }
};

pub const PromptShape = struct {
    available: bool = false,
    method: []const u8 = "provider_request_shape_v1",
    sampled_at_ms: i64 = 0,
    message_count: usize = 0,
    system_message_count: usize = 0,
    user_message_count: usize = 0,
    assistant_message_count: usize = 0,
    tool_message_count: usize = 0,
    tool_schema_count: usize = 0,
    multimodal_part_count: usize = 0,
    tool_surface_mode: []const u8 = tool_surface.Mode.no_tools.toSlice(),
    provider_supports_native_tools: bool = false,
    native_tool_count: usize = 0,
    native_tool_schemas_present: bool = false,
    xml_tool_catalog_present: bool = false,
    prompt_tool_catalog_present: bool = false,
    xml_fallback_protocol_present: bool = false,
    native_strict_canary: bool = false,
    native_tool_schema_bytes: u64 = 0,
    xml_tool_catalog_bytes: u64 = 0,
    prompt_tool_catalog_bytes: u64 = 0,
    prompt_cache_key_present: bool = false,
    prompt_cache_key_bytes: usize = 0,
    stable_system_prompt_bytes: u64 = 0,
    volatile_system_prompt_bytes: u64 = 0,
    system_prompt_bytes: u64 = 0,
    tool_schema_bytes: u64 = 0,
    user_message_bytes: u64 = 0,
    assistant_message_bytes: u64 = 0,
    assistant_reasoning_bytes: u64 = 0,
    native_tool_call_bytes: u64 = 0,
    tool_message_bytes: u64 = 0,
    xml_tool_history_bytes: u64 = 0,
    multimodal_payload_estimated_bytes: u64 = 0,
    provider_bound_message_bytes: u64 = 0,
    provider_request_body_bytes_estimated: u64 = 0,
    history_tail_bytes: u64 = 0,
    stable_system_prompt_hash: u64 = 0,
    volatile_system_prompt_hash: u64 = 0,
    history_tail_hash: u64 = 0,
    full_request_hash: u64 = 0,
    prompt_block_count: usize = 0,
    prompt_blocks: [PROMPT_BLOCK_LIMIT]PromptBlock = [_]PromptBlock{.{}} ** PROMPT_BLOCK_LIMIT,
    tool_schema_diagnostic_count: usize = 0,
    largest_tool_schemas: [TOOL_SCHEMA_DIAGNOSTIC_LIMIT]ToolSchemaDiagnostic =
        [_]ToolSchemaDiagnostic{.{}} ** TOOL_SCHEMA_DIAGNOSTIC_LIMIT,
};

pub const PromptShapeCapture = struct {
    stable_system_prompt_bytes: usize = 0,
    stable_system_prompt_hash: u64 = 0,
    history_tail_bytes: usize = 0,
    history_tail_hash: u64 = 0,
    sampled_at_ms: i64 = 0,
    tool_surface_plan: tool_surface.Plan = .{},
};

pub const Snapshot = struct {
    status: []const u8 = "live",
    sampled_at_ms: i64 = 0,
    model_name: []const u8,
    model_provider: ?[]const u8 = null,
    history_messages: usize,
    pressure_token_source: []const u8 = PressureTokenSource.local_estimate.toSlice(),
    local_token_estimate: u64 = 0,
    provider_prompt_tokens: u32 = 0,
    provider_cached_prompt_tokens: u32 = 0,
    token_estimate: u64,
    context_window_tokens: u64,
    context_window_source: []const u8 = "unknown",
    remaining_tokens: u64 = 0,
    usable_input_budget_tokens: u64 = 0,
    budget_pressure_percent: u8 = 0,
    context_content_bytes: u64 = 0,
    context_reasoning_bytes: u64 = 0,
    context_pressure_percent: u8,
    history_trim_limit_messages: u32,
    token_compaction_threshold: u64,
    token_compaction_recommended_threshold: u64 = 0,
    token_auto_compaction_pass_a_threshold: u64 = 0,
    token_auto_compaction_pass_c_threshold: u64 = 0,
    compaction_recommend_percent: u8 = compaction.COMPACTION_RECOMMEND_PERCENT,
    auto_compaction_pass_a_percent: u8 = compaction.AUTO_COMPACT_PASS_A_PERCENT,
    auto_compaction_pass_c_percent: u8 = compaction.AUTO_COMPACT_PASS_C_PERCENT,
    token_compaction_recommended: bool,
    /// Legacy JSON/report alias for token_compaction_recommended. Kept so
    /// older clients do not break, but this is advisory and does not mean an
    /// automatic compaction pass has fired.
    token_compaction_triggered: bool,
    token_reply_reserve: u64,
    token_tool_reserve: u64,
    token_safety_reserve: u64,
    token_total_reserve: u64,
    tool_count: usize,
    role_counts: RoleCounts,
    memory_enabled: bool,
    memory_runtime_enabled: bool,
    memory_session_id: ?[]const u8,
    conversation_retention_days: ?u32,
    memory_enriched_messages: usize,
    has_system_prompt: bool,
    has_conversation_context: bool,
    compact_context_enabled: bool,
    context_was_compacted: bool,
    workspace_prompt_fingerprint: ?u64,
    retrieval_mode: []const u8,
    embedding_provider: []const u8,
    vector_mode: []const u8,
    rollout_mode: []const u8,
    stable_prefix_cache: context_cache.StablePrefixState = .{},
    buckets: context_cache.BucketSet = .{},
    provider_usage_last_turn: ProviderUsage = .{},
    provider_preflight: ProviderPreflightUsage = .{},
    last_turn_delta: LastTurnDelta = .{},
    top_context_contributor_count: usize = 0,
    top_context_contributors: [context_estimator.TOP_CONTRIBUTOR_LIMIT]context_estimator.TopContributor =
        [_]context_estimator.TopContributor{.{}} ** context_estimator.TOP_CONTRIBUTOR_LIMIT,
    last_turn: LastTurnContext = .{},
    prompt_shape: PromptShape = .{},
};

pub const LastTurnContext = struct {
    available: bool = false,
    prompt_refreshed: bool = false,
    workspace_prompt_changed: bool = false,
    time_bucket_changed: bool = false,
    conversation_context_changed: bool = false,
    memory_context_injected: bool = false,
    memory_context_bytes: usize = 0,
    memory_enrich_ms: u64 = 0,
    cache_hit: bool = false,
    trim_events: usize = 0,
    trimmed_messages: usize = 0,
    trimmed_bytes: usize = 0,
    history_messages_after_trim: usize = 0,
    auto_compaction_events: usize = 0,
    auto_compacted_messages: usize = 0,
    force_compression_events: usize = 0,
    force_compressed_messages: usize = 0,
    tool_mode: []const u8 = "no_tools",
    native_tools_sent: bool = false,
    tool_choice: []const u8 = "none",
    provider_finish_reason: []const u8 = "unknown",
    native_tool_call_count: u32 = 0,
    xml_fallback_call_count: u32 = 0,
    xml_fallback_reason: []const u8 = "none",
    stream_tool_call_chunks: u32 = 0,
    tool_call_ids_present: bool = false,
    native_transcript_rendered: bool = false,
    native_tool_result_messages: u32 = 0,
    xml_history_messages: u32 = 0,
    synthesized_tool_call_ids: u32 = 0,
    bounded_result_count: u32 = 0,
    /// V1.14.10 A semantic shift (review fix N-02): pre-V1.14.10 this
    /// flag meant "the persistSessionCheckpoint sync call completed,
    /// data is on disk." Post-V1.14.10 (review fix M-03): it means
    /// "we successfully spawned an async lifecycle worker for this
    /// turn." When the in-flight guard drops a duplicate trigger, the
    /// flag is `false` — telemetry honestly reflects that THIS turn's
    /// data is queued behind the prior worker (the prior worker will
    /// pick up what was missed). Don't read this as a write-completion
    /// guarantee — read it as "spawn attempted-and-accepted."
    durable_continuity_refreshed: bool = false,
    memory_selection: MemorySelection = .{},
};

pub const MemorySelection = struct {
    available: bool = false,
    candidate_count: usize = 0,
    global_candidate_count: usize = 0,
    summary_latest_used: bool = false,
    context_anchor_used: bool = false,
    durable_fact_count: usize = 0,
    timeline_summary_count: usize = 0,
    search_match_count: usize = 0,
    global_fallback_count: usize = 0,
    continuity_bucket_entries: usize = 0,
    continuity_bucket_bytes: usize = 0,
    semantic_bucket_entries: usize = 0,
    semantic_bucket_bytes: usize = 0,
    fallback_bucket_entries: usize = 0,
    fallback_bucket_bytes: usize = 0,
    // V1.7a-2 graph-expand recall telemetry — added to projection
    // post-V1.8-12 audit (was orphaned in SelectionStats but never
    // projected to MemorySelection downstream consumers).
    graph_recall_active: bool = false,
    graph_recall_seed_count: usize = 0,
    graph_recall_neighbor_count: usize = 0,
    graph_recall_appended_bytes: usize = 0,
    // V1.8-9 active-identity pin telemetry. Mirrors graph_recall_*
    // shape so /agent/turn_audit can report identity coverage per turn.
    identity_pin_active: bool = false,
    identity_pin_fact_count: usize = 0,
    identity_pin_appended_bytes: usize = 0,
    // Typed-view telemetry (prefs/open-loops/decisions/people builders).
    // Mirrors graph_recall_* / identity_pin_* shape for turn_audit coverage.
    typed_views_active: bool = false,
    typed_views_item_count: usize = 0,
    typed_views_appended_bytes: usize = 0,
};

pub const PromptRefreshPlan = struct {
    current_time_bucket_min: i64,
    workspace_prompt_fingerprint: ?u64,
    conversation_context_present: bool,
    conversation_context_fingerprint: u64,
    workspace_prompt_changed: bool,
    time_bucket_changed: bool,
    conversation_context_changed: bool,
    should_refresh_system_prompt: bool,
};

fn hasMemoryContextPrefix(content: []const u8) bool {
    return std.mem.startsWith(u8, content, "[Memory context]\n");
}

fn memoryContextPrefixBytes(content: []const u8) usize {
    if (!hasMemoryContextPrefix(content)) return 0;
    if (std.mem.indexOf(u8, content, "\n\n")) |sep_idx| {
        return sep_idx + 2;
    }
    return content.len;
}

fn tokenEstimateFromBytes(bytes: usize) u64 {
    return context_estimator.tokenEstimateFromBytes(@intCast(bytes));
}

fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(bytes);
}

fn pressurePercent(used_tokens: u64, context_window_tokens: u64) u8 {
    if (context_window_tokens == 0) return 0;
    const pct = @min(@as(u64, 100), (used_tokens * 100) / context_window_tokens);
    return @intCast(pct);
}

fn modelProvider(model_name: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, model_name, '/') orelse return null;
    if (slash == 0) return null;
    return model_name[0..slash];
}

fn messageReasoningBytes(entry: anytype) usize {
    const EntryType = @TypeOf(entry);
    if (!@hasField(EntryType, "reasoning")) return 0;
    if (entry.reasoning) |reasoning| return reasoning.len;
    return 0;
}

fn providerMessageTextBytes(message: anytype) usize {
    const MessageType = @TypeOf(message);
    if (@hasField(MessageType, "content_parts")) {
        if (message.content_parts) |parts| {
            var total: usize = 0;
            for (parts) |part| {
                total += contentPartEstimatedBytes(part);
            }
            return total;
        }
    }
    if (@hasField(MessageType, "content")) return message.content.len;
    return 0;
}

fn contentPartEstimatedBytes(part: anytype) usize {
    return switch (part) {
        .text => |text| text.len,
        .image_url => |image| image.url.len + 256,
        .image_base64 => |image| image.data.len + image.media_type.len + 64,
        .video_base64 => |video| video.data.len + video.media_type.len + 64,
        .video_file_ref => |video| video.url.len + video.media_type.len + 256,
    };
}

fn contentPartCount(message: anytype) usize {
    const MessageType = @TypeOf(message);
    if (!@hasField(MessageType, "content_parts")) return 0;
    if (message.content_parts) |parts| return parts.len;
    return 0;
}

fn reasoningBytes(message: anytype) usize {
    const MessageType = @TypeOf(message);
    if (@hasField(MessageType, "reasoning_content")) {
        if (message.reasoning_content) |reasoning| return reasoning.len;
    }
    return 0;
}

fn toolSpecBytes(tool: anytype) usize {
    const ToolType = @TypeOf(tool);
    var bytes: usize = 0;
    if (@hasField(ToolType, "name")) bytes += tool.name.len;
    if (@hasField(ToolType, "description")) bytes += tool.description.len;
    if (@hasField(ToolType, "parameters_json")) bytes += tool.parameters_json.len;
    return bytes;
}

fn toolDescriptionBytes(tool: anytype) usize {
    const ToolType = @TypeOf(tool);
    if (@hasField(ToolType, "description")) return tool.description.len;
    return 0;
}

fn toolParametersBytes(tool: anytype) usize {
    const ToolType = @TypeOf(tool);
    if (@hasField(ToolType, "parameters_json")) return tool.parameters_json.len;
    return 0;
}

fn toolName(tool: anytype) []const u8 {
    const ToolType = @TypeOf(tool);
    if (@hasField(ToolType, "name")) return tool.name;
    return "unknown";
}

fn looksLikeXmlToolHistory(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "<tool_call") != null or
        std.mem.indexOf(u8, content, "<tool_result") != null or
        std.mem.indexOf(u8, content, "</tool_call") != null or
        std.mem.indexOf(u8, content, "</tool_result") != null or
        std.mem.indexOf(u8, content, "<tool name=") != null;
}

fn updateHashForOptional(hasher: *std.hash.Fnv1a_64, label: []const u8, value: anytype) void {
    hasher.update(label);
    if (value) |slice| hasher.update(slice);
}

fn updateHashForMessage(hasher: *std.hash.Fnv1a_64, message: anytype) void {
    hasher.update(@tagName(message.role));
    hasher.update("\n");
    if (@hasField(@TypeOf(message), "name")) updateHashForOptional(hasher, "name:", message.name);
    if (@hasField(@TypeOf(message), "tool_call_id")) updateHashForOptional(hasher, "tool_call_id:", message.tool_call_id);
    if (@hasField(@TypeOf(message), "content_parts")) {
        if (message.content_parts) |parts| {
            hasher.update("parts:");
            for (parts) |part| {
                switch (part) {
                    .text => |text| {
                        hasher.update("text:");
                        hasher.update(text);
                    },
                    .image_url => |image| {
                        hasher.update("image_url:");
                        hasher.update(image.url);
                        hasher.update(image.detail.toSlice());
                    },
                    .image_base64 => |image| {
                        hasher.update("image_base64:");
                        hasher.update(image.media_type);
                        hasher.update(image.data);
                    },
                    .video_base64 => |video| {
                        hasher.update("video_base64:");
                        hasher.update(video.media_type);
                        hasher.update(video.data);
                    },
                    .video_file_ref => |video| {
                        hasher.update("video_file_ref:");
                        hasher.update(video.media_type);
                        hasher.update(video.url);
                    },
                }
            }
        } else if (@hasField(@TypeOf(message), "content")) {
            hasher.update(message.content);
        }
    } else if (@hasField(@TypeOf(message), "content")) {
        hasher.update(message.content);
    }
    if (@hasField(@TypeOf(message), "reasoning_content")) updateHashForOptional(hasher, "reasoning:", message.reasoning_content);
    if (@hasField(@TypeOf(message), "tool_calls")) {
        hasher.update("tool_calls:");
        for (message.tool_calls) |tc| {
            hasher.update(tc.id);
            hasher.update("\x00");
            hasher.update(tc.name);
            hasher.update("\x00");
            hasher.update(tc.arguments);
            hasher.update("\x00");
        }
    }
}

fn updateHashForTool(hasher: *std.hash.Fnv1a_64, tool: anytype) void {
    const ToolType = @TypeOf(tool);
    hasher.update("tool:");
    if (@hasField(ToolType, "name")) hasher.update(tool.name);
    if (@hasField(ToolType, "description")) hasher.update(tool.description);
    if (@hasField(ToolType, "parameters_json")) hasher.update(tool.parameters_json);
}

fn toolHash(tool: anytype) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    updateHashForTool(&hasher, tool);
    return hasher.final();
}

fn copyToolName(dest: *[TOOL_SCHEMA_NAME_LIMIT]u8, value: []const u8) usize {
    @memset(dest[0..], 0);
    var out: usize = 0;
    for (value) |byte| {
        if (out >= TOOL_SCHEMA_NAME_LIMIT) break;
        if (byte == 0) break;
        dest[out] = if (byte < 0x20 or byte == 0x7f) '_' else byte;
        out += 1;
    }
    return out;
}

fn toolSchemaDiagnostic(tool: anytype) ToolSchemaDiagnostic {
    var diag = ToolSchemaDiagnostic{
        .description_bytes = @intCast(toolDescriptionBytes(tool)),
        .parameters_bytes = @intCast(toolParametersBytes(tool)),
        .bytes = @intCast(toolSpecBytes(tool)),
        .hash = toolHash(tool),
        .active = true,
    };
    diag.name_len = copyToolName(&diag.name, toolName(tool));
    return diag;
}

fn insertLargestToolSchema(shape: *PromptShape, diag: ToolSchemaDiagnostic) void {
    if (!diag.active or diag.bytes == 0) return;
    var insert_at: usize = shape.tool_schema_diagnostic_count;
    var i: usize = 0;
    while (i < shape.tool_schema_diagnostic_count) : (i += 1) {
        if (diag.bytes > shape.largest_tool_schemas[i].bytes) {
            insert_at = i;
            break;
        }
    }
    if (insert_at >= TOOL_SCHEMA_DIAGNOSTIC_LIMIT) return;
    const old_count = shape.tool_schema_diagnostic_count;
    if (shape.tool_schema_diagnostic_count < TOOL_SCHEMA_DIAGNOSTIC_LIMIT) {
        shape.tool_schema_diagnostic_count += 1;
    }
    var j = @min(old_count, TOOL_SCHEMA_DIAGNOSTIC_LIMIT - 1);
    while (j > insert_at) : (j -= 1) {
        shape.largest_tool_schemas[j] = shape.largest_tool_schemas[j - 1];
    }
    shape.largest_tool_schemas[insert_at] = diag;
}

fn addPromptBlock(shape: *PromptShape, name: []const u8, bucket: []const u8, content: []const u8) void {
    if (content.len == 0 or shape.prompt_block_count >= PROMPT_BLOCK_LIMIT) return;
    addPromptBlockMeasured(shape, name, bucket, content.len, hashBytes(content));
}

fn addPromptBlockMeasured(shape: *PromptShape, name: []const u8, bucket: []const u8, bytes: usize, hash: u64) void {
    if (bytes == 0 or shape.prompt_block_count >= PROMPT_BLOCK_LIMIT) return;
    if (std.mem.eql(u8, name, "prompt_tool_catalog")) {
        shape.prompt_tool_catalog_bytes += @intCast(bytes);
    } else if (std.mem.eql(u8, name, "xml_tool_catalog")) {
        shape.xml_tool_catalog_present = true;
        shape.xml_tool_catalog_bytes += @intCast(bytes);
    }
    shape.prompt_blocks[shape.prompt_block_count] = .{
        .name = name,
        .bucket = bucket,
        .bytes = @intCast(bytes),
        .token_estimate = tokenEstimateFromBytes(bytes),
        .hash = hash,
        .active = true,
    };
    shape.prompt_block_count += 1;
}

const PromptBlockMarker = struct {
    marker: []const u8,
    name: []const u8,
    bucket: []const u8,
};

const FoundPromptBlockMarker = struct {
    pos: usize,
    name: []const u8,
    bucket: []const u8,
};

fn insertPromptMarker(found: *[PROMPT_BLOCK_LIMIT]FoundPromptBlockMarker, count: *usize, marker: FoundPromptBlockMarker) void {
    if (count.* >= found.len) return;
    var insert_at = count.*;
    while (insert_at > 0 and found[insert_at - 1].pos > marker.pos) : (insert_at -= 1) {
        found[insert_at] = found[insert_at - 1];
    }
    found[insert_at] = marker;
    count.* += 1;
}

fn addPromptBlocksByMarkers(
    shape: *PromptShape,
    content: []const u8,
    markers: []const PromptBlockMarker,
    fallback_name: []const u8,
    fallback_bucket: []const u8,
) void {
    if (content.len == 0) return;

    var found: [PROMPT_BLOCK_LIMIT]FoundPromptBlockMarker = undefined;
    var count: usize = 0;
    for (markers) |marker| {
        const pos = std.mem.indexOf(u8, content, marker.marker) orelse continue;
        insertPromptMarker(&found, &count, .{
            .pos = pos,
            .name = marker.name,
            .bucket = marker.bucket,
        });
    }

    if (count == 0) {
        addPromptBlock(shape, fallback_name, fallback_bucket, content);
        return;
    }

    if (found[0].pos > 0) {
        addPromptBlock(shape, fallback_name, fallback_bucket, content[0..found[0].pos]);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const start = found[i].pos;
        const end = if (i + 1 < count) found[i + 1].pos else content.len;
        if (end > start) addPromptBlock(shape, found[i].name, found[i].bucket, content[start..end]);
    }
}

/// KEYSTONE — the single source of truth for the system-prompt scaffold
/// section titles. This list IS the brain-leak denylist seed: Fixes A/B/C of
/// the brain-leak series (extraction_persist write-boundary denylist, the
/// root.zig user-bound output strip, and the zaki_state C0 purge) all derive
/// from `stable_prompt_markers` + `scaffold_internal_tokens` below so the
/// guardrails can NEVER drift from the prompt that produces the scaffold.
/// If you add/rename a stable section here, the leak defenses update for free.
pub const stable_prompt_markers = [_]PromptBlockMarker{
    .{ .marker = "## Memory Link Types\n\n", .name = "memory_link_types", .bucket = "stable:tier1" },
    .{ .marker = "## Brain Architecture\n\n", .name = "brain_architecture", .bucket = "stable:tier1" },
    .{ .marker = "## Response Protocol\n\n", .name = "response_protocol", .bucket = "stable:tier1" },
    .{ .marker = "## Channel Attachments\n\n", .name = "channel_attachments", .bucket = "stable:tier1" },
    .{ .marker = "## Task Decomposition\n\n", .name = "task_decomposition", .bucket = "stable:tier1" },
    .{ .marker = "## Safety\n\n", .name = "safety", .bucket = "stable:tier1" },
    .{ .marker = "## Tools\n\n", .name = "prompt_tool_catalog", .bucket = "stable:tier2" },
    .{ .marker = "## Runtime Capabilities\n\n", .name = "runtime_capabilities", .bucket = "stable:tier2" },
    .{ .marker = "## Persona Calibration\n\n", .name = "persona", .bucket = "stable:tier3" },
    .{ .marker = "## Project Context\n\n", .name = "workspace_identity_files", .bucket = "stable:tier3" },
    .{ .marker = "## Skills\n\n", .name = "skills_full", .bucket = "stable:tier3" },
    .{ .marker = "## Available Skills\n\n", .name = "skills_available_index", .bucket = "stable:tier3" },
    .{ .marker = "## Workspace\n\n", .name = "workspace_paths", .bucket = "stable:tier3" },
    .{ .marker = "## Runtime\n\n", .name = "runtime_model", .bucket = "stable:tier4" },
    .{ .marker = "## Tool Use Protocol\n\n", .name = "xml_tool_protocol", .bucket = "stable:xml_tools" },
    .{ .marker = "### Available Tools\n\n", .name = "xml_tool_catalog", .bucket = "stable:xml_tools" },
};

/// Scaffold-body terms — the distinctive multi-word phrases that appear
/// INSIDE the stable sections above (chiefly `## Brain Architecture` and
/// `## Memory Link Types`). The #48 leak persisted these as brain ENTITIES,
/// so they belong on the entity-name denylist alongside the section titles.
///
/// Curated, NOT auto-derived: section BODIES are prose that changes; pinning
/// the load-bearing terms here keeps the denylist precise (full-name match,
/// see `scaffold_entity_names`) without sweeping in generic vocabulary.
pub const scaffold_internal_tokens = [_][]const u8{
    "Working memory",
    "Working Memory",
    "Distillation extraction",
    "Distillation Extraction",
    "Layer 0",
    "Layer 1",
    "Layer 2",
    "Auto-promoted",
    "Auto-promotion",
    "Semantic memory",
    "Episodic memory",
    "Procedural memory",
    "Memory link",
    "Memory Link",
    "Link type",
    "Link Type",
};

/// Brain-leak denylist of scaffold section TITLES (the bare `## <Title>` text,
/// header markup stripped). Built from `stable_prompt_markers` so it can't
/// drift. Excludes the generic single-word titles (Safety / Tools / Runtime /
/// Workspace / Skills) that legitimately occur as user-supplied entity names —
/// the leak only ever produced the scaffold-SPECIFIC multi-word phrases, and
/// matching is exact-full-name (not substring), so omitting them avoids
/// over-filtering real facts. The XML tool-protocol titles are kept (they are
/// never plausible user entities). See `scaffold_entity_names` for the
/// combined, deduped denylist Fixes A/C consume.
pub const scaffold_title_names = [_][]const u8{
    "Memory Link Types",
    "Brain Architecture",
    "Response Protocol",
    "Channel Attachments",
    "Task Decomposition",
    "Runtime Capabilities",
    "Persona Calibration",
    "Project Context",
    "Available Skills",
    "Tool Use Protocol",
    "Available Tools",
};

/// Combined entity-name denylist for the brain-leak fixes: scaffold section
/// titles + scaffold-body terms. Compared case-insensitively and after
/// whitespace-normalization by `isScaffoldEntityName`. This is the single
/// list Fix A (extraction write boundary) and Fix C (C0 purge) consume.
pub const scaffold_entity_names = scaffold_title_names ++ scaffold_internal_tokens;

/// Whitespace-normalize `s` in place into `buf` (collapse internal runs of
/// ASCII whitespace to a single space, trim ends, lowercase ASCII). Returns
/// the normalized slice (a prefix of `buf`). Used by `isScaffoldEntityName`
/// so "  brain   architecture " matches "Brain Architecture". `buf` must be
/// at least `s.len` bytes. Non-ASCII bytes pass through unchanged (the
/// scaffold terms are all ASCII, so this is sufficient + allocation-free).
fn normalizeScaffoldName(s: []const u8, buf: []u8) []u8 {
    var out_len: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    var seen_nonspace = false;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (seen_nonspace) pending_space = true;
            continue;
        }
        if (pending_space) {
            buf[out_len] = ' ';
            out_len += 1;
            pending_space = false;
        }
        buf[out_len] = std.ascii.toLower(ch);
        out_len += 1;
        seen_nonspace = true;
    }
    return buf[0..out_len];
}

/// True when `name` is a system-prompt scaffold artifact (section title or
/// scaffold-body term) that must never be persisted as a brain entity or
/// recalled into a reply. Case-insensitive, whitespace-normalized, EXACT
/// full-name match (not substring) so legitimate facts that merely contain a
/// scaffold word ("Safety team", "uses Layer 0 of the stack") are untouched.
/// Stack-buffered + allocation-free; safe to call per fact on the write path.
pub fn isScaffoldEntityName(name: []const u8) bool {
    // Bound the work: the longest denylist entry is ~20 chars; any candidate
    // far longer than the longest entry cannot be an exact match. 128 is a
    // generous cap that covers every entry with headroom and keeps the
    // stack buffer small. Longer names are definitionally not a match.
    if (name.len == 0 or name.len > 128) return false;
    var buf: [128]u8 = undefined;
    const norm = normalizeScaffoldName(name, &buf);
    if (norm.len == 0) return false;
    inline for (scaffold_entity_names) |entry| {
        var ebuf: [128]u8 = undefined;
        const enorm = normalizeScaffoldName(entry, &ebuf);
        if (std.mem.eql(u8, norm, enorm)) return true;
    }
    return false;
}

test "isScaffoldEntityName: scaffold titles + body terms match (case/whitespace-insensitive)" {
    try std.testing.expect(isScaffoldEntityName("Brain Architecture"));
    try std.testing.expect(isScaffoldEntityName("brain architecture")); // case
    try std.testing.expect(isScaffoldEntityName("  Brain   Architecture  ")); // whitespace
    try std.testing.expect(isScaffoldEntityName("Memory Link Types"));
    try std.testing.expect(isScaffoldEntityName("Response Protocol"));
    try std.testing.expect(isScaffoldEntityName("Channel Attachments"));
    try std.testing.expect(isScaffoldEntityName("Task Decomposition"));
    try std.testing.expect(isScaffoldEntityName("Working memory"));
    try std.testing.expect(isScaffoldEntityName("Distillation extraction"));
    try std.testing.expect(isScaffoldEntityName("Layer 0"));
    try std.testing.expect(isScaffoldEntityName("Auto-promoted"));
}

test "isScaffoldEntityName: legitimate facts are NOT over-filtered" {
    // Real user entities — must pass through.
    try std.testing.expect(!isScaffoldEntityName("Helix"));
    try std.testing.expect(!isScaffoldEntityName("dark mode"));
    try std.testing.expect(!isScaffoldEntityName("Acme"));
    try std.testing.expect(!isScaffoldEntityName("Cairo"));
    // Generic single words deliberately excluded from the denylist so a real
    // fact using them survives.
    try std.testing.expect(!isScaffoldEntityName("Safety"));
    try std.testing.expect(!isScaffoldEntityName("Tools"));
    try std.testing.expect(!isScaffoldEntityName("Skills"));
    // Exact-match, not substring: a scaffold word embedded in a real phrase
    // must NOT trip the filter.
    try std.testing.expect(!isScaffoldEntityName("Safety team"));
    try std.testing.expect(!isScaffoldEntityName("Brain Architecture course")); // longer than the entry
    try std.testing.expect(!isScaffoldEntityName("")); // empty
}

const volatile_prompt_markers = [_]PromptBlockMarker{
    .{ .marker = "## Conversation Context\n\n", .name = "conversation_context", .bucket = "volatile:turn" },
    .{ .marker = "## Current Date & Time\n\n", .name = "current_datetime", .bucket = "volatile:turn" },
    .{ .marker = "<working_memory", .name = "working_memory", .bucket = "volatile:memory" },
    .{ .marker = "<memory_for_turn", .name = "memory_for_turn", .bucket = "volatile:memory" },
    .{ .marker = "<recent_thoughts", .name = "recent_thoughts", .bucket = "volatile:reasoning_trace" },
    .{ .marker = "<known_weakness", .name = "known_weakness", .bucket = "volatile:self_knowledge" },
    .{ .marker = "<task_plan", .name = "task_plan", .bucket = "volatile:working_plan" },
    .{ .marker = "<recent_skill_traces", .name = "recent_skill_traces", .bucket = "volatile:procedural_memory" },
};

fn addSystemPromptBlocks(shape: *PromptShape, system_prompt: []const u8, stable_prefix_bytes: usize) void {
    const stable_end = @min(stable_prefix_bytes, system_prompt.len);
    addPromptBlocksByMarkers(
        shape,
        system_prompt[0..stable_end],
        &stable_prompt_markers,
        "stable_system_unclassified",
        "stable:unclassified",
    );
    if (stable_end < system_prompt.len) {
        addPromptBlocksByMarkers(
            shape,
            system_prompt[stable_end..],
            &volatile_prompt_markers,
            "volatile_system_unclassified",
            "volatile:unclassified",
        );
    }
}

pub fn buildPromptShapeFromProviderRequest(request: anytype, capture: PromptShapeCapture) PromptShape {
    const captured_plan = capture.tool_surface_plan;
    var shape = PromptShape{
        .available = true,
        .sampled_at_ms = if (capture.sampled_at_ms > 0) capture.sampled_at_ms else std.time.milliTimestamp(),
        .stable_system_prompt_bytes = capture.stable_system_prompt_bytes,
        .stable_system_prompt_hash = capture.stable_system_prompt_hash,
        .history_tail_bytes = capture.history_tail_bytes,
        .history_tail_hash = capture.history_tail_hash,
        .tool_surface_mode = captured_plan.mode.toSlice(),
        .provider_supports_native_tools = captured_plan.provider_supports_native_tools,
        .native_tool_count = captured_plan.native_tool_count,
        .native_tool_schemas_present = captured_plan.native_tool_schemas_present,
        .xml_tool_catalog_present = captured_plan.xml_tool_catalog_present,
        .prompt_tool_catalog_present = captured_plan.prompt_tool_catalog_present,
        .xml_fallback_protocol_present = captured_plan.xml_fallback_protocol_present,
        .native_strict_canary = captured_plan.native_strict_canary,
    };
    var request_hasher = std.hash.Fnv1a_64.init();

    if (@hasField(@TypeOf(request), "model")) {
        shape.provider_request_body_bytes_estimated += request.model.len;
        request_hasher.update("model:");
        request_hasher.update(request.model);
    }
    if (@hasField(@TypeOf(request), "prompt_cache_key")) {
        if (request.prompt_cache_key) |key| {
            shape.prompt_cache_key_present = true;
            shape.prompt_cache_key_bytes = key.len;
            shape.provider_request_body_bytes_estimated += key.len;
            request_hasher.update("prompt_cache_key_present");
        }
    }
    if (@hasField(@TypeOf(request), "max_tokens")) {
        if (request.max_tokens != null) shape.provider_request_body_bytes_estimated += 16;
    }
    if (@hasField(@TypeOf(request), "reasoning_effort")) {
        if (request.reasoning_effort) |effort| {
            shape.provider_request_body_bytes_estimated += effort.len;
            request_hasher.update("reasoning_effort:");
            request_hasher.update(effort);
        }
    }

    if (@hasField(@TypeOf(request), "tools")) {
        if (request.tools) |tools| {
            shape.tool_schema_count = tools.len;
            var tool_schema_hasher = std.hash.Fnv1a_64.init();
            for (tools) |tool| {
                const bytes = toolSpecBytes(tool);
                shape.tool_schema_bytes += bytes;
                shape.native_tool_schema_bytes += bytes;
                shape.provider_request_body_bytes_estimated += bytes + 64;
                updateHashForTool(&request_hasher, tool);
                updateHashForTool(&tool_schema_hasher, tool);
                insertLargestToolSchema(&shape, toolSchemaDiagnostic(tool));
            }
            shape.native_tool_schemas_present = tools.len > 0;
            if (shape.native_tool_count == 0) shape.native_tool_count = tools.len;
            addPromptBlockMeasured(&shape, "native_tool_schemas", "provider_tools", @intCast(shape.tool_schema_bytes), tool_schema_hasher.final());
        }
    }

    if (@hasField(@TypeOf(request), "messages")) {
        shape.message_count = request.messages.len;
        for (request.messages) |message| {
            const text_bytes = providerMessageTextBytes(message);
            const msg_reasoning_bytes = reasoningBytes(message);
            const parts = contentPartCount(message);
            shape.provider_bound_message_bytes += text_bytes + msg_reasoning_bytes;
            var native_tool_call_bytes: usize = 0;
            if (@hasField(@TypeOf(message), "tool_calls")) {
                for (message.tool_calls) |tc| {
                    native_tool_call_bytes += tc.id.len + tc.name.len + tc.arguments.len + 72;
                }
            }
            shape.provider_request_body_bytes_estimated += text_bytes + msg_reasoning_bytes + native_tool_call_bytes + 64;
            shape.multimodal_part_count += parts;
            if (parts > 0) shape.multimodal_payload_estimated_bytes += text_bytes;
            updateHashForMessage(&request_hasher, message);

            switch (message.role) {
                .system => {
                    shape.system_message_count += 1;
                    shape.system_prompt_bytes += text_bytes;
                    if (shape.system_message_count == 1 and @hasField(@TypeOf(message), "content")) {
                        const stable_bytes = @min(capture.stable_system_prompt_bytes, message.content.len);
                        addSystemPromptBlocks(&shape, message.content, stable_bytes);
                        if (message.content.len > stable_bytes) {
                            const volatile_slice = message.content[stable_bytes..];
                            var volatile_hasher = std.hash.Fnv1a_64.init();
                            volatile_hasher.update(volatile_slice);
                            shape.volatile_system_prompt_hash = volatile_hasher.final();
                        }
                    }
                },
                .user => {
                    shape.user_message_count += 1;
                    shape.user_message_bytes += text_bytes;
                },
                .assistant => {
                    shape.assistant_message_count += 1;
                    shape.assistant_message_bytes += text_bytes;
                    shape.assistant_reasoning_bytes += msg_reasoning_bytes;
                    shape.native_tool_call_bytes += native_tool_call_bytes;
                    if (@hasField(@TypeOf(message), "content") and looksLikeXmlToolHistory(message.content)) {
                        shape.xml_tool_history_bytes += text_bytes;
                    }
                },
                .tool => {
                    shape.tool_message_count += 1;
                    shape.tool_message_bytes += text_bytes;
                    if (@hasField(@TypeOf(message), "content")) shape.xml_tool_history_bytes += text_bytes;
                },
            }
        }
    }

    if (shape.system_prompt_bytes > shape.stable_system_prompt_bytes) {
        shape.volatile_system_prompt_bytes = shape.system_prompt_bytes - shape.stable_system_prompt_bytes;
    }
    shape.full_request_hash = request_hasher.final();
    return shape;
}

fn providerUsageFromAgent(self: anytype) ProviderUsage {
    const AgentType = @TypeOf(self.*);
    if (!@hasField(AgentType, "last_turn_usage")) return .{};
    const usage = self.last_turn_usage;
    const cache_hit_percent: u8 = if (usage.prompt_tokens > 0)
        @intCast(@min(@as(u32, 100), (usage.cached_prompt_tokens * 100) / usage.prompt_tokens))
    else
        0;
    return .{
        .available = usage.prompt_tokens > 0 or usage.completion_tokens > 0 or usage.total_tokens > 0,
        .prompt_tokens = usage.prompt_tokens,
        .completion_tokens = usage.completion_tokens,
        .reasoning_tokens = usage.reasoning_tokens,
        .total_tokens = usage.total_tokens,
        .cached_prompt_tokens = usage.cached_prompt_tokens,
        .cache_hit_percent = cache_hit_percent,
    };
}

fn providerPreflightFromAgent(self: anytype) ProviderPreflightUsage {
    const AgentType = @TypeOf(self.*);
    if (!@hasField(AgentType, "provider_preflight_prompt_tokens")) return .{};
    const active = if (@hasField(AgentType, "provider_preflight_active"))
        self.provider_preflight_active
    else
        false;
    const available = self.provider_preflight_prompt_tokens > 0;
    return .{
        .available = available,
        .active = active and available,
        .prompt_tokens = self.provider_preflight_prompt_tokens,
        .source = if (@hasField(AgentType, "provider_preflight_source")) self.provider_preflight_source else "provider_preflight",
    };
}

pub fn selectPressureTokens(
    local_token_estimate: u64,
    provider_usage: ProviderUsage,
    provider_preflight: ProviderPreflightUsage,
) PressureSelection {
    if (provider_preflight.active and provider_preflight.prompt_tokens > 0) {
        return .{
            .token_count = provider_preflight.prompt_tokens,
            .source = .provider_preflight,
        };
    }
    if (provider_usage.prompt_tokens > 0) {
        return .{
            .token_count = provider_usage.prompt_tokens,
            .source = .provider_last_usage,
        };
    }
    if (provider_preflight.available and provider_preflight.prompt_tokens > 0) {
        return .{
            .token_count = provider_preflight.prompt_tokens,
            .source = .provider_preflight,
        };
    }
    return .{
        .token_count = local_token_estimate,
        .source = .local_estimate,
    };
}

fn contextWindowSource(self: anytype, model_name: []const u8, context_window_tokens: u64) []const u8 {
    const AgentType = @TypeOf(self.*);
    if (@hasField(AgentType, "token_limit_override")) {
        if (self.token_limit_override != null) {
            return "override";
        }
    }
    if (model_capabilities.lookupCapabilities(model_name) != null) {
        return "model_capability";
    }
    if (context_window_tokens > 0) {
        return "default";
    }
    return "unknown";
}

fn conversationContextFingerprintFromAgent(self: anytype) u64 {
    const AgentType = @TypeOf(self.*);
    if (!@hasField(AgentType, "conversation_context")) return conversationContextFingerprint(null);
    if (@TypeOf(self.conversation_context) == ?prompt.ConversationContext) {
        return conversationContextFingerprint(self.conversation_context);
    }
    return conversationContextFingerprint(null);
}

pub fn conversationContextFingerprint(ctx: ?prompt.ConversationContext) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    if (ctx) |cc| {
        hasher.update("present");
        if (cc.channel) |channel| {
            hasher.update("channel:");
            hasher.update(channel);
        }
        if (cc.sender_number) |sender_number| {
            hasher.update("sender_number:");
            hasher.update(sender_number);
        }
        if (cc.sender_uuid) |sender_uuid| {
            hasher.update("sender_uuid:");
            hasher.update(sender_uuid);
        }
        if (cc.group_id) |group_id| {
            hasher.update("group_id:");
            hasher.update(group_id);
        }
        if (cc.is_group) |is_group| {
            hasher.update("is_group:");
            const b: u8 = if (is_group) 1 else 0;
            hasher.update(&[_]u8{b});
        }
    } else {
        hasher.update("absent");
    }
    return hasher.final();
}

pub fn buildSnapshot(self: anytype) Snapshot {
    const AgentType = @TypeOf(self.*);

    var role_counts = RoleCounts{};
    var memory_enriched_messages: usize = 0;
    var stable_prefix_entries: usize = 0;
    var stable_prefix_bytes: usize = 0;
    var memory_context_bytes: usize = 0;
    var recent_history_entries: usize = 0;
    var recent_history_bytes: usize = 0;

    if (@hasField(AgentType, "history")) {
        for (self.history.items) |entry| {
            const reasoning_bytes = messageReasoningBytes(entry);
            switch (entry.role) {
                .system => {
                    role_counts.system += 1;
                    stable_prefix_entries += 1;
                    stable_prefix_bytes += entry.content.len + reasoning_bytes;
                },
                .user => {
                    role_counts.user += 1;
                    recent_history_entries += 1;
                    const memory_prefix_bytes = memoryContextPrefixBytes(entry.content);
                    if (memory_prefix_bytes > 0) {
                        memory_enriched_messages += 1;
                        memory_context_bytes += memory_prefix_bytes;
                    }
                    recent_history_bytes += entry.content.len - @min(entry.content.len, memory_prefix_bytes);
                },
                .assistant => {
                    role_counts.assistant += 1;
                    recent_history_entries += 1;
                    recent_history_bytes += entry.content.len + reasoning_bytes;
                },
                .tool => {
                    role_counts.tool += 1;
                    recent_history_entries += 1;
                    recent_history_bytes += entry.content.len + reasoning_bytes;
                },
            }
        }
    }

    const has_system_prompt = if (@hasField(AgentType, "has_system_prompt")) self.has_system_prompt else role_counts.system > 0;
    const has_conversation_context = if (@hasField(AgentType, "conversation_context")) self.conversation_context != null else false;
    const conversation_context_fingerprint = conversationContextFingerprintFromAgent(self);
    const system_prompt_has_conversation_context = if (@hasField(AgentType, "system_prompt_has_conversation_context"))
        self.system_prompt_has_conversation_context
    else
        has_system_prompt and has_conversation_context;
    const prompt_refresh_plan = if (@hasField(AgentType, "has_system_prompt"))
        buildPromptRefreshPlan(self)
    else
        PromptRefreshPlan{
            .current_time_bucket_min = -1,
            .workspace_prompt_fingerprint = null,
            .conversation_context_present = has_conversation_context,
            .conversation_context_fingerprint = conversation_context_fingerprint,
            .workspace_prompt_changed = false,
            .time_bucket_changed = false,
            .conversation_context_changed = false,
            .should_refresh_system_prompt = !has_system_prompt,
        };
    const stable_prefix_cache = context_cache.buildStablePrefixState(prompt_refresh_plan, has_system_prompt);
    const last_turn = if (@hasField(AgentType, "last_turn_context")) self.last_turn_context else LastTurnContext{};
    const memory_context_entries = memory_enriched_messages;
    const model_name = if (@hasField(AgentType, "model_name")) self.model_name else "";
    const context_analysis = if (@hasField(AgentType, "history"))
        context_estimator.analyzeHistory(self.history)
    else
        context_estimator.Analysis{};
    const local_token_estimate = context_analysis.token_estimate;
    const context_window_tokens = if (@hasField(AgentType, "token_limit")) self.token_limit else 0;
    const resolved_max_tokens = if (@hasField(AgentType, "max_tokens")) self.max_tokens else 0;
    const token_budget_policy = compaction.buildTokenBudgetPolicy(context_window_tokens, resolved_max_tokens);
    const provider_usage = providerUsageFromAgent(self);
    const provider_preflight = providerPreflightFromAgent(self);
    const pressure_selection = selectPressureTokens(local_token_estimate, provider_usage, provider_preflight);
    const token_estimate = pressure_selection.token_count;
    const prompt_shape = if (@hasField(AgentType, "last_prompt_shape")) self.last_prompt_shape else PromptShape{};
    const remaining_tokens = if (context_window_tokens > token_estimate) context_window_tokens - token_estimate else 0;
    const usable_input_budget_tokens = if (context_window_tokens > token_budget_policy.total_reserve)
        context_window_tokens - token_budget_policy.total_reserve
    else
        0;

    return .{
        .sampled_at_ms = std.time.milliTimestamp(),
        .model_name = model_name,
        .model_provider = modelProvider(model_name),
        .history_messages = if (@hasField(AgentType, "history")) self.history.items.len else 0,
        .pressure_token_source = pressure_selection.source.toSlice(),
        .local_token_estimate = local_token_estimate,
        .provider_prompt_tokens = provider_usage.prompt_tokens,
        .provider_cached_prompt_tokens = provider_usage.cached_prompt_tokens,
        .token_estimate = token_estimate,
        .context_window_tokens = context_window_tokens,
        .context_window_source = contextWindowSource(self, model_name, context_window_tokens),
        .remaining_tokens = remaining_tokens,
        .usable_input_budget_tokens = usable_input_budget_tokens,
        .budget_pressure_percent = pressurePercent(token_estimate, usable_input_budget_tokens),
        .context_content_bytes = context_analysis.content_bytes,
        .context_reasoning_bytes = context_analysis.reasoning_bytes,
        .context_pressure_percent = pressurePercent(token_estimate, context_window_tokens),
        .history_trim_limit_messages = if (@hasField(AgentType, "max_history_messages")) self.max_history_messages else 0,
        .token_compaction_threshold = token_budget_policy.threshold,
        .token_compaction_recommended_threshold = token_budget_policy.compaction_trigger,
        .token_auto_compaction_pass_a_threshold = (context_window_tokens * compaction.AUTO_COMPACT_PASS_A_PERCENT) / 100,
        .token_auto_compaction_pass_c_threshold = (context_window_tokens * compaction.AUTO_COMPACT_PASS_C_PERCENT) / 100,
        // Context v2: 50% is an advisory marker, not an automatic compaction
        // fire signal. Automatic passes remain owned by autoCompactHistory
        // at 70% (Pass A) and 90% (Pass C).
        .token_compaction_recommended = token_budget_policy.compaction_trigger > 0 and token_estimate > token_budget_policy.compaction_trigger,
        .token_compaction_triggered = token_budget_policy.compaction_trigger > 0 and token_estimate > token_budget_policy.compaction_trigger,
        .token_reply_reserve = token_budget_policy.reply_reserve,
        .token_tool_reserve = token_budget_policy.tool_reserve,
        .token_safety_reserve = token_budget_policy.safety_reserve,
        .token_total_reserve = token_budget_policy.total_reserve,
        .tool_count = if (@hasField(AgentType, "tools")) self.tools.len else 0,
        .role_counts = role_counts,
        .memory_enabled = if (@hasField(AgentType, "mem")) self.mem != null else false,
        .memory_runtime_enabled = if (@hasField(AgentType, "mem_rt")) self.mem_rt != null else false,
        .memory_session_id = if (@hasField(AgentType, "memory_session_id")) self.memory_session_id else null,
        .conversation_retention_days = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.conversation_retention_days else null,
        .memory_enriched_messages = memory_enriched_messages,
        .has_system_prompt = has_system_prompt,
        .has_conversation_context = has_conversation_context,
        .compact_context_enabled = if (@hasField(AgentType, "compact_context_enabled")) self.compact_context_enabled else false,
        .context_was_compacted = if (@hasField(AgentType, "context_was_compacted")) self.context_was_compacted else false,
        .workspace_prompt_fingerprint = if (@hasField(AgentType, "workspace_prompt_fingerprint")) self.workspace_prompt_fingerprint else null,
        .retrieval_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.retrieval_mode else "n/a",
        .embedding_provider = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.embedding_provider else "n/a",
        .vector_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.vector_mode else "n/a",
        .rollout_mode = if (@hasField(AgentType, "mem_rt") and self.mem_rt != null) self.mem_rt.?.resolved.rollout_mode else "n/a",
        .stable_prefix_cache = stable_prefix_cache,
        .buckets = .{
            .stable_prefix = .{
                .entries = stable_prefix_entries,
                .bytes = stable_prefix_bytes,
                .token_estimate = tokenEstimateFromBytes(stable_prefix_bytes),
                .active = stable_prefix_entries > 0,
                .cacheability = .stable,
            },
            .memory_context = .{
                .entries = memory_context_entries,
                .bytes = memory_context_bytes,
                .token_estimate = tokenEstimateFromBytes(memory_context_bytes),
                .active = memory_context_entries > 0,
                .cacheability = .dynamic,
            },
            .recent_history = .{
                .entries = recent_history_entries,
                .bytes = recent_history_bytes,
                .token_estimate = tokenEstimateFromBytes(recent_history_bytes),
                .active = recent_history_entries > 0,
                .cacheability = .dynamic,
            },
            .last_turn_runtime = .{
                .entries = if (last_turn.available) 1 else 0,
                .bytes = last_turn.memory_context_bytes,
                .token_estimate = tokenEstimateFromBytes(last_turn.memory_context_bytes),
                .active = last_turn.available,
                .cacheability = .per_turn,
            },
            .conversation_context = .{
                .active = has_conversation_context,
                .embedded_in_stable_prefix = system_prompt_has_conversation_context,
                .fingerprint = conversation_context_fingerprint,
            },
        },
        .provider_usage_last_turn = provider_usage,
        .provider_preflight = provider_preflight,
        .last_turn_delta = .{
            .bytes = context_analysis.last_turn_delta_bytes,
            .token_estimate = context_analysis.last_turn_delta_tokens,
            .pressure_points = pressurePercent(context_analysis.last_turn_delta_tokens, context_window_tokens),
        },
        .top_context_contributor_count = context_analysis.top_count,
        .top_context_contributors = context_analysis.top_contributors,
        .last_turn = last_turn,
        .prompt_shape = prompt_shape,
    };
}

pub fn buildPromptRefreshPlan(self: anytype) PromptRefreshPlan {
    const AgentType = @TypeOf(self.*);
    const current_time_bucket_min = @divFloor(std.time.timestamp(), 60);
    const workspace_prompt_fingerprint = if (@hasField(AgentType, "allocator") and @hasField(AgentType, "workspace_dir"))
        prompt.workspacePromptFingerprint(self.allocator, self.workspace_dir) catch null
    else
        null;
    const has_system_prompt = if (@hasField(AgentType, "has_system_prompt")) self.has_system_prompt else false;
    const workspace_prompt_changed = has_system_prompt and
        workspace_prompt_fingerprint != null and
        @hasField(AgentType, "workspace_prompt_fingerprint") and
        self.workspace_prompt_fingerprint != workspace_prompt_fingerprint;
    const time_bucket_changed = has_system_prompt and
        @hasField(AgentType, "system_prompt_time_bucket_min") and
        self.system_prompt_time_bucket_min != current_time_bucket_min;
    const conversation_context_present = @hasField(AgentType, "conversation_context") and self.conversation_context != null;
    const conversation_context_fingerprint = conversationContextFingerprintFromAgent(self);
    const conversation_context_changed = has_system_prompt and
        @hasField(AgentType, "system_prompt_conversation_context_fingerprint") and
        self.system_prompt_conversation_context_fingerprint != conversation_context_fingerprint;

    return .{
        .current_time_bucket_min = current_time_bucket_min,
        .workspace_prompt_fingerprint = workspace_prompt_fingerprint,
        .conversation_context_present = conversation_context_present,
        .conversation_context_fingerprint = conversation_context_fingerprint,
        .workspace_prompt_changed = workspace_prompt_changed,
        .time_bucket_changed = time_bucket_changed,
        .conversation_context_changed = conversation_context_changed,
        .should_refresh_system_prompt = !has_system_prompt or workspace_prompt_changed or time_bucket_changed or conversation_context_changed,
    };
}

pub fn buildLastTurnContext(
    plan: PromptRefreshPlan,
    memory_stats: anytype,
    memory_enrich_ms: u64,
) LastTurnContext {
    return .{
        .available = true,
        .prompt_refreshed = plan.should_refresh_system_prompt,
        .workspace_prompt_changed = plan.workspace_prompt_changed,
        .time_bucket_changed = plan.time_bucket_changed,
        .conversation_context_changed = plan.conversation_context_changed,
        .memory_context_injected = memory_stats.injected,
        .memory_context_bytes = memory_stats.context_bytes,
        .memory_enrich_ms = memory_enrich_ms,
        .cache_hit = false,
        .history_messages_after_trim = 0,
        .memory_selection = selectionFromStats(memory_stats),
    };
}

pub fn recordTrimStats(last_turn: *LastTurnContext, trim_stats: anytype) void {
    if (!last_turn.available) return;
    if (trim_stats.removed_messages == 0 and trim_stats.removed_bytes == 0 and trim_stats.history_after == trim_stats.history_before) return;

    last_turn.trim_events += 1;
    last_turn.trimmed_messages += trim_stats.removed_messages;
    last_turn.trimmed_bytes += trim_stats.removed_bytes;
    last_turn.history_messages_after_trim = trim_stats.history_after;
}

pub fn recordAutoCompaction(last_turn: *LastTurnContext, history_before: usize, history_after: usize) void {
    if (!last_turn.available or history_before <= history_after) return;
    last_turn.auto_compaction_events += 1;
    last_turn.auto_compacted_messages += (history_before - history_after) + 1;
    last_turn.history_messages_after_trim = history_after;
}

pub fn recordForceCompression(last_turn: *LastTurnContext, history_before: usize, history_after: usize) void {
    if (!last_turn.available or history_before <= history_after) return;
    last_turn.force_compression_events += 1;
    last_turn.force_compressed_messages += history_before - history_after;
    last_turn.history_messages_after_trim = history_after;
}

pub fn selectionFromStats(stats: anytype) MemorySelection {
    return .{
        .available = stats.available,
        .candidate_count = stats.candidate_count,
        .global_candidate_count = stats.global_candidate_count,
        .summary_latest_used = stats.summary_latest_used,
        .context_anchor_used = stats.context_anchor_used,
        .durable_fact_count = stats.durable_fact_count,
        .timeline_summary_count = stats.timeline_summary_count,
        .search_match_count = stats.search_match_count,
        .global_fallback_count = stats.global_fallback_count,
        .continuity_bucket_entries = stats.continuity_bucket_entries,
        .continuity_bucket_bytes = stats.continuity_bucket_bytes,
        .semantic_bucket_entries = stats.semantic_bucket_entries,
        .semantic_bucket_bytes = stats.semantic_bucket_bytes,
        .fallback_bucket_entries = stats.fallback_bucket_entries,
        .fallback_bucket_bytes = stats.fallback_bucket_bytes,
        // V1.7a-2 graph-expand fields — projected through to MemorySelection
        // for downstream consumers (V1.8-12 audit fix).
        .graph_recall_active = stats.graph_recall_active,
        .graph_recall_seed_count = stats.graph_recall_seed_count,
        .graph_recall_neighbor_count = stats.graph_recall_neighbor_count,
        .graph_recall_appended_bytes = stats.graph_recall_appended_bytes,
        // V1.8-9 identity-pin fields.
        .identity_pin_active = stats.identity_pin_active,
        .identity_pin_fact_count = stats.identity_pin_fact_count,
        .identity_pin_appended_bytes = stats.identity_pin_appended_bytes,
        // Typed-view fields — mirrors identity_pin projection above.
        .typed_views_active = stats.typed_views_active,
        .typed_views_item_count = stats.typed_views_item_count,
        .typed_views_appended_bytes = stats.typed_views_appended_bytes,
    };
}

test "buildSnapshot counts roles and retrieval state" {
    const FakeRole = enum { system, user, assistant, tool };
    const FakeMessage = struct {
        role: FakeRole,
        content: []const u8,
    };
    const FakeHistory = struct {
        items: []const FakeMessage,
    };
    const FakeTool = u8;
    const Resolved = struct {
        retrieval_mode: []const u8,
        embedding_provider: []const u8,
        vector_mode: []const u8,
        rollout_mode: []const u8,
        conversation_retention_days: u32,
    };
    const FakeMemoryRuntime = struct {
        resolved: Resolved,
    };
    const messages = [_]FakeMessage{
        .{ .role = .system, .content = "system prompt" },
        .{ .role = .user, .content = "[Memory context]\n- pref: concise\n\nhello" },
        .{ .role = .assistant, .content = "hi" },
        .{ .role = .tool, .content = "tool output" },
    };
    const tools = [_]FakeTool{ 1, 2 };
    var fake_mem_rt = FakeMemoryRuntime{
        .resolved = .{
            .retrieval_mode = "hybrid",
            .embedding_provider = "together",
            .vector_mode = "pgvector",
            .rollout_mode = "on",
            .conversation_retention_days = 0,
        },
    };
    const fake = struct {
        model_name: []const u8,
        history: FakeHistory,
        tools: []const FakeTool,
        mem: ?u8,
        mem_rt: ?*FakeMemoryRuntime,
        token_limit: u64,
        max_tokens: u32,
        max_history_messages: u32,
        memory_session_id: ?[]const u8,
        conversation_context: ?u8,
        compact_context_enabled: bool,
        context_was_compacted: bool,
        has_system_prompt: bool,
        system_prompt_has_conversation_context: bool,
        system_prompt_time_bucket_min: i64,
        system_prompt_conversation_context_fingerprint: u64,
        workspace_prompt_fingerprint: ?u64,
    }{
        .model_name = "openai/gpt-5.2",
        .history = .{ .items = &messages },
        .tools = &tools,
        .mem = 1,
        .mem_rt = &fake_mem_rt,
        .token_limit = 1_000,
        .max_tokens = 300,
        .max_history_messages = 50,
        .memory_session_id = "agent:test:user:1:main",
        .conversation_context = null,
        .compact_context_enabled = true,
        .context_was_compacted = false,
        .has_system_prompt = true,
        .system_prompt_has_conversation_context = false,
        .system_prompt_time_bucket_min = -1,
        .system_prompt_conversation_context_fingerprint = 0,
        .workspace_prompt_fingerprint = 42,
    };

    const snapshot = buildSnapshot(&fake);
    try std.testing.expect(snapshot.sampled_at_ms > 0);
    try std.testing.expectEqualStrings("openai", snapshot.model_provider.?);
    try std.testing.expectEqualStrings("model_capability", snapshot.context_window_source);
    try std.testing.expectEqualStrings("local_estimate", snapshot.pressure_token_source);
    try std.testing.expectEqual(snapshot.local_token_estimate, snapshot.token_estimate);
    try std.testing.expectEqual(@as(usize, 4), snapshot.history_messages);
    try std.testing.expectEqual(@as(usize, 1), snapshot.memory_enriched_messages);
    try std.testing.expectEqual(@as(u64, 1_000) - snapshot.token_estimate, snapshot.remaining_tokens);
    try std.testing.expectEqual(@as(u8, 1), snapshot.context_pressure_percent);
    try std.testing.expectEqual(@as(u32, 50), snapshot.history_trim_limit_messages);
    try std.testing.expectEqual(@as(u64, 650), snapshot.token_compaction_threshold);
    try std.testing.expectEqual(@as(u64, 500), snapshot.token_compaction_recommended_threshold);
    try std.testing.expectEqual(@as(u64, 700), snapshot.token_auto_compaction_pass_a_threshold);
    try std.testing.expectEqual(@as(u64, 900), snapshot.token_auto_compaction_pass_c_threshold);
    try std.testing.expect(!snapshot.token_compaction_triggered);
    try std.testing.expectEqual(@as(u64, 300), snapshot.token_reply_reserve);
    try std.testing.expectEqual(@as(u64, 2_048), snapshot.token_tool_reserve);
    try std.testing.expectEqual(@as(u64, 1_024), snapshot.token_safety_reserve);
    try std.testing.expectEqual(@as(u64, 3_372), snapshot.token_total_reserve);
    try std.testing.expectEqualStrings("together", snapshot.embedding_provider);
    try std.testing.expectEqualStrings("pgvector", snapshot.vector_mode);
    try std.testing.expectEqual(@as(?u32, 0), snapshot.conversation_retention_days);
    try std.testing.expect(snapshot.has_system_prompt);
    try std.testing.expectEqual(@as(?u64, 42), snapshot.workspace_prompt_fingerprint);
    try std.testing.expectEqual(@as(usize, 1), snapshot.buckets.stable_prefix.entries);
    try std.testing.expectEqual(@as(usize, 13), snapshot.buckets.stable_prefix.bytes);
    try std.testing.expectEqual(@as(u64, 4), snapshot.buckets.stable_prefix.token_estimate);
    try std.testing.expectEqual(@as(usize, 1), snapshot.buckets.memory_context.entries);
    try std.testing.expectEqual(@as(usize, 34), snapshot.buckets.memory_context.bytes);
    try std.testing.expectEqual(@as(u64, 9), snapshot.buckets.memory_context.token_estimate);
    try std.testing.expectEqual(@as(usize, 3), snapshot.buckets.recent_history.entries);
    try std.testing.expectEqual(@as(usize, 18), snapshot.buckets.recent_history.bytes);
    try std.testing.expectEqual(@as(u64, 5), snapshot.buckets.recent_history.token_estimate);
    try std.testing.expect(snapshot.stable_prefix_cache.available);
}

test "buildSnapshot uses provider prompt tokens over lower local estimate" {
    const FakeRole = enum { system, user, assistant, tool };
    const FakeMessage = struct {
        role: FakeRole,
        content: []const u8,
    };
    const FakeHistory = struct {
        items: []const FakeMessage,
    };
    const messages = [_]FakeMessage{
        .{ .role = .system, .content = "tiny" },
        .{ .role = .user, .content = "hello" },
    };
    const fake = struct {
        model_name: []const u8,
        history: FakeHistory,
        token_limit: u64,
        max_tokens: u32,
        max_history_messages: u32,
        last_turn_usage: @import("../providers/root.zig").TokenUsage,
    }{
        .model_name = "kimi-k2.6",
        .history = .{ .items = &messages },
        .token_limit = 262_144,
        .max_tokens = 32_768,
        .max_history_messages = 50,
        .last_turn_usage = .{
            .prompt_tokens = 55_000,
            .completion_tokens = 100,
            .total_tokens = 55_100,
            .cached_prompt_tokens = 53_000,
        },
    };

    const snapshot = buildSnapshot(&fake);
    try std.testing.expect(snapshot.local_token_estimate < 55_000);
    try std.testing.expectEqual(@as(u64, 55_000), snapshot.token_estimate);
    try std.testing.expectEqual(@as(u32, 55_000), snapshot.provider_prompt_tokens);
    try std.testing.expectEqual(@as(u32, 53_000), snapshot.provider_cached_prompt_tokens);
    try std.testing.expectEqualStrings("provider_last_usage", snapshot.pressure_token_source);
    try std.testing.expectEqual(@as(u8, 20), snapshot.context_pressure_percent);
}

test "buildSnapshot uses active provider preflight before provider usage exists" {
    const FakeRole = enum { system, user, assistant, tool };
    const FakeMessage = struct {
        role: FakeRole,
        content: []const u8,
    };
    const FakeHistory = struct {
        items: []const FakeMessage,
    };
    const messages = [_]FakeMessage{
        .{ .role = .system, .content = "tiny" },
        .{ .role = .user, .content = "hello" },
    };
    const fake = struct {
        model_name: []const u8,
        history: FakeHistory,
        token_limit: u64,
        max_tokens: u32,
        max_history_messages: u32,
        provider_preflight_prompt_tokens: u32,
        provider_preflight_active: bool,
        provider_preflight_source: []const u8,
    }{
        .model_name = "kimi-k2.6",
        .history = .{ .items = &messages },
        .token_limit = 262_144,
        .max_tokens = 32_768,
        .max_history_messages = 50,
        .provider_preflight_prompt_tokens = 56_000,
        .provider_preflight_active = true,
        .provider_preflight_source = "moonshot_tokenizers_estimate",
    };

    const snapshot = buildSnapshot(&fake);
    try std.testing.expect(snapshot.local_token_estimate < 56_000);
    try std.testing.expectEqual(@as(u64, 56_000), snapshot.token_estimate);
    try std.testing.expectEqualStrings("provider_preflight", snapshot.pressure_token_source);
    try std.testing.expect(snapshot.provider_preflight.available);
    try std.testing.expect(snapshot.provider_preflight.active);
}

test "buildPromptShapeFromProviderRequest buckets provider-bound request without raw content" {
    const stable = "stable system contract\n";
    const volatile_prompt = "volatile clock and memory";
    const system_prompt = stable ++ volatile_prompt;
    const assistant_text = "<tool_call name=\"schedule.list\">{}</tool_call>";
    const reasoning_text = "private reasoning bytes";
    const tool_text = "<tool_result>{\"jobs\":[1,2,3]}</tool_result>";
    const image_payload = "AQIDBA==";
    const parts = [_]providers.ContentPart{
        providers.makeTextPart("look at this"),
        providers.makeBase64ImagePart(image_payload, "image/png"),
    };
    const messages = [_]providers.ChatMessage{
        providers.ChatMessage.system(system_prompt),
        providers.ChatMessage.user("user asks a private question"),
        .{
            .role = .assistant,
            .content = assistant_text,
            .reasoning_content = reasoning_text,
        },
        providers.ChatMessage.toolMsg(tool_text, "tool-1"),
        .{
            .role = .user,
            .content = "",
            .content_parts = &parts,
        },
    };
    const tools = [_]providers.ToolSpec{
        .{
            .name = "schedule.list",
            .description = "List scheduled jobs",
            .parameters_json = "{\"type\":\"object\"}",
        },
    };
    const request = providers.ChatRequest{
        .messages = &messages,
        .model = "kimi-k2.6",
        .max_tokens = 1024,
        .tools = &tools,
        .prompt_cache_key = "zaki:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .reasoning_effort = "high",
    };

    const first = buildPromptShapeFromProviderRequest(request, .{
        .stable_system_prompt_bytes = stable.len,
        .stable_system_prompt_hash = 1234,
        .history_tail_bytes = 42,
        .history_tail_hash = 5678,
        .sampled_at_ms = 99,
    });
    const second = buildPromptShapeFromProviderRequest(request, .{
        .stable_system_prompt_bytes = stable.len,
        .stable_system_prompt_hash = 1234,
        .history_tail_bytes = 42,
        .history_tail_hash = 5678,
        .sampled_at_ms = 99,
    });

    try std.testing.expect(first.available);
    try std.testing.expectEqual(@as(i64, 99), first.sampled_at_ms);
    try std.testing.expectEqual(@as(usize, messages.len), first.message_count);
    try std.testing.expectEqual(@as(usize, 1), first.system_message_count);
    try std.testing.expectEqual(@as(usize, 2), first.user_message_count);
    try std.testing.expectEqual(@as(usize, 1), first.assistant_message_count);
    try std.testing.expectEqual(@as(usize, 1), first.tool_message_count);
    try std.testing.expectEqual(@as(usize, 1), first.tool_schema_count);
    try std.testing.expectEqual(@as(usize, 2), first.multimodal_part_count);
    try std.testing.expect(first.prompt_cache_key_present);
    try std.testing.expectEqual(@as(u64, stable.len), first.stable_system_prompt_bytes);
    try std.testing.expectEqual(@as(u64, volatile_prompt.len), first.volatile_system_prompt_bytes);
    try std.testing.expectEqual(@as(u64, system_prompt.len), first.system_prompt_bytes);
    try std.testing.expectEqual(@as(u64, assistant_text.len), first.assistant_message_bytes);
    try std.testing.expectEqual(@as(u64, reasoning_text.len), first.assistant_reasoning_bytes);
    try std.testing.expectEqual(@as(u64, tool_text.len), first.tool_message_bytes);
    try std.testing.expectEqual(@as(u64, assistant_text.len + tool_text.len), first.xml_tool_history_bytes);
    try std.testing.expect(first.multimodal_payload_estimated_bytes > image_payload.len);
    try std.testing.expect(first.provider_request_body_bytes_estimated > first.provider_bound_message_bytes);
    try std.testing.expectEqual(first.full_request_hash, second.full_request_hash);
    try std.testing.expectEqual(first.volatile_system_prompt_hash, second.volatile_system_prompt_hash);
}

test "buildPromptShapeFromProviderRequest emits sanitized prompt blocks by section" {
    const stable =
        "## Safety\n\n" ++
        "stable safety rules\n\n" ++
        "## Tool Use Protocol\n\n" ++
        "xml protocol text\n\n" ++
        "### Available Tools\n\n" ++
        "xml tool catalog text\n\n";
    const volatile_prompt =
        "## Current Date & Time\n\n" ++
        "2026-06-06 12:00 UTC\n\n" ++
        "<memory_for_turn>\n" ++
        "private memory payload\n" ++
        "</memory_for_turn>\n";
    const system_prompt = stable ++ volatile_prompt;
    const messages = [_]providers.ChatMessage{
        providers.ChatMessage.system(system_prompt),
        providers.ChatMessage.user("user text must not be serialized in prompt blocks"),
    };
    const tools = [_]providers.ToolSpec{
        .{
            .name = "schedule",
            .description = "List scheduled jobs",
            .parameters_json = "{\"type\":\"object\"}",
        },
    };
    const request = providers.ChatRequest{
        .messages = &messages,
        .model = "kimi-k2.6",
        .tools = &tools,
    };

    const shape = buildPromptShapeFromProviderRequest(request, .{
        .stable_system_prompt_bytes = stable.len,
        .stable_system_prompt_hash = hashBytes(stable),
        .sampled_at_ms = 99,
    });

    try std.testing.expect(shape.prompt_block_count >= 5);

    var saw_safety = false;
    var saw_xml_protocol = false;
    var saw_xml_catalog = false;
    var saw_datetime = false;
    var saw_memory = false;
    var saw_native_tools = false;
    for (shape.prompt_blocks[0..shape.prompt_block_count]) |block| {
        try std.testing.expect(block.active);
        try std.testing.expect(block.bytes > 0);
        try std.testing.expect(block.token_estimate > 0);
        try std.testing.expect(block.hash > 0);
        try std.testing.expect(std.mem.indexOf(u8, block.name, "private memory payload") == null);
        try std.testing.expect(std.mem.indexOf(u8, block.name, "user text") == null);

        if (std.mem.eql(u8, block.name, "safety")) {
            saw_safety = true;
            try std.testing.expectEqualStrings("stable:tier1", block.bucket);
        } else if (std.mem.eql(u8, block.name, "xml_tool_protocol")) {
            saw_xml_protocol = true;
            try std.testing.expectEqualStrings("stable:xml_tools", block.bucket);
        } else if (std.mem.eql(u8, block.name, "xml_tool_catalog")) {
            saw_xml_catalog = true;
            try std.testing.expectEqualStrings("stable:xml_tools", block.bucket);
        } else if (std.mem.eql(u8, block.name, "current_datetime")) {
            saw_datetime = true;
            try std.testing.expectEqualStrings("volatile:turn", block.bucket);
        } else if (std.mem.eql(u8, block.name, "memory_for_turn")) {
            saw_memory = true;
            try std.testing.expectEqualStrings("volatile:memory", block.bucket);
        } else if (std.mem.eql(u8, block.name, "native_tool_schemas")) {
            saw_native_tools = true;
            try std.testing.expectEqualStrings("provider_tools", block.bucket);
        }
    }

    try std.testing.expect(saw_safety);
    try std.testing.expect(saw_xml_protocol);
    try std.testing.expect(saw_xml_catalog);
    try std.testing.expect(saw_datetime);
    try std.testing.expect(saw_memory);
    try std.testing.expect(saw_native_tools);
}

test "buildPromptShapeFromProviderRequest reports tool surface diagnostics" {
    const stable =
        "## Tools\n\n" ++
        "The executable tool catalog is supplied through the provider-native tools field.\n\n" ++
        "## Tool Use Protocol\n\n" ++
        "minimal fallback protocol only\n\n";
    const messages = [_]providers.ChatMessage{
        providers.ChatMessage.system(stable),
        providers.ChatMessage.user("user text must not leak"),
    };
    const tools = [_]providers.ToolSpec{
        .{
            .name = "small",
            .description = "small tool",
            .parameters_json = "{}",
        },
        .{
            .name = "large_tool",
            .description = "larger tool",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"alpha\":{\"type\":\"string\"},\"beta\":{\"type\":\"string\"}}}",
        },
    };
    const plan = tool_surface.select(true, tools.len);
    const request = providers.ChatRequest{
        .messages = &messages,
        .model = "kimi-k2.6",
        .tools = &tools,
    };

    const shape = buildPromptShapeFromProviderRequest(request, .{
        .stable_system_prompt_bytes = stable.len,
        .stable_system_prompt_hash = hashBytes(stable),
        .sampled_at_ms = 99,
        .tool_surface_plan = plan,
    });

    try std.testing.expectEqualStrings("native_with_xml_fallback", shape.tool_surface_mode);
    try std.testing.expect(shape.provider_supports_native_tools);
    try std.testing.expect(shape.native_tool_schemas_present);
    try std.testing.expect(shape.xml_fallback_protocol_present);
    try std.testing.expect(!shape.xml_tool_catalog_present);
    try std.testing.expect(!shape.prompt_tool_catalog_present);
    try std.testing.expectEqual(@as(usize, tools.len), shape.native_tool_count);
    try std.testing.expect(shape.native_tool_schema_bytes > 0);
    try std.testing.expect(shape.tool_schema_diagnostic_count == 2);
    try std.testing.expectEqualStrings("large_tool", shape.largest_tool_schemas[0].nameSlice());
    try std.testing.expect(shape.largest_tool_schemas[0].parameters_bytes > shape.largest_tool_schemas[1].parameters_bytes);
    for (shape.prompt_blocks[0..shape.prompt_block_count]) |block| {
        try std.testing.expect(std.mem.indexOf(u8, block.name, "user text") == null);
        try std.testing.expect(std.mem.indexOf(u8, block.name, "larger tool") == null);
    }
}

test "tool schema diagnostics sanitize padded dynamic tool names" {
    const ToolLike = struct {
        name: []const u8,
        description: []const u8,
        parameters_json: []const u8,
    };
    const tool = ToolLike{
        .name = "composio\x00\x00\nhidden",
        .description = "dynamic tool",
        .parameters_json = "{}",
    };
    const diag = toolSchemaDiagnostic(tool);
    try std.testing.expectEqualStrings("composio", diag.nameSlice());
    try std.testing.expect(std.mem.indexOfScalar(u8, diag.nameSlice(), 0) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, diag.nameSlice(), '\n') == null);
}

test "tool schema diagnostic nameSlice trims defensive null padding" {
    var diag = ToolSchemaDiagnostic{
        .name_len = 12,
    };
    @memcpy(diag.name[0..12], "composio\x00pad");

    try std.testing.expectEqualStrings("composio", diag.nameSlice());
}

test "buildPromptRefreshPlan refreshes missing system prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fake = struct {
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
        has_system_prompt: bool,
        workspace_prompt_fingerprint: ?u64,
        system_prompt_time_bucket_min: i64,
        conversation_context: ?prompt.ConversationContext,
        system_prompt_conversation_context_fingerprint: u64,
    }{
        .allocator = std.testing.allocator,
        .workspace_dir = tmp.dir.realpathAlloc(std.testing.allocator, ".") catch unreachable,
        .has_system_prompt = false,
        .workspace_prompt_fingerprint = null,
        .system_prompt_time_bucket_min = -1,
        .conversation_context = null,
        .system_prompt_conversation_context_fingerprint = 0,
    };
    defer std.testing.allocator.free(fake.workspace_dir);

    const plan = buildPromptRefreshPlan(&fake);
    try std.testing.expect(plan.should_refresh_system_prompt);
    try std.testing.expect(!plan.conversation_context_present);
}

test "buildPromptRefreshPlan detects clock and conversation changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const current_ctx: prompt.ConversationContext = .{
        .channel = "signal",
        .sender_uuid = "user-1",
        .is_group = false,
    };
    const stale_bucket = @divFloor(std.time.timestamp(), 60) - 5;
    const fake = struct {
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
        has_system_prompt: bool,
        workspace_prompt_fingerprint: ?u64,
        system_prompt_time_bucket_min: i64,
        conversation_context: ?prompt.ConversationContext,
        system_prompt_conversation_context_fingerprint: u64,
    }{
        .allocator = std.testing.allocator,
        .workspace_dir = tmp.dir.realpathAlloc(std.testing.allocator, ".") catch unreachable,
        .has_system_prompt = true,
        .workspace_prompt_fingerprint = 0,
        .system_prompt_time_bucket_min = stale_bucket,
        .conversation_context = current_ctx,
        .system_prompt_conversation_context_fingerprint = 0,
    };
    defer std.testing.allocator.free(fake.workspace_dir);

    const plan = buildPromptRefreshPlan(&fake);
    try std.testing.expect(plan.time_bucket_changed);
    try std.testing.expect(plan.conversation_context_changed);
    try std.testing.expect(plan.should_refresh_system_prompt);
}

test "buildLastTurnContext captures injected memory bytes" {
    const plan = PromptRefreshPlan{
        .current_time_bucket_min = 1,
        .workspace_prompt_fingerprint = 7,
        .conversation_context_present = false,
        .conversation_context_fingerprint = 0,
        .workspace_prompt_changed = true,
        .time_bucket_changed = false,
        .conversation_context_changed = false,
        .should_refresh_system_prompt = true,
    };

    const stats = struct {
        available: bool,
        candidate_count: usize,
        global_candidate_count: usize,
        summary_latest_used: bool,
        context_anchor_used: bool,
        durable_fact_count: usize,
        timeline_summary_count: usize,
        search_match_count: usize,
        global_fallback_count: usize,
        continuity_bucket_entries: usize,
        continuity_bucket_bytes: usize,
        semantic_bucket_entries: usize,
        semantic_bucket_bytes: usize,
        fallback_bucket_entries: usize,
        fallback_bucket_bytes: usize,
        context_bytes: usize,
        injected: bool,
        // V1.8-13: selectionFromStats now also reads graph_recall_* and
        // identity_pin_* fields. The struct passed to buildLastTurnContext
        // (which calls selectionFromStats) must satisfy that contract.
        graph_recall_active: bool,
        graph_recall_seed_count: usize,
        graph_recall_neighbor_count: usize,
        graph_recall_appended_bytes: usize,
        identity_pin_active: bool,
        identity_pin_fact_count: usize,
        identity_pin_appended_bytes: usize,
        typed_views_active: bool,
        typed_views_item_count: usize,
        typed_views_appended_bytes: usize,
    }{
        .available = true,
        .candidate_count = 5,
        .global_candidate_count = 12,
        .summary_latest_used = true,
        .context_anchor_used = false,
        .durable_fact_count = 1,
        .timeline_summary_count = 2,
        .search_match_count = 1,
        .global_fallback_count = 0,
        .continuity_bucket_entries = 1,
        .continuity_bucket_bytes = 12,
        .semantic_bucket_entries = 3,
        .semantic_bucket_bytes = 18,
        .fallback_bucket_entries = 0,
        .fallback_bucket_bytes = 0,
        .context_bytes = 34,
        .injected = true,
        // V1.8-13 contract: zeroed defaults for the test fixture.
        .graph_recall_active = false,
        .graph_recall_seed_count = 0,
        .graph_recall_neighbor_count = 0,
        .graph_recall_appended_bytes = 0,
        .identity_pin_active = false,
        .identity_pin_fact_count = 0,
        .identity_pin_appended_bytes = 0,
        // V1.8-14 contract: zeroed defaults for the test fixture.
        .typed_views_active = false,
        .typed_views_item_count = 0,
        .typed_views_appended_bytes = 0,
    };
    const last_turn = buildLastTurnContext(
        plan,
        stats,
        12,
    );

    try std.testing.expect(last_turn.available);
    try std.testing.expect(last_turn.prompt_refreshed);
    try std.testing.expect(last_turn.workspace_prompt_changed);
    try std.testing.expect(last_turn.memory_context_injected);
    try std.testing.expectEqual(@as(usize, 34), last_turn.memory_context_bytes);
    try std.testing.expectEqual(@as(u64, 12), last_turn.memory_enrich_ms);
    try std.testing.expect(!last_turn.cache_hit);
    try std.testing.expect(last_turn.memory_selection.summary_latest_used);
    try std.testing.expect(!last_turn.memory_selection.context_anchor_used);
    try std.testing.expectEqual(@as(usize, 2), last_turn.memory_selection.timeline_summary_count);
}

test "recordTrimStats accumulates removed history" {
    var last_turn = LastTurnContext{
        .available = true,
    };

    recordTrimStats(&last_turn, .{
        .history_before = 8,
        .history_after = 5,
        .removed_messages = 3,
        .removed_bytes = 42,
    });
    recordTrimStats(&last_turn, .{
        .history_before = 6,
        .history_after = 5,
        .removed_messages = 1,
        .removed_bytes = 10,
    });

    try std.testing.expectEqual(@as(usize, 2), last_turn.trim_events);
    try std.testing.expectEqual(@as(usize, 4), last_turn.trimmed_messages);
    try std.testing.expectEqual(@as(usize, 52), last_turn.trimmed_bytes);
    try std.testing.expectEqual(@as(usize, 5), last_turn.history_messages_after_trim);
}

test "record compaction events updates last turn lifecycle" {
    var last_turn = LastTurnContext{
        .available = true,
    };

    recordAutoCompaction(&last_turn, 15, 8);
    recordForceCompression(&last_turn, 8, 5);

    try std.testing.expectEqual(@as(usize, 1), last_turn.auto_compaction_events);
    try std.testing.expectEqual(@as(usize, 8), last_turn.auto_compacted_messages);
    try std.testing.expectEqual(@as(usize, 1), last_turn.force_compression_events);
    try std.testing.expectEqual(@as(usize, 3), last_turn.force_compressed_messages);
    try std.testing.expectEqual(@as(usize, 5), last_turn.history_messages_after_trim);
}
