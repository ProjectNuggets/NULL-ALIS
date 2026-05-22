# Phase 1.5: Prompt Architecture and Liveness

Goal: Make the agent feel alive — always narrating, always showing its work, always learning.

## Sprints

| Sprint | Branch | Goal | Key Files |
|---|---|---|---|
| 1.5A | `refactor/prompt-scaffold-v1` | Composable prompt sections, persona from SOUL.md, turn classification, narration rules | `src/agent/prompt.zig`, `src/agent/prompt_sections.zig` |
| 1.5B | `feat/liveness-narration-v1` | Real-time user-facing narration during execution | `src/agent/narration.zig`, `src/observability.zig`, `src/gateway.zig` |
| 1.5C | `feat/task-decomposition-v1` | Visible sub-step planning for complex requests | `src/agent/task_planner.zig`, `src/agent/root.zig` |
| 1.5D | `feat/learning-loop-v1` | Correction detection, preference storage, durable behavioral facts | `src/agent/learning.zig`, `src/memory/root.zig` |
| 1.5E | `feat/persona-calibration-v1` | Configurable personality dimensions, SOUL.md resolver | `src/agent/prompt.zig`, `src/config.zig` |

## Dependencies

- Depends on: Phase 1 complete (execution modes inform prompt shaping)
- Blocks: Phase 2 (narration feeds into run events)

## Success Criteria

1. Agent never goes silent during multi-tool work — always narrates what it's doing
2. Complex requests show a visible numbered plan before execution
3. Corrections are remembered and applied in future turns
4. Persona is configurable and defaults to "attentive digital twin"
5. Prompt is assembled from named composable sections, not a monolithic builder
