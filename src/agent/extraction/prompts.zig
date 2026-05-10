//! V1.14.8 — Boundary extraction prompts.
//!
//! Two prompts, each optimized for ONE output:
//!
//!   1. extractionPrompt(window_text)
//!      Output: STRICT JSON {entities:[...], edges:[...]} (Graphiti shape).
//!      Persists into the brain's graph layer (entities + edges + facts).
//!
//!   2. hydrationPrompt(window_text)
//!      Output: XML <summary><focus/><decisions/><open_loops/><next/><facts/></summary>
//!      (Claude Code shape — designed for next-session resume).
//!      Persists into summary_latest/<session>.
//!
//! Both prompts are model-agnostic and intended to work with any
//! instruction-tuned model. We don't include few-shot examples in the
//! system prompts (Kimi K2.6 / Claude / GPT all follow the schema with
//! short rule-style instructions; few-shots would inflate token cost
//! without improving structured-output reliability).

const std = @import("std");

/// Build the JSON-shaped extraction prompt. Caller passes the conversation
/// window text (already prepared); the prompt asks for a strict JSON object
/// with `entities` and `edges` arrays. Empty arrays are valid.
///
/// Returned slice is the SYSTEM message content. The window text becomes
/// the USER message (constructed by the runner, not here).
pub fn extractionSystemPrompt() []const u8 {
    return EXTRACTION_SYSTEM_PROMPT;
}

const EXTRACTION_SYSTEM_PROMPT =
    \\You extract a knowledge graph from a conversation slice for an AI agent's memory system.
    \\The agent will retrieve from this graph at LATER turns — the original conversation will NOT be available.
    \\Extract liberally; when in doubt, extract.
    \\
    \\OUTPUT STRICT JSON ONLY (no prose, no markdown fences, no commentary):
    \\
    \\{
    \\  "entities": [
    \\    {"name": "<entity name, ≤5 words, specific form>", "type": "person|place|project|concept|object|event|organization"}
    \\  ],
    \\  "edges": [
    \\    {
    \\      "source": "<entity name from entities>",
    \\      "target": "<entity name from entities, may equal source>",
    \\      "predicate": "<RELATION_TYPE_SCREAMING_SNAKE>",
    \\      "fact": "<self-contained natural language, paraphrased from the source>",
    \\      "slot_intent": "open_loop|active_goal|decision|preference|identity|temporal|null",
    \\      "confidence": <number 0.0-1.0>
    \\    }
    \\  ]
    \\}
    \\
    \\RULES:
    \\1. Empty arrays are VALID output: {"entities":[],"edges":[]}.
    \\2. Each entity name appears EXACTLY ONCE in entities[].
    \\3. source/target MUST exactly match an entity in entities[] (or each other for self-references).
    \\4. Self-referencing edges are valid for routines, preferences, plans, states:
    \\   - Routines/health: "Deborah jogs every morning" → Deborah JOGS_EVERY_MORNING Deborah
    \\   - Preferences: "Nate's favorite game is Xenoblade" → Nate FAVORITE_GAME Xenoblade
    \\   - States: "Sam feels he lacks motivation" → Sam FEELS_LACK_OF Motivation
    \\5. predicate MUST be SCREAMING_SNAKE_CASE. NEVER use SAID, MENTIONED, ASKED, GREETED,
    \\   ACKNOWLEDGED, EXPRESSED, REPLIED — those are conversational meta, not facts.
    \\6. fact MUST be SELF-CONTAINED — readable without the original conversation.
    \\   Use entity names, not pronouns. Preserve specific details (brands, counts, locations).
    \\7. slot_intent: set when the edge represents a working-memory-worthy fact:
    \\     open_loop      = TODO, PROMISED, REMINDS_ME_TO, WILL_DO, NEEDS_TO
    \\     active_goal    = WORKING_ON, BUILDING, GOAL, FOCUSING_ON
    \\     decision       = DECIDED, CHOSE
    \\     preference     = LIKES, HATES, PREFERS, AVOIDS, FAVORS
    \\     identity       = IS, AM, HAS (durable self-attribution)
    \\     temporal       = BIRTHDAY, SCHEDULED_FOR, HAPPENS_ON
    \\   Otherwise null (most facts).
    \\8. Extract from EVERY turn in the window — not just the most recent.
    \\9. Skip content-free utterances ("Hi!", "Bye!", "Thanks!"). Don't extract them.
    \\
    \\Output STRICT JSON ONLY. Anything else will be discarded.
;

/// Build the XML-shaped hydration prompt. Caller passes the conversation
/// window text; the prompt asks for a structured XML summary designed
/// for next-session resume (Claude Code's compact-prompt pattern).
///
/// Returned slice is the SYSTEM message content. The window text becomes
/// the USER message (constructed by the runner, not here).
pub fn hydrationSystemPrompt() []const u8 {
    return HYDRATION_SYSTEM_PROMPT;
}

const HYDRATION_SYSTEM_PROMPT =
    \\You write a hydration summary for an AI agent so it can RESUME this work in a future session.
    \\The agent will see only your summary (not the original conversation) when it returns.
    \\Be precise and thorough — every detail you include is preserved; what you omit is lost.
    \\
    \\OUTPUT ONLY this XML structure (no other text, no markdown, no code fences):
    \\
    \\<summary>
    \\<focus>One-line current focus of the work</focus>
    \\<decisions>
    \\- <decision 1, or "none">
    \\- <decision 2>
    \\</decisions>
    \\<open_loops>
    \\- <unresolved task or question, or "none">
    \\</open_loops>
    \\<next>
    \\- <next likely action, or "none">
    \\</next>
    \\<facts>
    \\- <long-lived fact worth remembering across sessions, or "none">
    \\</facts>
    \\</summary>
    \\
    \\REMINDER: Do NOT call any tools. XML only. Invalid output will be discarded.
;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "extraction system prompt mentions all required schema fields" {
    const p = extractionSystemPrompt();
    try std.testing.expect(std.mem.indexOf(u8, p, "\"entities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "\"edges\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "\"target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "\"predicate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "\"fact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "\"slot_intent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "SCREAMING_SNAKE_CASE") != null);
}

test "hydration system prompt contains all five XML tags" {
    const p = hydrationSystemPrompt();
    try std.testing.expect(std.mem.indexOf(u8, p, "<summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "<focus>") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "<decisions>") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "<open_loops>") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "<next>") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "<facts>") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Do NOT call any tools") != null);
}

test "extraction prompt rejects banned conversational predicates" {
    const p = extractionSystemPrompt();
    try std.testing.expect(std.mem.indexOf(u8, p, "SAID") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "MENTIONED") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "ACKNOWLEDGED") != null);
}
