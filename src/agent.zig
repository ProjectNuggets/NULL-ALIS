//! Agent module — delegates to agent/root.zig.
//!
//! Re-exports all public symbols from the agent submodule.

const agent_root = @import("agent/root.zig");
const prompt_mod = @import("agent/prompt.zig");

pub const Agent = agent_root.Agent;
pub const run = agent_root.run;
pub const ConversationContext = prompt_mod.ConversationContext;

test {
    _ = agent_root;
    // V1.7a-9b — pull communities.zig into test discovery so its
    // pure-data LPA tests run with the rest of the agent suite. The
    // module is consumed at run-time by community_pipeline.zig (9c)
    // and the /brain/communities/recompute endpoint (9d).
    _ = @import("agent/communities.zig");
    // V1.7a-9c — pipeline orchestration tests (FNV stable-id + helpers).
    _ = @import("agent/community_pipeline.zig");
    // V1.7-ship S1 — concrete LlmNamer wiring tests (cleanName helper).
    _ = @import("agent/community_llm_namer.zig");
}
