# V1 Single-Mode Decision (2026-04-28)

## Decision

V1 ships with **one effective mode**. The fast/balanced/deep selector remains in the settings UI for BFF JSON contract continuity, but at runtime ALL modes resolve to **balanced**.

## Why

Per Nova directive 2026-04-28 conversation:
> *"so option B with future ability to bring it back"*

Following an honest matrix audit that surfaced 7 architectural limitations in the multi-mode design:

1. Modes are per-tenant, not per-conversation
2. No "auto" mode — agent can't pick effort by prompt complexity
3. Mode-change is heavy (model swap, prompt cache reset)
4. No mode visibility in chat UX
5. Cost ledger doesn't tag mode
6. Three modes is itself a guess (copied from Claude/Cursor/Hermes)
7. Maintenance complexity tax compounds with every new agent feature

## What changed

**Single line in `src/user_settings.zig:applySettingsToConfig`:**
```zig
const effective_mode = AssistantMode.balanced;
_ = settings.assistant_mode; // intentionally unused — see gate above
```

The full preset infrastructure is preserved:
- `ProductPresetsConfig` in `config_types.zig` keeps fast/balanced/deep definitions
- `AssistantMode` enum still has all three variants
- BFF `/api/v1/users/:id/settings` accepts and stores any mode value
- Tests assert the gate works (`fast input → balanced applied`, `deep input → balanced applied`)

## What users get

The balanced preset:
- **Model:** Kimi K2.5 via Together
- **Temperature:** 0.7
- **reasoning_effort:** medium
- **max_tool_iterations:** 200
- **Queue cap:** 12 (serial, summarize on burst)
- **Summarizer window:** 5K tokens
- **Effective context window:** 256K (Kimi)

Universal sanity ceilings (R18):
- Stream timeout: 1 hour (catches broken sockets)
- Tool result chars: 200K
- memory_recall hard cap: 1000
- max_response_tokens: null (uncapped)

## Trigger to remove the gate (re-enable modes)

ANY of:
- ≥10% of paying users hit `max_tool_iterations` cap
- ≥10% of paying users explicitly request faster/cheaper mode
- SWE-Bench evaluation shows balanced underperforms vs deep by ≥5pt
- Customer feedback explicitly requests "thinking harder" or "shorter replies"

## How to re-enable modes when triggered

Single change at `src/user_settings.zig:applySettingsToConfig`:

```zig
// Remove these 2 lines:
const effective_mode = AssistantMode.balanced;
_ = settings.assistant_mode;

// Restore:
const effective_mode = settings.assistant_mode;
```

Tests `V1 single-mode gate: ...` need updating back to per-mode assertions OR removal.

## Related shipped work that stays

- **Q1** (#57) — message-count cap deprecated. Compaction is sole governor. **No revert needed.**
- **Q2** (#59) — Kimi reasoning_effort wired + context_snapshot honest. **No revert needed.**
- **Q3** (#60) — modes-with-teeth (fast/balanced/deep → low/medium/high reasoning). **Preserved in code; gated by single-mode gate.** When gate is removed, Q3 mapping resumes.
- **R15** (#61) — stream timeout defaults. **No revert needed.**
- **R16** (#62) — reasoning fields disambiguation. **No revert needed.**
- **R18** (#64) — artificial caps lifted. **No revert needed.**

## Frontend follow-up

zaki-prod can hide the assistant_mode dropdown in `ZakiSettingsSheet.tsx:988-1002`. That's a separate change in a separate repo. The backend doesn't care whether the UI shows the dropdown or not — settings PATCH still accepts the field.

## Architectural note

Single mode + adaptive runtime is a stronger architecture than multi-mode. The agent itself decides depth via the model's own reasoning capability. We trade explicit user control for simpler defaults. If user feedback proves we need explicit control, modes return — the road back is short (1 line of code + tests).

This is **not a step backward**. It's a step toward letting the agent decide, which has been the directional theme of Nova's recent calls (Q1 trust compaction, R18 lift caps, this).
