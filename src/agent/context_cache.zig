pub const Cacheability = enum {
    stable,
    dynamic,
    per_turn,
};

pub const Bucket = struct {
    entries: usize = 0,
    bytes: usize = 0,
    token_estimate: u64 = 0,
    active: bool = false,
    cacheability: Cacheability = .dynamic,
};

pub const ConversationBucket = struct {
    active: bool = false,
    embedded_in_stable_prefix: bool = false,
    fingerprint: u64 = 0,
};

pub const BucketSet = struct {
    stable_prefix: Bucket = .{ .cacheability = .stable },
    memory_context: Bucket = .{ .cacheability = .dynamic },
    recent_history: Bucket = .{ .cacheability = .dynamic },
    last_turn_runtime: Bucket = .{ .cacheability = .per_turn },
    conversation_context: ConversationBucket = .{},
};

pub const StablePrefixState = struct {
    available: bool = false,
    refresh_needed: bool = false,
    cold_start: bool = false,
    workspace_prompt_changed: bool = false,
    time_bucket_changed: bool = false,
    conversation_context_changed: bool = false,
    workspace_fingerprint: ?u64 = null,
    current_time_bucket_min: i64 = -1,
};

pub fn buildStablePrefixState(plan: anytype, has_system_prompt: bool) StablePrefixState {
    return .{
        .available = has_system_prompt,
        .refresh_needed = plan.should_refresh_system_prompt,
        .cold_start = !has_system_prompt,
        .workspace_prompt_changed = plan.workspace_prompt_changed,
        .time_bucket_changed = plan.time_bucket_changed,
        .conversation_context_changed = plan.conversation_context_changed,
        .workspace_fingerprint = plan.workspace_prompt_fingerprint,
        .current_time_bucket_min = plan.current_time_bucket_min,
    };
}

pub fn cacheabilityText(value: Cacheability) []const u8 {
    return switch (value) {
        .stable => "stable",
        .dynamic => "dynamic",
        .per_turn => "per_turn",
    };
}

test "buildStablePrefixState tracks refresh causes" {
    const plan = struct {
        should_refresh_system_prompt: bool,
        workspace_prompt_changed: bool,
        time_bucket_changed: bool,
        conversation_context_changed: bool,
        workspace_prompt_fingerprint: ?u64,
        current_time_bucket_min: i64,
    }{
        .should_refresh_system_prompt = true,
        .workspace_prompt_changed = true,
        .time_bucket_changed = false,
        .conversation_context_changed = true,
        .workspace_prompt_fingerprint = 7,
        .current_time_bucket_min = 123,
    };

    const state = buildStablePrefixState(plan, true);
    try @import("std").testing.expect(state.available);
    try @import("std").testing.expect(state.refresh_needed);
    try @import("std").testing.expect(state.workspace_prompt_changed);
    try @import("std").testing.expect(!state.time_bucket_changed);
    try @import("std").testing.expect(state.conversation_context_changed);
    try @import("std").testing.expectEqual(@as(?u64, 7), state.workspace_fingerprint);
    try @import("std").testing.expectEqual(@as(i64, 123), state.current_time_bucket_min);
}
