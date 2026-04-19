const std = @import("std");
const builtin = @import("builtin");
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

/// Build the full system prompt from workspace identity files, tools, and runtime context.
pub fn buildSystemPrompt(
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

    // Attachment marker conventions for channel delivery.
    try appendChannelAttachmentsSection(w);

    // Conversation context section (Signal-specific for now)
    try buildConversationContextSection(w, ctx.conversation_context);

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

    // DateTime section
    try appendDateTimeSection(allocator, w, ctx.workspace_dir);

    // Runtime section
    try buildRuntimeSection(w, ctx.model_name);

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
    try w.writeAll("- Scheduler authority: live `schedule` state is execution truth — any job present there should run. `AUTOMATIONS.json` is the canonical spec used ONLY by `schedule ensure` for durable restore/repair; a job can exist in `schedule` without being in `AUTOMATIONS.json` (user-created, ad-hoc) and is NOT drift. `HEARTBEAT.md` is wake-policy only, never schedule truth. `schedule ensure` reconciles live state toward the spec; it may run only on wake turns and only for jobs declared in `AUTOMATIONS.json`.\n\n");
}

/// Emit the workspace section.
fn buildWorkspaceSection(w: anytype, workspace_dir: []const u8) !void {
    try std.fmt.format(w, "## Workspace\n\nWorking directory: `{s}`\n\n", .{workspace_dir});
}

/// Emit the runtime section.
fn buildRuntimeSection(w: anytype, model_name: []const u8) !void {
    try std.fmt.format(w, "## Runtime\n\nOS: {s} | Model: {s}\n\n", .{
        @tagName(builtin.os.tag),
        model_name,
    });
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

fn buildToolsSection(w: anytype, tools: []const Tool) !void {
    try w.writeAll("## Tools\n\n");
    for (tools) |t| {
        try std.fmt.format(w, "- **{s}**: {s}\n  Parameters: `{s}`\n", .{
            t.name(),
            t.description(),
            t.parametersJson(),
        });
    }
    try w.writeAll("\n");
}

fn appendChannelAttachmentsSection(w: anytype) !void {
    try w.writeAll("## Channel Attachments\n\n");
    try w.writeAll("- On marker-aware channels (for example Telegram), you can send real attachments by emitting markers in your final reply.\n");
    try w.writeAll("- File/document: `[FILE:/absolute/path/to/file.ext]` or `[DOCUMENT:/absolute/path/to/file.ext]`\n");
    try w.writeAll("- Image/video/audio/voice: `[IMAGE:/abs/path]`, `[VIDEO:/abs/path]`, `[AUDIO:/abs/path]`, `[VOICE:/abs/path]`\n");
    try w.writeAll("- If user gives `~/...`, expand it to the absolute home path before sending.\n");
    try w.writeAll("- Do not claim attachment sending is unavailable when these markers are supported.\n\n");
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
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Do not claim attachment sending is unavailable") != null);
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

test "buildSystemPrompt datetime appears before runtime" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    const dt_pos = std.mem.indexOf(u8, prompt, "## Current Date & Time") orelse return error.SectionNotFound;
    const rt_pos = std.mem.indexOf(u8, prompt, "## Runtime") orelse return error.SectionNotFound;
    try std.testing.expect(dt_pos < rt_pos);
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
