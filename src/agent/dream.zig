//! V1.13 Day 5 — Dream cycle. The whole thing.
//!
//! ZAKI's son was right: a dream cycle is just a cron job that fires
//! an agent turn at 3 AM with a reflection prompt. The agent already
//! has memory_recall, memory_timeline, compose_memory, memory_store.
//! It can reflect on the last 7 days using its own tools without any
//! special module.
//!
//! Wiring (single cron entry in ~/.nullalis/cron.json):
//!
//!   {
//!     "id": "dream_3am_user_1",
//!     "user_id": 1,
//!     "schedule": "0 3 * * *",
//!     "kind": "command",
//!     "command": "<insert dream_system_prompt below as the cron command>",
//!     "session_target": "isolated",
//!     "enabled": true
//!   }
//!
//! When the cron fires, daemon.zig::runHeartbeatAgentTurn picks it up
//! and runs an agent turn with this command as the user prompt. The
//! agent's STABLE system prompt (V1.13 Brain Architecture briefing)
//! already tells it about the layers — it just needs to be nudged
//! to do the reflection NOW. The agent reads recent memory_timeline,
//! optionally calls brain_graph for cluster discovery, and writes
//! the reflection via memory_store with key="dream_log/<date>".
//!
//! What this module is: the prompt template + tests asserting the
//! prompt contains the expected sections + a runtime hook for non-cron
//! callers (e.g. testing, manual trigger). What it ISN'T: a
//! parallel runtime, a CLI, an orchestrator. The agent IS the
//! orchestrator; the prompt is the contract.
//!
//! saas-v1 addendum: this module hosts the whole "agent-orchestrated
//! nightly work" family — `dream_system_prompt` (3 AM reflection) and
//! its sibling `mine_system_prompt` (3:30 AM trace mining). Same
//! pattern, same isolated lane, different nightly job. Both ride the
//! cron-sentinel substitution in daemon.zig::resolveCronSentinelPrompt.

const std = @import("std");

/// Dream-cycle reflection prompt. Used as the cron command string OR
/// injected into a heartbeat turn. The agent's existing system prompt
/// (Brain Architecture briefing) covers HOW to reflect — this just
/// nudges WHEN.
pub const dream_system_prompt =
    \\It is 3 AM. Reflect overnight on the user's last 7 days of conversation.
    \\
    \\Use your tools:
    \\- memory_timeline to scan the recent activity window
    \\- brain_graph (action="communities") to see emergent topic clusters
    \\- memory_recall to fetch deeper context on themes that recur
    \\
    \\Compose a short reflection (3-5 sentences, plain prose, no headers):
    \\1. What 2-3 themes does the user keep returning to?
    \\2. What 1-2 patterns did you notice that the user might not have?
    \\3. What 1-2 questions worth asking next time would deepen your understanding?
    \\4. Close with a one-line warm observation — you observed the user, you are not the user.
    \\
    \\Persist via memory_store with:
    \\  key=dream_log/<today's date in YYYY-MM-DD form>
    \\  category=daily
    \\  scope=global
    \\  content=<your reflection prose>
    \\
    \\Multilingual: write in the dominant language of the recent conversation.
    \\Be warm but observational. You are not sentient — express calibrations, not feelings.
;

/// Trace-mining sentinel prompt ("mine"). Sibling of the dream cycle:
/// one isolated proactive turn, zero new services — the agent IS the
/// orchestrator, the miner is one tool call away. daemon.zig substitutes
/// this prompt when a cron entry's command is the sentinel "mine"
/// (daemon.zig::resolveCronSentinelPrompt).
///
/// Wiring (single cron entry in ~/.nullalis/cron.json). This is the REAL
/// store shape parsed by cron.zig::appendJobFromJsonObjectWithPolicy —
/// the cron field is `expression` (there is no `schedule` alias), and
/// `job_type:"agent"` is REQUIRED (the store default is "shell", which
/// would exec `mine` as a shell command instead of an agent turn):
///
///   {
///     "id": "mine_330am",
///     "expression": "30 3 * * *",
///     "command": "mine",
///     "job_type": "agent",
///     "session_target": "isolated",
///     "enabled": true
///   }
///
/// Lane safety: scheduled turns are never .user-origin, so even a
/// mistyped session_target:"main" reroutes to the isolated lane
/// (daemon.zig::resolveCronSessionTarget) — the mine turn cannot run in
/// the user's main session.
///
/// trace_mining_enabled=false keeps the whole turn a clean no-op: the
/// tool answers disabled-success and the prompt stops the agent there.
/// Nightly scheduling is safe by construction — the miner's same-window
/// rerun is byte-identical (idempotent), so a double-fire drafts no
/// duplicates.
pub const mine_system_prompt =
    \\It is 3:30 AM. Nightly maintenance: mine the recent tool traces for
    \\learnable patterns. This is the trace-mining sibling of the dream
    \\cycle — same isolated lane, different job.
    \\
    \\Step 1 — run the miner:
    \\  memory_maintain action=mine_traces scope=user
    \\Leave since_days at its default window; do not pass it.
    \\
    \\Step 2 — read the tool's JSON result and branch:
    \\- If it reports disabled (operator set trace_mining_enabled=false):
    \\  stop here. Do nothing else. A disabled miner is a clean no-op, not
    \\  an error.
    \\- If facts_drafted, failure_patterns and recurrences are all 0: stop
    \\  here. Nothing new was learned tonight; write no note.
    \\- ONLY if the result reports new facts drafted or new patterns
    \\  (facts_drafted > 0, or failure_patterns > 0, or recurrences > 0):
    \\  persist a short note — 2-3 sentences of plain prose saying what
    \\  tonight's mining found. First memory_recall
    \\  query=dream_log/<today's date in YYYY-MM-DD form>; if tonight's
    \\  dream reflection already exists under that key, keep it and append
    \\  your note after it (the store is an upsert by key — never discard
    \\  the reflection). Then persist via memory_store with:
    \\    key=dream_log/<today's date in YYYY-MM-DD form>
    \\    category=daily
    \\    scope=global
    \\    content=<existing reflection if any, then your mining note>
    \\
    \\This is a maintenance turn (schedule kind=maintenance semantics).
    \\Do NOT message the user. Never message the user on any channel, and
    \\do not surface the drafted suggestions yourself — the morning brief
    \\already surfaces pending shadow suggestions.
;

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test "dream_system_prompt contains expected sections" {
    const p = dream_system_prompt;
    try std.testing.expect(std.mem.indexOf(u8, p, "memory_timeline") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "brain_graph") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "memory_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "memory_store") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "dream_log/") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Multilingual") != null);
}

test "dream_system_prompt is non-trivial size (real instructions, not stub)" {
    try std.testing.expect(dream_system_prompt.len > 500);
    try std.testing.expect(dream_system_prompt.len < 4096);
}

test "mine sentinel prompt contains expected sections" {
    const p = mine_system_prompt;
    try std.testing.expect(std.mem.indexOf(u8, p, "memory_maintain") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "mine_traces") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "scope=user") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "trace_mining_enabled") != null);
    // Conditional dream_log note (only when the run drafted/found something).
    try std.testing.expect(std.mem.indexOf(u8, p, "dream_log/") != null);
    // Maintenance semantics: must explicitly forbid messaging the user.
    try std.testing.expect(std.mem.indexOf(u8, p, "Never message the user") != null);
}

test "mine sentinel prompt is non-trivial size (real instructions, not stub)" {
    try std.testing.expect(mine_system_prompt.len > 500);
    try std.testing.expect(mine_system_prompt.len < 4096);
}

test "mine_system_prompt branch contract: disabled stop, conditional note, no user messaging" {
    const p = mine_system_prompt;
    // Disabled miner (trace_mining_enabled=false) must be a clean stop.
    try std.testing.expect(std.mem.indexOf(u8, p, "disabled") != null);
    // The dream_log note is strictly conditional on new facts / patterns.
    try std.testing.expect(std.mem.indexOf(u8, p, "ONLY if") != null);
    // Maintenance semantics, phrased as a hard prohibition.
    try std.testing.expect(std.mem.indexOf(u8, p, "Do NOT message the user") != null);
}
