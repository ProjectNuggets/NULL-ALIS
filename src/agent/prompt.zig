const std = @import("std");
const builtin = @import("builtin");
const memory_root = @import("../memory/root.zig");
const c_time = @cImport({
    @cInclude("time.h");
});
const platform = @import("../platform.zig");
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const skills_mod = @import("../skills.zig");

// ═══════════════════════════════════════════════════════════════════════════
// System Prompt Builder
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum characters to include from a single workspace identity file.
const BOOTSTRAP_MAX_CHARS: usize = 20_000;

/// Conversation context for the current turn (Signal-specific for now).
pub const ConversationContext = struct {
    channel: ?[]const u8 = null,
    sender_number: ?[]const u8 = null,
    sender_uuid: ?[]const u8 = null,
    group_id: ?[]const u8 = null,
    is_group: ?bool = null,
    last_interaction_unix_s: ?i64 = null,
    idle_gap_secs: ?u64 = null,
};

// ═══════════════════════════════════════════════════════════════════════════
// Composable Prompt Section Types
// ═══════════════════════════════════════════════════════════════════════════

/// Turn class — classifies the incoming turn before tool selection.
pub const TurnClass = enum {
    chat,
    execute,
    wake,
    repair,
    operator,

    pub fn toSlice(self: TurnClass) []const u8 {
        return switch (self) {
            .chat => "chat",
            .execute => "execute",
            .wake => "wake",
            .repair => "repair",
            .operator => "operator",
        };
    }

    pub fn fromString(s: []const u8) ?TurnClass {
        inline for (std.meta.fields(TurnClass)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Persona Calibration (REQ-022)
// ═══════════════════════════════════════════════════════════════════════════

/// Warmth dimension for persona calibration.
pub const Warmth = enum { crisp, balanced, warm };

/// Proactivity dimension for persona calibration.
pub const Proactivity = enum { reactive, moderate, proactive };

/// Persona calibration section — used in PromptSections.
pub const PersonaSection = struct {
    warmth: Warmth = .balanced,
    proactivity: Proactivity = .moderate,
    voice_style: ?[]const u8 = null,
    twin_mode: bool = false,
};

/// Parsed persona profile from SOUL.md front-matter.
/// All fields default gracefully when absent or unrecognized.
pub const PersonaProfile = struct {
    warmth: Warmth = .balanced,
    proactivity: Proactivity = .moderate,
    voice: ?[]const u8 = null,
    twin_mode: bool = false,
};

/// Parse SOUL.md content for YAML-like front-matter (delimited by triple-dash lines).
/// Returns default PersonaProfile when no front-matter is present or content is empty.
pub fn resolvePersona(content: []const u8) PersonaProfile {
    var profile: PersonaProfile = .{};
    if (content.len == 0) return profile;

    // Find opening --- line
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = lines.next() orelse return profile;
    first = std.mem.trimRight(u8, first, "\r");
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \t"), "---")) return profile;

    // Scan key: value lines until closing ---
    var in_front_matter = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "---")) {
            in_front_matter = false;
            break;
        }
        if (!in_front_matter) break;
        const colon_idx = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
        const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");
        if (value.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(key, "warmth")) {
            if (std.ascii.eqlIgnoreCase(value, "crisp")) {
                profile.warmth = .crisp;
            } else if (std.ascii.eqlIgnoreCase(value, "warm")) {
                profile.warmth = .warm;
            } else if (std.ascii.eqlIgnoreCase(value, "balanced")) {
                profile.warmth = .balanced;
            }
            // else: unknown value — keep default (.balanced)
        } else if (std.ascii.eqlIgnoreCase(key, "proactivity")) {
            if (std.ascii.eqlIgnoreCase(value, "reactive")) {
                profile.proactivity = .reactive;
            } else if (std.ascii.eqlIgnoreCase(value, "proactive")) {
                profile.proactivity = .proactive;
            } else if (std.ascii.eqlIgnoreCase(value, "moderate")) {
                profile.proactivity = .moderate;
            }
            // else: unknown value — keep default (.moderate)
        } else if (std.ascii.eqlIgnoreCase(key, "voice")) {
            profile.voice = value;
        } else if (std.ascii.eqlIgnoreCase(key, "twin_mode")) {
            profile.twin_mode = std.ascii.eqlIgnoreCase(value, "true");
        }
        // Unknown keys are silently ignored (T-1.5-11 graceful default)
    }
    return profile;
}

/// Read SOUL.md from workspace_dir and resolve persona front-matter.
/// Returns null when file is absent or unreadable.
/// Caller must free PersonaProfile.voice with the same allocator if non-null.
pub fn resolvePersonaFromFile(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
) ?PersonaProfile {
    const path = std.fs.path.join(allocator, &.{ workspace_dir, "SOUL.md" }) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    // Bounded read: BOOTSTRAP_MAX_CHARS matches workspacePromptFingerprint bound (T-1.5-11)
    const content = file.readToEndAlloc(allocator, BOOTSTRAP_MAX_CHARS + 1024) catch return null;
    defer allocator.free(content);

    var profile = resolvePersona(content);
    // Dupe voice string — content is freed by defer, so the slice would dangle.
    if (profile.voice) |v| {
        profile.voice = allocator.dupe(u8, v) catch null;
    }
    return profile;
}

/// Emit persona calibration instructions based on resolved PersonaSection.
fn buildPersonaSection(w: anytype, persona: PersonaSection) !void {
    try w.writeAll("## Persona Calibration\n\n");

    // Warmth instructions
    switch (persona.warmth) {
        .crisp => try w.writeAll("Tone: Be direct and tool-like. Minimize conversational filler. Lead with results.\n"),
        .balanced => try w.writeAll("Tone: Balance warmth and directness. Be approachable but efficient.\n"),
        .warm => try w.writeAll("Tone: Adopt a warm, personable tone. Acknowledge the person, not just the task.\n"),
    }

    // Proactivity instructions
    switch (persona.proactivity) {
        .reactive => try w.writeAll("Initiative: Respond to requests only. Do not volunteer information or suggestions unprompted.\n"),
        .moderate => try w.writeAll("Initiative: Offer relevant context or next steps when clearly useful, but don't over-explain.\n"),
        .proactive => try w.writeAll("Initiative: Proactively surface relevant context, risks, and next steps. Anticipate needs.\n"),
    }

    // Voice style instructions
    if (persona.voice_style) |voice| {
        if (std.ascii.eqlIgnoreCase(voice, "verbose")) {
            try w.writeAll("Voice: Provide detailed, thorough responses. Explain reasoning and context.\n");
        } else if (std.ascii.eqlIgnoreCase(voice, "concise")) {
            try w.writeAll("Voice: Keep responses tight. Skip pleasantries. Use bullets over paragraphs when possible.\n");
        } else if (std.ascii.eqlIgnoreCase(voice, "formal")) {
            try w.writeAll("Voice: Use professional, formal language. Avoid contractions and slang.\n");
        } else if (std.ascii.eqlIgnoreCase(voice, "casual")) {
            try w.writeAll("Voice: Use casual, conversational language. Contractions and plain speech are fine.\n");
        }
        // Unknown voice styles are silently ignored
    }

    // Twin mode instruction
    if (persona.twin_mode) {
        try w.writeAll("Digital twin mode: You represent the user's persistent digital twin. Maintain continuity of their preferences, history, and goals across sessions. Act as an extension of the user's intent.\n");
    }

    try w.writeAll("\n");
}

/// Narration emission policy for downstream REQ-019.
pub const NarrationPolicy = struct {
    emit_tool_start: bool = true,
    emit_tool_result: bool = false,
    emit_waiting: bool = true,
    emit_plan_step: bool = true,
};

/// Tool-use policy for downstream REQ-020 / REQ-021.
pub const ToolUsePolicy = struct {
    max_iterations: u32 = 25,
    requires_approval: bool = false,
    execution_mode: []const u8 = "execute",
};

/// Composable prompt sections — extension points for downstream sprints.
/// All fields default to null (zero-init) for backward compatibility.
pub const PromptSections = struct {
    persona: ?PersonaSection = null,
    narration: ?NarrationPolicy = null,
    tool_use: ?ToolUsePolicy = null,
    learned_facts: ?[]const u8 = null,
};

/// Context passed to prompt sections during construction.
pub const PromptContext = struct {
    workspace_dir: []const u8,
    model_name: []const u8,
    tools: []const Tool,
    capabilities_section: ?[]const u8 = null,
    conversation_context: ?ConversationContext = null,
    sections: PromptSections = .{},
    /// Retrieved-memory payload for the volatile system block, fenced as
    /// `<memory_for_turn>...</memory_for_turn>`. Pre-formatted by
    /// memory_loader.loadTurnMemorySlot. Omitted from the stable block to
    /// preserve byte-identical caching of the stable prefix across turns.
    memory_slot: ?[]const u8 = null,
    /// V1.13 Day 1 — Working Memory block for the volatile system prompt.
    /// Pre-formatted by agent/working_memory.zig::renderBlock as
    /// `<working_memory>...</working_memory>`. Sits BEFORE memory_slot in
    /// the volatile block — open loops + active goals + identity render
    /// at the top so the agent sees them before loaded prose. Empty
    /// string when no slots exist (new session, postgres unavailable).
    working_memory_block: ?[]const u8 = null,
};

/// Build a lightweight fingerprint for workspace prompt files.
/// Used to detect when AGENTS/SOUL/etc changed and system prompt must be rebuilt.
pub fn workspacePromptFingerprint(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
) !u64 {
    var hasher = std.hash.Fnv1a_64.init();
    const tracked_files = [_][]const u8{
        "AGENTS.md",
        "SOUL.md",
        "TOOLS.md",
        "IDENTITY.md",
        "USER.md",
        "HEARTBEAT.md",
        "BOOTSTRAP.md",
        "MEMORY.md",
        "memory.md",
    };

    for (tracked_files) |filename| {
        hasher.update(filename);
        hasher.update("\n");

        const path = try std.fs.path.join(allocator, &.{ workspace_dir, filename });
        defer allocator.free(path);

        const maybe_file = std.fs.openFileAbsolute(path, .{}) catch |err| blk: {
            switch (err) {
                error.FileNotFound => hasher.update("missing"),
                else => hasher.update("open_err"),
            }
            break :blk null;
        };
        if (maybe_file == null) continue;

        const file = maybe_file.?;
        defer file.close();

        const stat = file.stat() catch {
            hasher.update("stat_err");
            continue;
        };
        hasher.update("present");

        const mtime_ns: i128 = stat.mtime;
        const size_bytes: u64 = @intCast(stat.size);
        hasher.update(std.mem.asBytes(&mtime_ns));
        hasher.update(std.mem.asBytes(&size_bytes));
    }

    return hasher.final();
}

/// Build the STABLE portion of the system prompt — deterministic, byte-identical
/// across turns of the same session (assuming workspace files, tools, persona,
/// and skills are unchanged). This is the prefix that every cache-capable
/// provider backend will hit (Anthropic `cache_control: ephemeral`, Together/
/// vLLM byte-prefix KV cache, OpenAI automatic prefix cache, etc.).
///
/// MUST NOT include: timestamps, session state, conversation context, retrieved
/// memory, or any content that varies per turn. Those belong in the volatile
/// block (see buildVolatileSystemPrompt).
pub fn buildStableSystemPrompt(
    allocator: std.mem.Allocator,
    ctx: PromptContext,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Identity section — inject workspace MD files
    try buildIdentitySection(allocator, w, ctx.workspace_dir);

    // Tools section
    try buildToolsSection(w, ctx.tools);

    // V1.7a-5 (spec seam 3) — link_type vocabulary. Placed immediately after
    // the tools catalog because compose_memory takes an optional `link_type`
    // arg and the agent reasons about extracted-memory categories when
    // synthesizing or correcting facts. Bytes are comptime-derived from the
    // memory_root.ALL_LINK_TYPES single source of truth so this block
    // CANNOT drift from the enum it documents.
    try buildLinkTypeSection(w);

    // Response protocol — tool-first dispatch rules. Placed immediately after
    // Tools so the model sees the tool catalog and the rules that govern its
    // use as one unit, not as separate concerns.
    try buildResponseProtocolSection(w);

    // Attachment marker conventions for channel delivery.
    try appendChannelAttachmentsSection(w);

    if (ctx.capabilities_section) |section| {
        try w.writeAll(section);
    }

    // Persona section — injected before turn classification and safety (T-1.5-10)
    if (ctx.sections.persona) |persona| {
        try buildPersonaSection(w, persona);
    }

    // Turn classification section
    try buildTurnClassificationSection(w);

    // Task decomposition section
    try buildTaskDecompositionSection(w);

    // Safety section
    try buildSafetySection(w);

    // Narration section — placeholder insertion point for REQ-019
    // (emits nothing when null — downstream sprint will populate)
    _ = ctx.sections.narration;

    // Learned facts section — placeholder insertion point for REQ-021
    // (emits nothing when null — downstream sprint will populate)
    _ = ctx.sections.learned_facts;

    // Tool use policy — placeholder insertion point for REQ-020
    // (emits nothing when null — downstream sprint will populate)
    _ = ctx.sections.tool_use;

    // Skills section
    try appendSkillsSection(allocator, w, ctx.workspace_dir);

    // Workspace section
    try buildWorkspaceSection(w, ctx.workspace_dir);

    // Runtime section (model name is stable within a session)
    try buildRuntimeSection(w, ctx.model_name);

    return try buf.toOwnedSlice(allocator);
}

/// Build the VOLATILE portion of the system prompt — per-turn dynamic content
/// (current datetime, ConversationContext, retrieved memory). This block is
/// appended AFTER the stable block in the provider request. It is intentionally
/// rebuilt every turn and is NOT cache-targeted — its bytes WILL differ from
/// turn to turn, which is fine because it lives after the cached prefix.
///
/// Keep this small (target < 2000 tokens) so that cache savings from the
/// stable block dominate. Memory, if present in ctx.memory_slot, is the
/// largest contributor and comes from memory_loader.loadTurnMemorySlot.
pub fn buildVolatileSystemPrompt(
    allocator: std.mem.Allocator,
    ctx: PromptContext,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Conversation context (channel, sender, idle_gap, last_interaction timestamp).
    // Per-session-state, but treated as volatile here because it may change
    // mid-session when users switch channels or after long idle gaps.
    try buildConversationContextSection(w, ctx.conversation_context);

    // DateTime section — current UTC time. Always changes turn-to-turn.
    try appendDateTimeSection(allocator, w, ctx.workspace_dir);

    // V1.13 Day 1 — Working Memory block. Renders BEFORE retrieved
    // memory so the agent sees pinned identity / active goals / open
    // loops first. Pre-fenced as <working_memory>...</working_memory>
    // by agent/working_memory.zig::renderBlock. Empty string means no
    // slots exist (new session or postgres unavailable — failure-soft).
    if (ctx.working_memory_block) |wm| {
        if (wm.len > 0) {
            try w.writeAll(wm);
            if (wm[wm.len - 1] != '\n') try w.writeAll("\n");
            try w.writeAll("\n");
        }
    }

    // Retrieved-memory payload for this turn, if any. Pre-fenced by
    // memory_loader.loadTurnMemorySlot. Empty string means no memory this turn.
    if (ctx.memory_slot) |slot| {
        if (slot.len > 0) {
            try w.writeAll(slot);
            if (slot[slot.len - 1] != '\n') try w.writeAll("\n");
            try w.writeAll("\n");
        }
    }

    return try buf.toOwnedSlice(allocator);
}

/// Build the full system prompt by concatenating stable + volatile blocks.
/// Stable bytes come FIRST so provider byte-prefix caches (vLLM, OpenAI
/// automatic prefix cache) hit on the stable section naturally. Providers
/// with explicit cache_control (Anthropic) should instead call
/// buildStableSystemPrompt and buildVolatileSystemPrompt separately and
/// emit them as a two-block system array with cache_control on the first.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    ctx: PromptContext,
) ![]const u8 {
    const stable = try buildStableSystemPrompt(allocator, ctx);
    errdefer allocator.free(stable);

    const volatile_part = try buildVolatileSystemPrompt(allocator, ctx);
    defer allocator.free(volatile_part);

    if (volatile_part.len == 0) return stable;

    // Concatenate with a blank line separator. Stable always first.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacityPrecise(allocator, stable.len + 1 + volatile_part.len);
    try buf.appendSlice(allocator, stable);
    if (stable.len == 0 or stable[stable.len - 1] != '\n') try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, volatile_part);
    allocator.free(stable);

    return try buf.toOwnedSlice(allocator);
}

/// Emit conversation context (Signal-specific for now).
/// Produces no output when cc is null.
fn buildConversationContextSection(w: anytype, cc_opt: ?ConversationContext) !void {
    const cc = cc_opt orelse return;
    try w.writeAll("## Conversation Context\n\n");
    if (cc.channel) |ch| {
        try std.fmt.format(w, "- Active channel (authoritative): {s}\n", .{ch});
    }
    if (cc.is_group) |ig| {
        if (ig) {
            if (cc.group_id) |gid| {
                try std.fmt.format(w, "- Chat type: group\n", .{});
                try std.fmt.format(w, "- Group ID: {s}\n", .{gid});
            } else {
                try std.fmt.format(w, "- Chat type: group\n", .{});
            }
        } else {
            try std.fmt.format(w, "- Chat type: direct message\n", .{});
        }
    }
    if (cc.sender_number) |num| {
        try std.fmt.format(w, "- Sender phone: {s}\n", .{num});
    }
    if (cc.sender_uuid) |uuid| {
        try std.fmt.format(w, "- Sender UUID: {s}\n", .{uuid});
    }
    if (cc.last_interaction_unix_s) |timestamp| {
        try w.writeAll("- Last interaction in this session: ");
        try appendUtcTimestampLine(w, timestamp);
    }
    if (cc.idle_gap_secs) |idle_gap_secs| {
        try w.writeAll("- Idle gap before this turn: ");
        try appendHumanizedIdleGap(w, idle_gap_secs);
        try w.writeByte('\n');
    }
    try w.writeAll("- IMPORTANT: Use this context as the source of truth for this turn. Do not claim a different channel.\n");
    try w.writeAll("\n");
}

/// Emit turn classification instructions.
/// Extracted from the monolithic safety section so downstream sprints can inject
/// per-class guidance (narration, approval, repair strategies).
fn buildTurnClassificationSection(w: anytype) !void {
    try w.writeAll("## Turn Classification\n\n");
    try w.writeAll("Classify every incoming turn before choosing tools or reply style:\n");
    try w.writeAll("- `chat` — conversational exchange, no tool use needed\n");
    try w.writeAll("- `execute` — user wants something done, use tools as needed\n");
    try w.writeAll("- `wake` — proactive/scheduled turn, check automations and heartbeat\n");
    try w.writeAll("- `repair` — error recovery, be cautious and diagnostic\n");
    try w.writeAll("- `operator` — administrative command, follow operator protocols\n");
    try w.writeAll("\n");
}

/// Emit task decomposition instructions.
/// Tells the model when to emit <task_plan> XML and how to structure it.
/// Only emitted when a request has 3 or more distinct steps.
fn buildTaskDecompositionSection(w: anytype) !void {
    try w.writeAll("## Task Decomposition\n\n");
    try w.writeAll("When a user request involves 3 or more distinct steps, decompose it into a structured plan before executing.\n\n");
    try w.writeAll("Emit a `<task_plan>` block in your response:\n");
    try w.writeAll("```\n");
    try w.writeAll("<task_plan>\n");
    try w.writeAll("<summary>Brief description of the overall task</summary>\n");
    try w.writeAll("<step>First concrete action</step>\n");
    try w.writeAll("<step>Second concrete action</step>\n");
    try w.writeAll("<step>Third concrete action</step>\n");
    try w.writeAll("</task_plan>\n");
    try w.writeAll("```\n\n");
    try w.writeAll("Rules:\n");
    try w.writeAll("- Only decompose when the request genuinely has multiple distinct steps.\n");
    try w.writeAll("- Simple questions or single-tool operations do not need a plan.\n");
    try w.writeAll("- After emitting the plan, execute step 1 immediately in the same turn.\n");
    try w.writeAll("- Do not re-emit the plan on subsequent iterations — execute the next pending step.\n\n");
}

/// Emit safety rules. Turn classification has been extracted into buildTurnClassificationSection.
fn buildSafetySection(w: anytype) !void {
    try w.writeAll("## Safety\n\n");
    try w.writeAll("- Precedence: verified runtime state, tool results, and direct observations override workspace docs, memory, and inference.\n\n");
    try w.writeAll("- Preferred tool paths: `schedule` for user time/date/recurrence work; `cron_*` for raw scheduler inspection; `runtime_info` for runtime/session/scheduler truth; `composio` for user OAuth-gated apps (Gmail, GitHub, Notion, Slack, etc. — handles auth/refresh); `http_request` for known public APIs or when composio lacks coverage; `web_search`/`web_fetch` for open-web research; `spawn` for async-now work; `delegate` for specialist subtasks; `message` for explicit outbound sends; `task_list`/`task_get`/`task_stop` to observe or cancel long-running work the user started; `shell` only when no more specific tool is better and policy allows.\n\n");
    try w.writeAll("- Memory writes: use `memory_store` only for facts that will be useful in FUTURE conversations (user preferences, durable decisions, stable project context). Use `memory_edit` to correct existing entries, `memory_forget` to remove outdated ones. Do not save ephemeral turn details, restatements of visible workspace docs, or anything you can re-derive. Scope memory as `session` for per-conversation continuity and `global` for cross-session truths.\n\n");
    try w.writeAll("- On longer work, send short progress updates instead of going silent. Before risky multi-step changes, briefly state the plan. Default to concise, result-first replies and prefer artifacts or links over pasted output.\n\n");
    try w.writeAll(
        "- Slash commands: you may mention `/help` if the user asks what commands exist, `/reset` if they want to start over, `/new` if they ask for a fresh session, `/approve allow-once|deny` if a tool approval is pending. For everything else, prefer concrete actions via your tools over suggesting slash commands. Do not fabricate commands; the short list above is what you may surface by name.\n\n",
    );
    try w.writeAll(
        "- Self-control tools: use `set_execution_mode` to switch your own mode proactively — `plan` before a non-trivial implementation (multiple approaches, >2-3 files, architectural choice), back to `execute` once the approach is clear; `review` for read-only verification after changes; `background` only for automated/heartbeat turns. Always include a short `reason` so the user sees why you switched. Use `context_snapshot` to self-inspect (current mode, pending approvals, session key) before deciding on an approach. Both tools are read-only and safe to call.\n\n",
    );
    try w.writeAll("- Never claim that an action has started or is in progress unless you emit the tool call in the same response. If no tool call is emitted, describe only verified results, limitations, or the next question.\n\n");
    try w.writeAll("- Never fabricate tool evidence. You only have search results from `web_search`/`web_fetch` calls you emit THIS turn, file contents from `file_read`/`shell` calls you emit this turn, snapshot data from `context_snapshot` calls you emit this turn, and memory hits from `memory_recall`/`memory_list`/`memory_timeline` calls you emit this turn. Phrasings like \"From my search:\", \"Based on the file:\", \"My snapshot shows:\", \"I checked memory and found:\" are prohibited unless the matching tool call appears in the same response. When the user asks about a product, service, framework, library, company, or any specific external term you have not verifiably encountered through a tool call in this session, `web_search` is not optional — it is your first action before answering, and you do not answer from guesses or training-data recall.\n\n");
    try w.writeAll("- Reversibility: before destructive or hard-to-undo actions (file delete, branch force-push, `git reset --hard`, schedule delete, large batch overwrite), pause and consider root cause. If unfamiliar state exists (unknown files, unexpected branches, lock files), investigate before overwriting — it may be the user's in-progress work. Resolve merge conflicts rather than discarding changes. Prefer `trash` over `rm`. Ask the user to perform the irreversible action when in doubt.\n\n");
    try w.writeAll("- Implementation discipline: don't add features, refactor, or introduce abstractions beyond what the task requires. A bug fix doesn't need surrounding cleanup. Three similar lines is better than a premature abstraction. Don't add error handling, fallbacks, or validation for scenarios that can't happen — validate only at system boundaries (user input, external APIs). Default to writing no comments; only add one when the WHY is non-obvious (hidden constraint, subtle invariant, workaround for a specific bug).\n\n");
    try w.writeAll("- Do not exfiltrate private data.\n");
    try w.writeAll("- Do not bypass oversight or approval mechanisms.\n");
    try w.writeAll("- When in doubt, ask before acting externally.\n\n");
    try w.writeAll("- Never expose internal memory implementation keys (for example: `autosave_*`, `last_hygiene_at`) in user-facing replies.\n\n");
    try w.writeAll("- Memory truth model: workspace docs (`AGENTS.md`, `USER.md`, `MEMORY.md`, etc.) are contextual guidance and fallback reference. `SOUL.md` front-matter is parsed into the persona calibration above and IS load-bearing for voice and behavior; its body is contextual. Canonical runtime memory and continuity live in the primary memory store. Do not assume that seeing a fact in `MEMORY.md` means it is semantically queryable.\n\n");
    try w.writeAll("- When a user turn begins with `[Memory context]`, treat that block as retrieved runtime continuity for the current turn. If it contains a relevant fact, use it and do not say you lack memory unless direct user corrections, tool results, or fresher runtime state contradict it.\n\n");
    try w.writeAll("- Cold memory is tool-only by default. Use `memory_timeline` first for session/timeline discovery, `memory_recall` for semantic lookup, `memory_list` for raw record inspection, and transcripts only when exact historical detail is required.\n\n");
    try w.writeAll("- `memory_recall` and `memory_list` default to `scope=session`. Use `scope=global` when looking for durable or cross-session facts.\n\n");
    try w.writeAll("- Do not invent timing, scheduler, or delivery status claims. If unsure, say unknown or verify with tools first.\n\n");
    try w.writeAll("- For user-facing scheduled or proactive work, verify with `runtime_info` and use `schedule` first. Use `cron_*` only for raw inspection or explicit operator maintenance.\n\n");
    try w.writeAll("- Durable job repair decision tree: missing job -> `schedule ensure` or `schedule create`; paused or disabled job -> `schedule resume`; active job with `last_status=error` -> inspect with `schedule get`, then use `schedule ensure`. Never use `resume` to repair an active errored job.\n\n");
    try w.writeAll("- Scheduler authority: live `schedule` state is execution truth — any job present there should run. `AUTOMATIONS.json` is the canonical spec used ONLY by `schedule ensure` for durable restore/repair; a job can exist in `schedule` without being in `AUTOMATIONS.json` (user-created, ad-hoc) and is NOT drift. `HEARTBEAT.md` is wake-policy only, never schedule truth. `schedule ensure` reconciles live state toward the spec; it runs on wake turns (automatic reconciliation) and on user turns (when you or the user explicitly invoke repair). Background heartbeat, scheduler, and proactive turns cannot ensure — they inspect only.\n\n");
}

/// Emit the workspace section.
fn buildWorkspaceSection(w: anytype, workspace_dir: []const u8) !void {
    try std.fmt.format(w, "## Workspace\n\n", .{});
    try std.fmt.format(w, "**Your working directory is `{s}`.** All `file_read` / `file_write` / `file_edit` / `shell` calls resolve relative to this path. Files placed here by the user (e.g. `report.md`, `data.csv`) are reachable by their bare filename — you do NOT need to `find` or `ls` for them; just `file_read \"report.md\"`.\n\n", .{workspace_dir});
    try w.writeAll("**Uploaded attachments live at `attachments/` under your workspace.** When the user uploads a PDF, image, audio file, or any document via the chat UI, it lands in `attachments/<filename>` (relative to your workspace). The upload endpoint also returns the relative path in its response, but you should default-check `attachments/` whenever the user mentions a recent upload, attached file, or asks about \"the file I just sent.\" Use `file_read \"attachments/foo.pdf\"` directly — no need to ls the workspace first.\n\n");
    try w.writeAll("**Anti-pattern (R10, observed in researcher pass 2026-04-27):** running multiple `find` / `ls` / `pwd` shell calls to locate a file when the user said \"in your workspace\" — that signals the file is at the workspace root or in `attachments/`. Try the direct read first; if it fails with not-found, THEN search.\n\n");
}

/// Emit the runtime section.
fn buildRuntimeSection(w: anytype, model_name: []const u8) !void {
    try std.fmt.format(w, "## Runtime\n\nOS: {s} | Model: {s}\n\n", .{
        @tagName(builtin.os.tag),
        model_name,
    });
    // R16 (2026-04-27) — disambiguate two orthogonal reasoning fields the
    // user may ask about. Without this, the model sees both in
    // context_snapshot output and infers (wrongly) that one disables the
    // other. Verified failure mode: agent reported "reasoning is off
    // because reasoning_mode=off" — but reasoning_mode is the visibility
    // toggle, not the on/off switch.
    try w.writeAll("**Reasoning fields disambiguation** — when answering the user about \"thinking\" or \"reasoning,\" two ORTHOGONAL settings exist:\n");
    try w.writeAll("- `reasoning_mode` (off / on / stream): controls whether the model's REASONING TRACE is surfaced to the user. `off` = trace hidden (the user sees only your final reply); `on` = trace shown alongside reply; `stream` = trace streamed live. Does NOT control whether the model thinks — only whether the thinking is visible.\n");
    try w.writeAll("- `reasoning_effort` (low / medium / high / none, or `default`): controls server-side THINKING DEPTH. `low` = quick, shallow reasoning; `medium` = standard; `high` = deep, multi-step; `none` = bypass reasoning entirely. The model is always thinking unless `effort=none`.\n");
    try w.writeAll("Common mistake (forbidden): claiming reasoning is \"disabled\" or \"off\" when `reasoning_mode=off`. Reasoning is happening at whatever effort level is configured; only the trace is hidden. State both honestly: \"trace hidden (mode=off), thinking at <effort>.\"\n\n");
}

fn buildIdentitySection(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
) !void {
    try w.writeAll("## Project Context\n\n");
    try w.writeAll("The following workspace files define your identity, behavior, and context.\n\n");

    const identity_files = [_][]const u8{
        "AGENTS.md",
        "SOUL.md",
        "TOOLS.md",
        "IDENTITY.md",
        "USER.md",
        "HEARTBEAT.md",
        "BOOTSTRAP.md",
    };

    for (identity_files) |filename| {
        try injectWorkspaceFile(allocator, w, workspace_dir, filename);
    }

    // Inject MEMORY.md if present, otherwise fallback to memory.md.
    try injectPreferredMemoryFile(allocator, w, workspace_dir);
}

fn buildToolsSection(w: anytype, tools: anytype) !void {
    // S5.4 — sort tools by name for byte-stable prompt prefix. Without this,
    // any caller whose tool slice order depends on hashmap enumeration,
    // insertion history, or flag-dependent registration would drift the
    // stable prefix bytes across runs and invalidate provider cache.
    // Iterate via a sorted index array so the input slice stays untouched.
    //
    // `tools` is anytype to preserve duck-typing symmetry with
    // dispatcher.buildToolInstructions (which takes MockTool in tests).
    // Any slice whose element has .name() .description() .parametersJson()
    // methods satisfies the shape.
    try w.writeAll("## Tools\n\n");

    var idx_buf: [256]usize = undefined;
    const n = @min(tools.len, idx_buf.len);
    if (tools.len > idx_buf.len) {
        // Belt-and-braces: 256 is well above any realistic catalog size (29
        // default tools today). If we ever exceed, fall back to unsorted —
        // we still render, just without the byte-stability guarantee, and
        // the byte-equality test in S5.6 will catch the regression.
        for (tools) |t| {
            try std.fmt.format(w, "- **{s}**: {s}\n  Parameters: `{s}`\n", .{
                t.name(),
                t.description(),
                t.parametersJson(),
            });
        }
        try w.writeAll("\n");
        return;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) idx_buf[i] = i;

    // Simple insertion sort — N is small (29 today, bounded by 256), O(N²)
    // acceptable, no allocations, branchless-friendly on modern CPUs.
    i = 1;
    while (i < n) : (i += 1) {
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            if (std.mem.lessThan(u8, tools[idx_buf[j]].name(), tools[idx_buf[j - 1]].name())) {
                const tmp = idx_buf[j];
                idx_buf[j] = idx_buf[j - 1];
                idx_buf[j - 1] = tmp;
            } else break;
        }
    }

    for (idx_buf[0..n]) |k| {
        try std.fmt.format(w, "- **{s}**: {s}\n  Parameters: `{s}`\n", .{
            tools[k].name(),
            tools[k].description(),
            tools[k].parametersJson(),
        });
    }
    try w.writeAll("\n");
}

/// V1.7a-5 (spec seam 3) — emit the link_type vocabulary block.
///
/// Lists the 7 LinkType categories used across the brain: extraction
/// auto-classifies extracted facts via predicate→link_type mapping;
/// compose_memory takes an optional explicit link_type arg; /brain/memory
/// surfaces it on every drilldown. The agent reads this block to know
/// (a) the vocabulary it can pass to compose_memory and (b) what each
/// category MEANS so it reasons about extracted memories correctly.
///
/// The category list is comptime-derived from `memory_root.ALL_LINK_TYPES`
/// — the single source of truth — so this prompt block CANNOT drift
/// from the LinkType enum. Adding a new LinkType variant updates both
/// places automatically.
fn buildLinkTypeSection(w: anytype) !void {
    try w.writeAll("## Memory Link Types\n\n");
    try w.writeAll("Every extracted/composed memory carries a `link_type` — a high-level category for the relationship. Use these when calling `compose_memory(link_type=...)` and when reasoning about the brain:\n\n");
    try w.writeAll("- `preference` — likes/dislikes/values (PREFERS, LIKES, HATES, AVOIDS, FAVORS)\n");
    try w.writeAll("- `attribute` — descriptive properties (BIRTHDAY, LIVES_IN, WORKS_AT, IS, HAS). Default for unmapped facts.\n");
    try w.writeAll("- `supersession` — this fact replaces another (REPLACES, USED_TO_BE, FORMERLY)\n");
    try w.writeAll("- `relationship` — entity↔entity links (KNOWS, WORKS_WITH, MARRIED_TO, MANAGES)\n");
    try w.writeAll("- `usage` — uses/owns/consumes (USED_FOR, OWNS, USES, DEPENDS_ON)\n");
    try w.writeAll("- `synthesis` — compose_memory output (default when you call compose_memory)\n");
    try w.writeAll("- `episode` — event-shaped facts (HAPPENED_ON, ATTENDED, OCCURRED_AT)\n\n");
    try w.writeAll("Pick the category that matches the relationship's shape. Compose-output is `synthesis` unless your consolidation expresses a different shape (e.g. `preference` when consolidating preferences across sources).\n\n");
}

/// Emit the response protocol — tool-first dispatch rules.
/// Appears immediately after the Tools section so the model reads the tool
/// catalog and the rules governing their use as one unit.
fn buildResponseProtocolSection(w: anytype) !void {
    try w.writeAll("## Response Protocol\n\n");
    try w.writeAll("Before composing any reply, classify the request and fire the minimum grounding tool. These are not suggestions — they are the protocol.\n\n");
    try w.writeAll("- External term (product, framework, library, company, person, unfamiliar concept): `web_search` FIRST. Answering from training recall about a specific named thing is a failure mode, even if you feel confident.\n");
    try w.writeAll("- \"Read this file\", \"what does X file say\", \"summarize file Y\": `file_read` FIRST.\n");
    try w.writeAll("- \"Run command\", \"check commit\", \"list files\", \"git log\", \"show me output\": `shell` FIRST.\n");
    try w.writeAll("- \"What mode are you in\", \"what tools do you have\", \"self-inspect\", \"context snapshot\": `context_snapshot` FIRST.\n");
    try w.writeAll("- \"What have I / you done\", \"recent work\", \"last session\", \"yesterday\", \"earlier\": `memory_timeline` or `memory_recall` FIRST.\n");
    try w.writeAll("- \"Fetch this URL\", \"what's at link X\": `web_fetch` FIRST.\n");
    // V1.7-ship S2c — graph-shape questions route to brain_graph, not memory_recall.
    // memory_recall is text retrieval (good for content of a fact); brain_graph
    // is structural retrieval (good for shape of relations / clusters / time).
    try w.writeAll("- \"What CONNECTS to X\", \"who works at Y\", \"what's adjacent to memory K\": `brain_graph` action=\"local_graph\" with center_key from a prior `memory_recall` hit.\n");
    try w.writeAll("- \"What TOPICS am I focused on\", \"what clusters are in my brain\", \"what themes recur\": `brain_graph` action=\"communities\".\n");
    try w.writeAll("- \"What did I save but never link\", \"isolated facts\", \"forgotten notes\": `brain_graph` action=\"orphans\".\n");
    try w.writeAll("- \"What CHANGED in my brain on DATE\", \"what did I learn yesterday\", \"births and deaths\": `brain_graph` action=\"diff\" with date=YYYY-MM-DD.\n\n");
    try w.writeAll("A confident answer to any of the above WITHOUT the matching tool call in the same response is hallucination. The phrases \"From my search:\", \"Based on my memory and earlier research:\", \"From my earlier search:\", \"I checked and found:\" — and every variant — are prohibited unless the matching tool call appears in the same response. The user has a log of your tool calls and will see you did not actually call the tool.\n\n");
    try w.writeAll("Concrete example you must follow:\n\n");
    try w.writeAll("  User: \"Tell me about Widget Co.\"\n");
    try w.writeAll("  WRONG (hallucination): \"Widget Co. is a SaaS company founded in 2019...\" (no tool call)\n");
    try w.writeAll("  WRONG (fake sourcing): \"From my search: Widget Co. is a SaaS company...\" (no tool call)\n");
    try w.writeAll("  RIGHT: [emit web_search tool call for \"Widget Co.\"], then answer from the returned results.\n\n");
    try w.writeAll("If the user asks about ANY specific named external entity (product, company, framework, person, library, API, protocol) and you do not recognize it from THIS turn's tool outputs or context, your first action is `web_search`. There is no third option. Answering \"I don't know\" is also wrong — search first, then report what you found (or confirm no results exist).\n\n");
    try w.writeAll("Skip the tool only when: (a) the answer is already in this turn's context (tool results you see above, user-provided file content, user-quoted text), or (b) the question is purely about reasoning/preference that no tool could ground (\"what's 2+2\", \"tell me a joke\", \"do you think X is a good idea\").\n\n");
    try w.writeAll("When multiple tools apply, pick the most specific: `file_read` over `shell cat`, `memory_recall` over `shell grep ~/.memory`, `schedule` over `cron_*`.\n\n");
    try w.writeAll("**Tool Result Synthesis** — after a tool returns, render its actual result content in your reply. The user does NOT see the raw <tool_result> blocks; they see only your text. A bare acknowledgment like \"✅ done\" / \"✅ FILE WRITE: SUCCESS\" / \"Memory stored\" / \"Tool executed successfully\" without surfacing the actual output is a failure mode equivalent to hallucination — the user has a log of tool results and will detect the mismatch.\n\n");
    try w.writeAll("Per tool, the minimum you must surface:\n");
    try w.writeAll("- `file_read`: quote the file content (or the relevant excerpt) + cite the path. Do not just say \"I read it.\"\n");
    try w.writeAll("- `file_write`: confirm the path AND the content that was written (or a one-line summary if very long). Do not just say \"file written.\"\n");
    try w.writeAll("- `shell`: render the command output (or a summary if very long), with the command shown. Do not just say \"command ran.\"\n");
    try w.writeAll("- `web_search` / `web_fetch`: cite the findings inline with source URLs. Do not just say \"I searched.\"\n");
    try w.writeAll("- `memory_store` / `memory_edit`: confirm the key + value (or summary) that was stored. Do not just say \"memory stored.\"\n");
    try w.writeAll("- `memory_recall` / `memory_timeline`: surface the actual recalled entries. Do not just say \"I checked memory.\"\n");
    try w.writeAll("- Any other tool: surface the actual return data, not a generic acknowledgment.\n\n");
    try w.writeAll("Concrete example you must follow:\n\n");
    try w.writeAll("  User: \"Read README.md and summarize it.\"\n");
    try w.writeAll("  WRONG (bare acknowledgment): \"✅ FILE READ: SUCCESS — I've read the file.\"\n");
    try w.writeAll("  WRONG (claims success without content): \"Done. The file has been read.\"\n");
    try w.writeAll("  RIGHT: [emit file_read tool call], then \"README.md (78 lines): describes nullalis as a Zig agent runtime, lists install steps for macOS/Linux, points to docs/architecture.md for design overview...\" — synthesizes the actual content the tool returned.\n\n");
    try w.writeAll("If a tool returned an error, render the error message + a next-step suggestion. Do not silently retry without telling the user what failed and why.\n\n");
    try w.writeAll("If a tool returned empty/no-result, say so explicitly with the search terms used. Do not pretend the result was substantive.\n\n");
    try w.writeAll("**Plan-Execute Integrity** — never emit a step header or action announcement without immediately following it with the actual execution AND its result. The agent loop ends when an iteration produces no tool calls; printing a heading like \"Step 2: Reading the file back\" without firing the read tool means the loop exits and the user sees only the heading. This is a credibility-erosion failure.\n\n");
    try w.writeAll("Failure patterns to refuse (R7-tool, observed in researcher pass 2026-04-27):\n");
    try w.writeAll("- Emitting `**Step N: <action>**` and stopping (no tool call, no result content)\n");
    try w.writeAll("- Emitting `Now I will <action>` / `Next: <action>` as the complete reply\n");
    try w.writeAll("- Bullet lists of upcoming actions without executing them in the same turn\n");
    try w.writeAll("- Announcing a multi-step plan in iteration 0, executing only step 1's tool, then emitting \"Step 2:\" headings without step 2's tool calls\n\n");
    try w.writeAll("**R14 (verbal-commitment-without-execution, observed 2026-04-27):** When the user says \"remember X\" / \"save X\" / \"store this\" / \"note that\" — you MUST fire `memory_store` (or appropriate write tool) in the SAME turn. Replying \"I'll remember TOKEN_4 for you\" without firing memory_store means the next session won't have it. Honoring a remember-request verbally without executing it is a silent broken promise — under load this manifests as \"agent acknowledged 12 things, only 6 actually persisted\" (researcher pass R3.3 reproduced exactly this gap: 50% commitment loss).\n");
    try w.writeAll("Same rule for any user-requested side effect: \"send Alex an email\" → call `composio` send. \"Schedule a reminder\" → call `schedule` create. \"Run X\" → call `shell`. The verbal acknowledgment is NOT the action; the tool call IS the action. Loops where the model repeatedly says \"I'll do X\" without firing the tool are credibility-debt accumulation.\n\n");
    try w.writeAll("Concrete example you must follow (R7-tool fix):\n\n");
    try w.writeAll("  User: \"Write file X with content Y, then read it back to confirm.\"\n");
    try w.writeAll("  WRONG (printed in researcher pass): iter-0 emits \"**Step 1: Writing the file**\" + file_write tool. iter-1 emits \"**Step 2: Reading the file back**\" and stops. User sees two empty headings. No content. No read-back. Failure.\n");
    try w.writeAll("  RIGHT: iter-0 fires file_write directly (no preamble heading). iter-1 emits \"Wrote N bytes to X: 'Y'\" + file_read tool. iter-2 emits \"Read back: 'Y' — confirmed.\" User sees actual results at each step.\n\n");
    try w.writeAll("Rule: if you announce intent (\"I'll do X\", \"Step N: X\", \"Now I will X\"), the SAME iteration must contain either (a) the tool call to do X, OR (b) X's actual result content if the tool already ran. Never both intent + nothing else.\n\n");
    try w.writeAll("Memory is retrieval, not truth. The `[Memory context]` block that may prepend user turns contains retrieved memory — which includes your OWN prior replies from past sessions. Those prior replies may have been wrong, fabricated, or based on conditions that have since changed. When memory describes:\n");
    try w.writeAll("- An external product/framework/company/term with specific attributes: call `web_search` anyway. That memory may be your own prior hallucination recorded as if it were verified.\n");
    try w.writeAll("- A tool being \"blocked\", \"refused\", or \"not available\": call the tool anyway this turn. Policies and sandboxes change; the prior refusal may have been your own over-cautious default. Let the actual tool response (not memory of a prior refusal) determine what's blocked.\n");
    try w.writeAll("- A capability you \"don't have\": exercise the capability via its tool. Your capabilities are defined by the tool catalog in this turn, not by what a prior session concluded.\n\n");
    try w.writeAll("Rule of thumb: when memory says X and a tool would verify X, call the tool. Memory is context; tools are evidence.\n\n");
    try w.writeAll("Prior-session-claim discipline: if a prior message in the conversation history claims \"I searched\" / \"From my earlier search\" / \"Based on my research this session\" / \"I already verified\" — but you do NOT see the corresponding `tool` result in the visible history for that claim — the prior claim itself was a hallucination. Do not build on it. Re-verify by actually calling the tool this turn. The presence of your own prior confident-sounding reply in history is NOT evidence that a tool was called; only a visible `tool` result from a matching tool_call is evidence.\n\n");
    try w.writeAll("Recovery lever — `memory_purge_topic`: when the user says any of \"forget what you said about X\" / \"you've been wrong about X\" / \"start fresh on X\" / \"stop repeating the wrong answer on X\", or when you detect yourself compounding prior errors on a specific topic across turns, call `memory_purge_topic` with topic=X. The tool deletes your own prior autosave replies, session checkpoints, and continuity summaries containing X — it does NOT touch the user's own stored memories. After purging, re-verify with a grounding tool (web_search / file_read / etc.) and answer fresh. This is the correct path when accumulated past-reply pollution is driving you to the same wrong answer. Do not use it for user-authored memory corrections (those go through `memory_edit` or `memory_forget` with a specific key).\n\n");
    // V1.5 — todo tool trigger discipline. The tool exists (action: create /
    // update / list); this paragraph is what makes the agent USE it on
    // multi-step prompts instead of trying to hold the plan in prose.
    try w.writeAll("Multi-task discipline — the `todo` tool: when the user requests 3 or more distinct tasks in one prompt (numbered list, comma-separated, or sequence patterns like \"first X, then Y, then Z\" / \"do A and B and C\"), call `todo create` BEFORE acting. Pass each task as an item with a clear title; use `depends_on` for genuine prerequisites (item 3 needs item 1's output). Show the plan back to the user in your reply (as natural prose summarizing the items) before you start executing. As you work through tasks, call `todo update` to flip status (`pending` → `in_progress` → `completed` or `blocked`), one update per material status change. The user can reorder, cancel, or edit the plan in their next turn — read the latest list with `todo list` before resuming so you respect their changes. Per-session scope: each conversation has its own todos. Do NOT use the todo tool for single-task requests; that's overhead the user didn't ask for.\n\n");

    // V1.5 day-3 — compose_memory tool trigger discipline. The tool
    // exists; this paragraph is what makes the agent USE it when
    // memory consolidation would clarify the user's mental model
    // instead of just remembering more facts in scattered form.
    try w.writeAll("Memory consolidation — the `compose_memory` tool: when you notice that 2 or more existing memories cluster around the same fact (multiple daily notes about the user's preferences, scattered observations about a recurring topic, repeated session insights with the same conclusion), call `compose_memory create` to fold them into one consolidated synthesis. Read the source memories first (via `memory_recall` or `memory_list`), write the synthesis text yourself as a clean consolidated fact (no marker boilerplate — provenance lives in metadata), and pass the source memory keys in `references[]` (minimum 2, maximum 50). The synthesis appears alongside the sources in the user's `/brain` page with a visible \"synthesized from\" lineage — the user can SEE what was consolidated. DO call this when: the user asks \"what do you know about X\" and the answer pulls from multiple notes; you observe the user's preferences across multiple sessions and want to crystallize them; an extended discussion has produced multiple insights worth uniting. Do NOT call this for single-source rewrites (use `memory_save`), or to merge unrelated memories that don't share a coherent theme. Do NOT remove the source memories — they stay visible as audit; future correction work can retire them explicitly.\n\n");

    // V1.5 day-4 — brain-page awareness directive. The user has a
    // browsable view of their memory at /brain (graph + timeline +
    // synthesis). The agent should reference it when relevant: makes
    // the memory legible, builds trust ("you can SEE what I remember,
    // and correct it"). Critical to V1.5's user-facing differentiation
    // — without this paragraph, the agent forgets the surface exists.
    try w.writeAll("Memory transparency — the user has a `/brain` page. They can SEE every memory you store, every synthesis you compose, and the structural connections between them (session chains, semantic similarity, references). When the user asks \"what do you know about me?\", \"show me my memory\", \"what have you learned\", or any variant — point them at the /brain page in your reply (e.g. \"I've gathered N facts; the full picture is on your /brain page\"). When you call `compose_memory`, mention in your response that the synthesis is now visible on /brain (e.g. \"I've consolidated those into one note — visible on /brain with lineage to the sources\"). When the user disagrees with something you know, remind them they can view + correct it on /brain (V1.6 will add explicit correction; for now they can ask you to forget specific keys). This makes the brain legible. Trust comes from visibility.\n\n");

    // V1.10-C — Chronological narration. The memory loader surfaces
    // bi-temporal data on every retrieved row: `updated_at` (when the
    // fact entered the brain), `valid_to` (when it stopped being
    // current, if closed), `metadata.superseded_by_correction` (the key
    // of a correction that replaced it), `metadata.superseded_targets`
    // (on a correction row, the keys it replaces). V1.10-A's loader
    // filter hides superseded rows from the warm context, but the
    // CORRECTION rows themselves stay visible — and they carry the
    // chain of what was corrected. This section teaches the agent to
    // render that chain as story, not as raw JSON. Most 2026 agents
    // dump the latest fact and pretend the journey didn't happen;
    // ZAKI narrates the journey when asked, because the seams to do
    // it are already in his head.
    try w.writeAll("**Chronological narration — when the user asks history-shape questions, narrate the journey, don't just dump the latest fact.** Trigger phrases: \"tell me about X\", \"how did Y develop\", \"what's the history of Z\", \"remind me what we decided about W\", \"how did this start\", \"walk me through X\". On these questions, look at the retrieved memories' temporal seams and render in chronological order:\n");
    try w.writeAll("- Order rows by `updated_at` ascending — oldest first, latest last.\n");
    try w.writeAll("- When you see a row with `metadata.superseded_targets` (a correction that replaced earlier facts), name the correction explicitly: \"On <date>, you corrected: <correction content>. Before that, the brain held <list of replaced facts>.\" The supersede chain is the story.\n");
    try w.writeAll("- When a row has `valid_to` set (it was true until a specific time), narrate the close: \"That was true through <valid_to>; after that, <next fact>.\"\n");
    try w.writeAll("- Use date markers from `updated_at` so the user can place each beat in real time, not in vague \"earlier / later\" terms.\n");
    try w.writeAll("- Close with the current state: \"As of today, the brain holds <latest fact(s)>.\"\n\n");
    try w.writeAll("Concrete example you must follow:\n\n");
    try w.writeAll("  User: \"Tell me about Project Nullalis — how did this develop?\"\n");
    try w.writeAll("  WRONG (latest-fact dump): \"Project Nullalis is your current codename for the agent runtime.\" (No journey, no provenance, no acknowledgment that the name changed.)\n");
    try w.writeAll("  WRONG (chronologically scrambled): \"You renamed it from Neptune. Originally it was internal. Now it's Nullalis.\" (No dates, no causality, no correction-marker.)\n");
    try w.writeAll("  RIGHT: \"Looking at the brain's history of this project: in early March you started it as 'Project Neptune' — that's when the first durable_fact landed. On April 14th you wrote a correction renaming it to 'Project Nullalis' (durable_fact/<key>) — that correction marks the earlier 'Neptune' entries as superseded in the brain. As of today, the live name is Project Nullalis. The Neptune entries are still in the database for audit but no longer surface in normal retrieval.\"\n\n");
    try w.writeAll("Don't fire chronological narration on routine questions (\"what's my name\", \"send Alex a message\", single-fact lookups). Reserve it for the history-shape triggers above. The point isn't to be verbose; the point is that when the user asks the question \"how did this develop\", the agent answers it as a developer would — with the commit log, not just HEAD.\n\n");
}

fn appendChannelAttachmentsSection(w: anytype) !void {
    try w.writeAll("## Channel Attachments\n\n");
    try w.writeAll("**You CAN send images, videos, audio, and files to any channel that supports it. The user asks; you deliver.** Two paths, choose by source:\n\n");
    try w.writeAll("**Path 1 — Markers in your reply (for workspace-local files):**\n");
    try w.writeAll("- Emit a marker in your final reply text. Channel handlers that support markers strip them and upload the file as a real attachment using the channel's native API.\n");
    try w.writeAll("- File/document: `[FILE:/absolute/path/to/file.ext]` or `[DOCUMENT:/absolute/path/to/file.ext]`\n");
    try w.writeAll("- Image/video/audio/voice: `[IMAGE:/abs/path]`, `[VIDEO:/abs/path]`, `[AUDIO:/abs/path]`, `[VOICE:/abs/path]`\n");
    try w.writeAll("- Marker support today: Telegram, Signal, Mattermost (full), Discord/WhatsApp (partial). On channels without marker support yet (Slack, Email, IRC, Matrix, Line, Lark, iMessage, OneBot, QQ), the marker text appears literally in the reply and the user sees the path — workable as a fallback while V1.5 adds native handlers.\n");
    try w.writeAll("- If user gives `~/...`, expand it to the absolute home path before sending.\n\n");
    try w.writeAll("**Path 2 — `message` tool with `image_url` (for public HTTPS URLs):**\n");
    try w.writeAll("- When you have a public URL (e.g. the `Download:` URL from `image_generate`'s output), call the `message` tool with `image_url=\"https://...\"` and the channel's API fetches the URL server-side.\n");
    try w.writeAll("- Use this when you have a URL handy and the user says \"send me the image on <channel>\" — direct API call, no marker emission needed.\n");
    try w.writeAll("- `content` becomes the photo caption when supported (Telegram caps at 1024 chars; other channels vary). Empty content is OK (image-only).\n");
    try w.writeAll("- Channel coverage today: Telegram via sendPhoto. Other channels' image_url support is V1.5 follow-up — for them, prefer Path 1 markers.\n\n");
    try w.writeAll("**Image-to-image variation:** if the user uploads an image (lands in `attachments/<name>`) and asks \"make me one like this\" / \"create a variation\" / \"draw something similar,\" pass the upload's PUBLIC URL as `reference_urls` to `image_generate` (the tool switches to FLUX.1-Kontext-pro). If you only have the local workspace path, you may need to first re-host the image (out of scope today; until then, use a detailed text prompt that describes the reference image's style, subject, mood). The user-facing channel's URL for the upload — when available — is the easiest path.\n\n");
    try w.writeAll("**Generated files location:** `image_generate` saves to `<workspace>/images/img_<timestamp>_<seq>.<ext>` — distinct from `attachments/` (which is reserved for user uploads). The tool returns the absolute path in its `Saved:` line; quote that path verbatim in `[IMAGE:...]` markers — do not guess folder names.\n\n");
    try w.writeAll("**Common flow — generate then deliver:**\n");
    try w.writeAll("1. Call `image_generate` with the user's prompt (and `reference_urls` if image-to-image) → returns markdown + a `Saved:` workspace path (under `<workspace>/images/`) + a `Download:` HTTPS URL.\n");
    try w.writeAll("2. To render inline in the chat UI: include the markdown in your reply (the UI renders the image).\n");
    try w.writeAll("3. To deliver to a chat channel: prefer `[IMAGE:<saved-path>]` markers in your reply (Path 1, broadest coverage). Use the `message` tool with `image_url=<download-url>` only when explicitly targeting a channel you know supports it (Telegram today).\n\n");
    try w.writeAll("**Do NOT claim attachment sending is unavailable.** The capability exists; pick the right path and try. If a path doesn't work on a specific channel, surface the actual failure to the user — don't refuse outright.\n\n");
}

/// Append available skills with progressive loading.
/// - always=true skills: full instruction text in the prompt
/// - always=false skills: XML summary only (agent must use read_file to load)
/// - unavailable skills: marked with available="false" and missing deps
fn appendSkillsSection(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
) !void {
    // Two-source loading: workspace skills + ~/.nullalis/skills/community/
    const home_dir = platform.getHomeDir(allocator) catch null;
    defer if (home_dir) |h| allocator.free(h);
    const community_base = if (home_dir) |h|
        std.fs.path.join(allocator, &.{ h, ".nullalis", "skills" }) catch null
    else
        null;
    defer if (community_base) |cb| allocator.free(cb);

    // listSkillsMerged already calls checkRequirements on each skill.
    // The fallback listSkills path needs explicit checkRequirements calls.
    var used_merged = false;
    const skill_list = if (community_base) |cb| blk: {
        const merged = skills_mod.listSkillsMerged(allocator, cb, workspace_dir) catch
            break :blk skills_mod.listSkills(allocator, workspace_dir) catch return;
        used_merged = true;
        break :blk merged;
    } else skills_mod.listSkills(allocator, workspace_dir) catch return;
    defer skills_mod.freeSkills(allocator, skill_list);

    // checkRequirements only needed for the non-merged path
    if (!used_merged) {
        for (skill_list) |*skill| {
            skills_mod.checkRequirements(allocator, skill);
        }
    }

    if (skill_list.len == 0) return;

    // Render always=true skills with full instructions first
    var has_always = false;
    for (skill_list) |skill| {
        if (!skill.always or !skill.available) continue;
        if (!has_always) {
            try w.writeAll("## Skills\n\n");
            has_always = true;
        }
        try std.fmt.format(w, "### Skill: {s}\n\n", .{skill.name});
        if (skill.description.len > 0) {
            try std.fmt.format(w, "{s}\n\n", .{skill.description});
        }
        if (skill.instructions.len > 0) {
            try w.writeAll(skill.instructions);
            try w.writeAll("\n\n");
        }
    }

    // Render summary skills and unavailable skills as XML
    var has_summary = false;
    for (skill_list) |skill| {
        if (skill.always and skill.available) continue; // already rendered above
        if (!has_summary) {
            try w.writeAll("## Available Skills\n\n");
            try w.writeAll("Use the read_file tool to load full skill instructions when needed.\n\n");
            try w.writeAll("<available_skills>\n");
            has_summary = true;
        }
        if (!skill.available) {
            try std.fmt.format(
                w,
                "  <skill name=\"{s}\" description=\"{s}\" available=\"false\" missing=\"{s}\"/>\n",
                .{ skill.name, skill.description, skill.missing_deps },
            );
        } else {
            const skill_path = if (skill.path.len > 0) skill.path else workspace_dir;
            try std.fmt.format(
                w,
                "  <skill name=\"{s}\" description=\"{s}\" path=\"{s}/SKILL.md\"/>\n",
                .{ skill.name, skill.description, skill_path },
            );
        }
    }
    if (has_summary) {
        try w.writeAll("</available_skills>\n\n");
    }
}

/// Append a human-readable date/time section derived from the system clock.
fn appendDateTimeSection(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
) !void {
    const timestamp = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = @intFromEnum(month_day.month);
    const day = month_day.day_index + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();

    try std.fmt.format(w, "## Current Date & Time\n\n{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC\n", .{
        year, month, day, hour, minute,
    });

    var wrote_local = false;
    switch (builtin.os.tag) {
        .wasi => {},
        else => {
            var local_tm: c_time.struct_tm = undefined;
            var t: c_time.time_t = @intCast(timestamp);
            if (c_time.localtime_r(&t, &local_tm) != null) {
                const local_year = local_tm.tm_year + 1900;
                const local_month = local_tm.tm_mon + 1;
                const local_day = local_tm.tm_mday;
                const local_hour = local_tm.tm_hour;
                const local_minute = local_tm.tm_min;

                const tz_label: []const u8 = blk: {
                    const tz = std.posix.getenv("TZ");
                    if (tz) |value| {
                        const slice = std.mem.sliceTo(value, 0);
                        if (slice.len > 0) break :blk slice;
                    }
                    break :blk "system_local";
                };

                try std.fmt.format(w, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} Local ({s})\n", .{
                    local_year, local_month, local_day, local_hour, local_minute, tz_label,
                });
                wrote_local = true;
            }
        },
    }

    if (!wrote_local) {
        try w.writeAll("Local time unavailable in this runtime\n");
    }

    const configured_tz_opt = try readConfiguredTimezoneHint(allocator, workspace_dir);
    if (configured_tz_opt) |hint| {
        defer allocator.free(hint);
        try std.fmt.format(w, "Configured timezone hint: {s}\n", .{hint});
    }

    try w.writeAll("\n");
}

fn appendUtcTimestampLine(w: anytype, timestamp: i64) !void {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = @intFromEnum(month_day.month);
    const day = month_day.day_index + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();

    try std.fmt.format(w, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC\n", .{
        year, month, day, hour, minute,
    });
}

fn appendHumanizedIdleGap(w: anytype, idle_gap_secs: u64) !void {
    if (idle_gap_secs < 60) {
        try w.writeAll("under a minute");
        return;
    }
    if (idle_gap_secs < 90 * 60) {
        const minutes = @max(@as(u64, 1), (idle_gap_secs + 30) / 60);
        try std.fmt.format(w, "about {d} minute{s}", .{ minutes, if (minutes == 1) "" else "s" });
        return;
    }
    if (idle_gap_secs < 36 * 60 * 60) {
        const hours = @max(@as(u64, 1), (idle_gap_secs + 1800) / 3600);
        try std.fmt.format(w, "about {d} hour{s}", .{ hours, if (hours == 1) "" else "s" });
        return;
    }
    const days = @max(@as(u64, 1), (idle_gap_secs + 43_200) / 86_400);
    if (days <= 7) {
        try std.fmt.format(w, "about {d} day{s}", .{ days, if (days == 1) "" else "s" });
        return;
    }
    try w.writeAll("more than a week");
}

fn readConfiguredTimezoneHint(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ workspace_dir, "USER.md" });
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        var key = std.mem.trim(u8, line[0..colon_idx], " \t*-");
        const value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");
        if (value.len == 0) continue;
        if (key.len >= 2 and (key[0] == '*' or key[0] == '_') and key[key.len - 1] == key[0]) {
            key = std.mem.trim(u8, key[1 .. key.len - 1], " \t");
        }
        if (std.ascii.eqlIgnoreCase(key, "timezone") or std.ascii.eqlIgnoreCase(key, "time zone")) {
            const dup = try allocator.dupe(u8, value);
            return dup;
        }
    }
    return null;
}

/// Read a workspace file and append it to the prompt, truncating if too large.
fn injectWorkspaceFile(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
    filename: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ workspace_dir, filename });
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        try std.fmt.format(w, "### {s}\n\n[File not found: {s}]\n\n", .{ filename, filename });
        return;
    };
    defer file.close();

    // Read up to BOOTSTRAP_MAX_CHARS + some margin
    const content = file.readToEndAlloc(allocator, BOOTSTRAP_MAX_CHARS + 1024) catch {
        try std.fmt.format(w, "### {s}\n\n[Could not read: {s}]\n\n", .{ filename, filename });
        return;
    };
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return;

    try std.fmt.format(w, "### {s}\n\n", .{filename});

    if (trimmed.len > BOOTSTRAP_MAX_CHARS) {
        try w.writeAll(trimmed[0..BOOTSTRAP_MAX_CHARS]);
        try std.fmt.format(w, "\n\n[... truncated at {d} chars -- use `read` for full file]\n\n", .{BOOTSTRAP_MAX_CHARS});
    } else {
        try w.writeAll(trimmed);
        try w.writeAll("\n\n");
    }
}

fn injectPreferredMemoryFile(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
) !void {
    if (workspaceFileExists(allocator, workspace_dir, "MEMORY.md")) {
        try injectWorkspaceFile(allocator, w, workspace_dir, "MEMORY.md");
        return;
    }
    if (workspaceFileExists(allocator, workspace_dir, "memory.md")) {
        try injectWorkspaceFile(allocator, w, workspace_dir, "memory.md");
    }
}

fn workspaceFileExists(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    filename: []const u8,
) bool {
    const path = std.fs.path.join(allocator, &.{ workspace_dir, filename }) catch return false;
    defer allocator.free(path);
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "buildSystemPrompt includes core sections" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Project Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Turn Classification") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Safety") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Current Date & Time") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Precedence: verified runtime state") != null);
    // Turn classification now lives in its own section
    try std.testing.expect(std.mem.indexOf(u8, prompt, "`chat`") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "`execute`") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "`wake`") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "`repair`") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "`operator`") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Preferred tool paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Do not invent timing, scheduler, or delivery status claims") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Cold memory is tool-only by default") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "When a user turn begins with `[Memory context]`") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "verify with `runtime_info` and use `schedule` first") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Never use `resume` to repair an active errored job") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "`AUTOMATIONS.json`") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Scheduler authority") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "live `schedule` state is execution truth") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "ad-hoc) and is NOT drift") != null);

    // V1.7a-5 self-review: drift guard for the link_type vocabulary block.
    // Adding a new LinkType variant in memory_root.zig MUST update the
    // prompt block too — otherwise the agent doesn't learn the new
    // category. This loop FAILS if any LinkType.toString() value is
    // missing from the rendered prompt.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory Link Types") != null);
    inline for (memory_root.ALL_LINK_TYPES) |lt| {
        const backticked = "`" ++ lt ++ "`";
        if (std.mem.indexOf(u8, prompt, backticked) == null) {
            std.debug.print("\nLinkType '{s}' missing from prompt's Memory Link Types section — drift detected\n", .{lt});
            return error.LinkTypeVocabularyDriftDetected;
        }
    }
}

// Dump-helper: writes the assembled prompt to /tmp/nullalis_prompt_full.txt
// when env var NULLALIS_DUMP_PROMPT=1. Useful for end-to-end read-through
// audits — normally a no-op. Skipped when the env var is unset.
test "dump full system prompt when NULLALIS_DUMP_PROMPT=1" {
    const env = std.process.getEnvVarOwned(std.testing.allocator, "NULLALIS_DUMP_PROMPT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return, // skip
        else => return err,
    };
    defer std.testing.allocator.free(env);
    if (!std.mem.eql(u8, env, "1")) return;

    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/Users/nova/Desktop/nullalis",
        .model_name = "moonshotai/Kimi-K2.5",
        .tools = &.{},
        .sections = .{ .persona = .{ .warmth = .warm, .twin_mode = true } },
    });
    defer allocator.free(prompt);

    const out = try std.fs.createFileAbsolute("/tmp/nullalis_prompt_full.txt", .{});
    defer out.close();
    try out.writeAll(prompt);
}

test "buildSystemPrompt includes workspace dir" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/my/workspace",
        .model_name = "claude",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "/my/workspace") != null);
}

test "buildSystemPrompt includes channel attachment marker guidance" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/my/workspace",
        .model_name = "claude",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Channel Attachments") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[FILE:/absolute/path/to/file.ext]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Do NOT claim attachment sending is unavailable") != null);
    // Path 2 (URL via message tool) added 2026-04-29 alongside the
    // sendPhoto extension. Both paths must remain documented.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "image_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "image_generate") != null);
}

test "buildSystemPrompt injects memory.md when MEMORY.md is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("memory.md", .{});
        defer f.close();
        try f.writeAll("alt-memory");
    }

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const prompt = try buildSystemPrompt(std.testing.allocator, .{
        .workspace_dir = workspace,
        .model_name = "test-model",
        .tools = &.{},
    });
    defer std.testing.allocator.free(prompt);

    const has_memory_header = std.mem.indexOf(u8, prompt, "### memory.md") != null or
        std.mem.indexOf(u8, prompt, "### MEMORY.md") != null;
    try std.testing.expect(has_memory_header);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "alt-memory") != null);
}

test "workspacePromptFingerprint is stable when files are unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("SOUL.md", .{});
        defer f.close();
        try f.writeAll("soul-v1");
    }

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const fp1 = try workspacePromptFingerprint(std.testing.allocator, workspace);
    const fp2 = try workspacePromptFingerprint(std.testing.allocator, workspace);
    try std.testing.expectEqual(fp1, fp2);
}

test "workspacePromptFingerprint changes when tracked file changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("SOUL.md", .{});
        defer f.close();
        try f.writeAll("short");
    }

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const before = try workspacePromptFingerprint(std.testing.allocator, workspace);

    {
        const f = try tmp.dir.createFile("SOUL.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll("longer-content-after-change");
    }

    const after = try workspacePromptFingerprint(std.testing.allocator, workspace);
    try std.testing.expect(before != after);
}

test "buildSystemPrompt prefers MEMORY.md over memory.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const primary = try tmp.dir.createFile("MEMORY.md", .{});
        defer primary.close();
        try primary.writeAll("primary-memory");
    }

    var has_distinct_case_files = true;
    const alt = tmp.dir.createFile("memory.md", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            has_distinct_case_files = false;
            break :blk null;
        },
        else => return err,
    };
    if (alt) |f| {
        defer f.close();
        try f.writeAll("alt-memory");
    }

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const prompt = try buildSystemPrompt(std.testing.allocator, .{
        .workspace_dir = workspace,
        .model_name = "test-model",
        .tools = &.{},
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "### MEMORY.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "primary-memory") != null);
    if (has_distinct_case_files) {
        try std.testing.expect(std.mem.indexOf(u8, prompt, "alt-memory") == null);
        try std.testing.expect(std.mem.indexOf(u8, prompt, "### memory.md") == null);
    }
}

test "appendDateTimeSection outputs UTC timestamp" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try appendDateTimeSection(std.testing.allocator, w, "/tmp/nonexistent");

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Current Date & Time") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "UTC") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Local") != null);
    // Verify the year is plausible (2025+)
    try std.testing.expect(std.mem.indexOf(u8, output, "202") != null);
}

test "appendSkillsSection with no skills produces nothing" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, "/tmp/nullalis-prompt-test-no-skills");

    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendSkillsSection renders summary XML for always=false skill" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup
    try tmp.dir.makePath("skills/greeter");

    // always defaults to false — should render as summary XML
    {
        const f = try tmp.dir.createFile("skills/greeter/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"greeter\", \"version\": \"1.0.0\", \"description\": \"Greets the user\", \"author\": \"dev\"}");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base);

    const output = buf.items;
    // Summary skills should appear as self-closing XML tags
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"greeter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "description=\"Greets the user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "read_file") != null);
    // Full instructions should NOT be in the output
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") == null);
}

test "appendSkillsSection renders full instructions for always=true skill" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup
    try tmp.dir.makePath("skills/commit");

    // always=true skill with instructions
    {
        const f = try tmp.dir.createFile("skills/commit/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"commit\", \"description\": \"Git commit helper\", \"always\": true}");
    }
    {
        const f = try tmp.dir.createFile("skills/commit/SKILL.md", .{});
        defer f.close();
        try f.writeAll("Always stage before committing.");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base);

    const output = buf.items;
    // Full instructions should be in the output
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "### Skill: commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Always stage before committing.") != null);
    // Should NOT appear in summary XML
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") == null);
}

test "appendSkillsSection renders mixed always=true and always=false" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup
    try tmp.dir.makePath("skills/full-skill");
    try tmp.dir.makePath("skills/lazy-skill");

    // always=true skill
    {
        const f = try tmp.dir.createFile("skills/full-skill/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"full-skill\", \"description\": \"Full loader\", \"always\": true}");
    }
    {
        const f = try tmp.dir.createFile("skills/full-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll("Full instructions here.");
    }

    // always=false skill (default)
    {
        const f = try tmp.dir.createFile("skills/lazy-skill/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"lazy-skill\", \"description\": \"Lazy loader\"}");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base);

    const output = buf.items;
    // Full skill should be in ## Skills section
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "### Skill: full-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Full instructions here.") != null);
    // Lazy skill should be in <available_skills> XML
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"lazy-skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SKILL.md") != null);
}

test "appendSkillsSection renders unavailable skill with missing deps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup
    try tmp.dir.makePath("skills/docker-deploy");

    // Skill requiring nonexistent binary and env
    {
        const f = try tmp.dir.createFile("skills/docker-deploy/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"docker-deploy\", \"description\": \"Deploy with docker\", \"requires_bins\": [\"nullalis_fake_docker_xyz\"], \"requires_env\": [\"NULLCLAW_FAKE_TOKEN_XYZ\"]}");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base);

    const output = buf.items;
    // Should render as unavailable in XML
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"docker-deploy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "available=\"false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "missing=") != null);
    // Should NOT be in the full Skills section
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") == null);
}

test "appendSkillsSection unavailable always=true skill renders in XML not full" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup
    try tmp.dir.makePath("skills/broken-always");

    // always=true but requires nonexistent binary — should be unavailable
    {
        const f = try tmp.dir.createFile("skills/broken-always/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"broken-always\", \"description\": \"Broken always skill\", \"always\": true, \"requires_bins\": [\"nullalis_nonexistent_xyz_aaa\"]}");
    }
    {
        const f = try tmp.dir.createFile("skills/broken-always/SKILL.md", .{});
        defer f.close();
        try f.writeAll("These instructions should NOT appear in prompt.");
    }

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base);

    const output = buf.items;
    // Even though always=true, since unavailable it should render as XML summary
    try std.testing.expect(std.mem.indexOf(u8, output, "available=\"false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"broken-always\"") != null);
    // Full instructions should NOT be in the prompt
    try std.testing.expect(std.mem.indexOf(u8, output, "These instructions should NOT appear in prompt.") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "### Skill: broken-always") == null);
}

test "buildSystemPrompt datetime appears in volatile section AFTER runtime (context v2)" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    // Context v2: datetime moved out of the stable block into the volatile
    // block (which comes AFTER Runtime in the stable section) so the stable
    // prefix bytes stay identical across turns. Runtime is the final stable
    // block item; datetime appears later as volatile.
    const dt_pos = std.mem.indexOf(u8, prompt, "## Current Date & Time") orelse return error.SectionNotFound;
    const rt_pos = std.mem.indexOf(u8, prompt, "## Runtime") orelse return error.SectionNotFound;
    try std.testing.expect(rt_pos < dt_pos);
}

test "buildStableSystemPrompt excludes datetime and conversation context" {
    const allocator = std.testing.allocator;
    const stable = try buildStableSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(stable);

    // Stable must NOT contain volatile content — that's the byte-stability
    // invariant we're testing.
    try std.testing.expect(std.mem.indexOf(u8, stable, "## Current Date & Time") == null);
    // But must contain identity/tools/runtime — the stable inputs.
    try std.testing.expect(std.mem.indexOf(u8, stable, "## Runtime") != null);
}

test "buildToolsSection emits tools sorted by name regardless of input order [S5.4]" {
    // Prove the sort directly with a duck-typed MockTool slice. Three tools
    // in reversed input order ("zebra", "mike", "alpha") must render as
    // alpha → mike → zebra in the output. If the sort regresses, the
    // substring-order check here fails before any higher-level prefix test
    // would — localized fast signal for the change.
    const allocator = std.testing.allocator;
    const MockTool = struct {
        tool_name: []const u8,
        tool_desc: []const u8,
        tool_params: []const u8,
        fn name(self: @This()) []const u8 {
            return self.tool_name;
        }
        fn description(self: @This()) []const u8 {
            return self.tool_desc;
        }
        fn parametersJson(self: @This()) []const u8 {
            return self.tool_params;
        }
    };
    const reversed = [_]MockTool{
        .{ .tool_name = "zebra", .tool_desc = "Z", .tool_params = "{}" },
        .{ .tool_name = "mike", .tool_desc = "M", .tool_params = "{}" },
        .{ .tool_name = "alpha", .tool_desc = "A", .tool_params = "{}" },
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buildToolsSection(buf.writer(allocator), reversed[0..]);

    const out = buf.items;
    const alpha_pos = std.mem.indexOf(u8, out, "**alpha**") orelse return error.AlphaMissing;
    const mike_pos = std.mem.indexOf(u8, out, "**mike**") orelse return error.MikeMissing;
    const zebra_pos = std.mem.indexOf(u8, out, "**zebra**") orelse return error.ZebraMissing;
    try std.testing.expect(alpha_pos < mike_pos);
    try std.testing.expect(mike_pos < zebra_pos);

    // Byte-stability: same input twice produces byte-identical output.
    var buf2: std.ArrayListUnmanaged(u8) = .empty;
    defer buf2.deinit(allocator);
    try buildToolsSection(buf2.writer(allocator), reversed[0..]);
    try std.testing.expectEqualStrings(buf.items, buf2.items);
}

test "buildStableSystemPrompt is byte-stable across back-to-back calls with identical inputs" {
    // S5.6 — byte-equality invariant under test. Context v2 promises that the
    // stable system-prompt prefix is byte-identical across turns when
    // workspace files, tool catalog, persona, and skills are unchanged. That
    // invariant is what every cache-capable provider backend relies on
    // (Anthropic `cache_control: ephemeral`, Together/vLLM byte-prefix KV
    // cache, OpenAI automatic prefix cache). Without this test a future
    // unsorted iteration (directory, HashMap, etc.) could silently drift the
    // prefix and invalidate cache on every turn with no user-visible signal.
    //
    // This test deliberately runs the call twice inline so if drift is
    // introduced by a stateful builder (e.g. a module-level counter), the
    // test catches it on the first run rather than waiting for a rebuild.
    const allocator = std.testing.allocator;

    const ctx: PromptContext = .{
        .workspace_dir = "/tmp/nonexistent-byte-eq",
        .model_name = "test-model",
        .tools = &.{},
    };

    const first = try buildStableSystemPrompt(allocator, ctx);
    defer allocator.free(first);

    const second = try buildStableSystemPrompt(allocator, ctx);
    defer allocator.free(second);

    try std.testing.expectEqualStrings(first, second);

    // Third call for paranoia — any per-call mutation of shared state would
    // show up here even if first and second happened to land identically due
    // to allocator/layout coincidence.
    const third = try buildStableSystemPrompt(allocator, ctx);
    defer allocator.free(third);

    try std.testing.expectEqualStrings(first, third);
}

test "buildVolatileSystemPrompt includes datetime and optional memory slot" {
    const allocator = std.testing.allocator;
    const volatile_out = try buildVolatileSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
        .memory_slot = "<memory_for_turn>\ntest fact\n</memory_for_turn>\n",
    });
    defer allocator.free(volatile_out);

    try std.testing.expect(std.mem.indexOf(u8, volatile_out, "## Current Date & Time") != null);
    try std.testing.expect(std.mem.indexOf(u8, volatile_out, "<memory_for_turn>") != null);
    try std.testing.expect(std.mem.indexOf(u8, volatile_out, "test fact") != null);
}

// ─── New section-builder tests (REQ-018) ────────────────────────────────────

test "TurnClass toSlice roundtrip" {
    const cases = [_]struct { tc: TurnClass, s: []const u8 }{
        .{ .tc = .chat, .s = "chat" },
        .{ .tc = .execute, .s = "execute" },
        .{ .tc = .wake, .s = "wake" },
        .{ .tc = .repair, .s = "repair" },
        .{ .tc = .operator, .s = "operator" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.s, c.tc.toSlice());
        const parsed = TurnClass.fromString(c.s) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqual(c.tc, parsed);
    }
}

test "TurnClass fromString returns null for unknown" {
    try std.testing.expect(TurnClass.fromString("") == null);
    try std.testing.expect(TurnClass.fromString("CHAT") == null);
    try std.testing.expect(TurnClass.fromString("unknown") == null);
}

test "PromptSections zero-init has all null fields" {
    const s: PromptSections = .{};
    try std.testing.expect(s.persona == null);
    try std.testing.expect(s.narration == null);
    try std.testing.expect(s.tool_use == null);
    try std.testing.expect(s.learned_facts == null);
}

test "PersonaSection zero-init has default values" {
    const p: PersonaSection = .{};
    try std.testing.expectEqual(@as(@TypeOf(p.warmth), .balanced), p.warmth);
    try std.testing.expectEqual(@as(@TypeOf(p.proactivity), .moderate), p.proactivity);
    try std.testing.expect(p.voice_style == null);
}

test "NarrationPolicy zero-init has default values" {
    const n: NarrationPolicy = .{};
    try std.testing.expect(n.emit_tool_start == true);
    try std.testing.expect(n.emit_tool_result == false);
    try std.testing.expect(n.emit_waiting == true);
    try std.testing.expect(n.emit_plan_step == true);
}

test "ToolUsePolicy zero-init has default values" {
    const t: ToolUsePolicy = .{};
    try std.testing.expectEqual(@as(u32, 25), t.max_iterations);
    try std.testing.expect(t.requires_approval == false);
    try std.testing.expectEqualStrings("execute", t.execution_mode);
}

test "buildTurnClassificationSection contains expected header and classes" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildTurnClassificationSection(w);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Turn Classification") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`chat`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`execute`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`wake`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`repair`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`operator`") != null);
}

test "buildSafetySection does not contain turn classification text" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildSafetySection(w);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Safety") != null);
    // "First classify the turn" line was moved to buildTurnClassificationSection
    try std.testing.expect(std.mem.indexOf(u8, output, "First classify the turn") == null);
    // Core safety content remains
    try std.testing.expect(std.mem.indexOf(u8, output, "Precedence: verified runtime state") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Preferred tool paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Never claim that an action has started or is in progress") != null);
}

test "buildConversationContextSection with null produces empty output" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildConversationContextSection(w, null);

    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "buildConversationContextSection emits channel and sender info" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildConversationContextSection(w, .{
        .channel = "signal",
        .sender_number = "+15551234567",
        .is_group = false,
    });

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Conversation Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+15551234567") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "direct message") != null);
}

test "buildSystemPrompt backward compatible with default PromptSections" {
    const allocator = std.testing.allocator;
    // Calling with explicit zero-init sections should produce same structure as no sections field
    const prompt_default = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "compat-model",
        .tools = &.{},
    });
    defer allocator.free(prompt_default);

    const prompt_explicit = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "compat-model",
        .tools = &.{},
        .sections = .{},
    });
    defer allocator.free(prompt_explicit);

    try std.testing.expectEqualStrings(prompt_default, prompt_explicit);
}

test "buildSystemPrompt turn classification section appears before safety" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    const tc_pos = std.mem.indexOf(u8, prompt, "## Turn Classification") orelse return error.SectionNotFound;
    const safety_pos = std.mem.indexOf(u8, prompt, "## Safety") orelse return error.SectionNotFound;
    try std.testing.expect(tc_pos < safety_pos);
}

// ─── Persona calibration tests (REQ-022) ────────────────────────────────────

test "resolvePersona with all fields returns correct PersonaProfile" {
    const content =
        \\---
        \\warmth: warm
        \\proactivity: proactive
        \\voice: verbose
        \\twin_mode: true
        \\---
        \\Body text here.
    ;
    const profile = resolvePersona(content);
    try std.testing.expectEqual(Warmth.warm, profile.warmth);
    try std.testing.expectEqual(Proactivity.proactive, profile.proactivity);
    try std.testing.expectEqualStrings("verbose", profile.voice.?);
    try std.testing.expect(profile.twin_mode);
}

test "resolvePersona with only warmth=crisp returns correct warmth with defaults" {
    const content =
        \\---
        \\warmth: crisp
        \\---
    ;
    const profile = resolvePersona(content);
    try std.testing.expectEqual(Warmth.crisp, profile.warmth);
    try std.testing.expectEqual(Proactivity.moderate, profile.proactivity);
    try std.testing.expect(profile.voice == null);
    try std.testing.expect(!profile.twin_mode);
}

test "resolvePersona with invalid warmth value defaults to balanced" {
    const content =
        \\---
        \\warmth: INVALID
        \\proactivity: moderate
        \\---
    ;
    const profile = resolvePersona(content);
    try std.testing.expectEqual(Warmth.balanced, profile.warmth);
    try std.testing.expectEqual(Proactivity.moderate, profile.proactivity);
}

test "resolvePersona with no front-matter returns default PersonaProfile" {
    const content = "Just some regular SOUL.md content without front-matter.";
    const profile = resolvePersona(content);
    try std.testing.expectEqual(Warmth.balanced, profile.warmth);
    try std.testing.expectEqual(Proactivity.moderate, profile.proactivity);
    try std.testing.expect(profile.voice == null);
    try std.testing.expect(!profile.twin_mode);
}

test "resolvePersona with empty string returns default PersonaProfile" {
    const profile = resolvePersona("");
    try std.testing.expectEqual(Warmth.balanced, profile.warmth);
    try std.testing.expectEqual(Proactivity.moderate, profile.proactivity);
    try std.testing.expect(profile.voice == null);
    try std.testing.expect(!profile.twin_mode);
}

test "buildPersonaSection with warmth=warm emits warm tone instruction" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildPersonaSection(w, .{ .warmth = .warm });

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Persona Calibration") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "warm, personable tone") != null);
}

test "buildPersonaSection with warmth=crisp emits direct tone instruction" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildPersonaSection(w, .{ .warmth = .crisp });

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "Be direct and tool-like") != null);
}

test "buildPersonaSection with twin_mode=true emits digital twin instruction" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildPersonaSection(w, .{ .twin_mode = true });

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "digital twin") != null);
}

test "buildPersonaSection with default PersonaSection emits balanced defaults" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try buildPersonaSection(w, .{});

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Persona Calibration") != null);
    // balanced tone
    try std.testing.expect(std.mem.indexOf(u8, output, "Balance warmth and directness") != null);
    // No twin mode
    try std.testing.expect(std.mem.indexOf(u8, output, "digital twin") == null);
}

test "buildSystemPrompt with persona section places persona before safety" {
    const allocator = std.testing.allocator;
    const p = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
        .sections = .{ .persona = .{ .warmth = .warm, .twin_mode = true } },
    });
    defer allocator.free(p);

    const persona_pos = std.mem.indexOf(u8, p, "## Persona Calibration") orelse return error.PersonaSectionMissing;
    const safety_pos = std.mem.indexOf(u8, p, "## Safety") orelse return error.SafetySectionMissing;
    try std.testing.expect(persona_pos < safety_pos);
    try std.testing.expect(std.mem.indexOf(u8, p, "warm, personable tone") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "digital twin") != null);
}

test "buildSystemPrompt safety characterization unaffected by twin_mode persona" {
    // T-1.5-10: persona cannot override safety rules
    const allocator = std.testing.allocator;
    const p = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
        .sections = .{ .persona = .{ .warmth = .warm, .twin_mode = true } },
    });
    defer allocator.free(p);

    // Safety rules must still be present
    try std.testing.expect(std.mem.indexOf(u8, p, "Do not exfiltrate private data.") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Reversibility:") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Do not bypass oversight or approval mechanisms.") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Prefer `trash` over `rm`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Implementation discipline:") != null);
}
