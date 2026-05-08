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
