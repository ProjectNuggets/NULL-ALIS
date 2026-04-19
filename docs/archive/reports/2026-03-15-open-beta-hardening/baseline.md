# Open Beta Hardening Baseline (2026-03-15)

## Scope Lock
- In scope:
  - Nullalis blocker fixes: tenant policy wiring, Telegram log safety/fallback behavior, docker mount validation fallback diagnostics, memory session-default scope, onboarding truth fields.
  - ZAKI prod UI hard stop at 5/day for app chat.
  - Full local QA/QS gates in both repos.
- Out of scope:
  - Backend quota/paywall enforcement.
  - New channels/features.
  - Provider/model strategy changes.

## Branch + SHA Snapshot
- nullalis
  - branch: `v0.7-open-beta-hardening`
  - sha: `6a59197`
- zaki-prod
  - branch: `website-v0.3-polish`
  - sha: `48d578c`

## Worktree Snapshot (at validation time)
- nullalis:
  - `src/agent/root.zig`
  - `src/gateway.zig`
  - `src/security/docker.zig`
  - `src/tools/git.zig`
  - `src/tools/memory_list.zig`
  - `src/tools/memory_recall.zig`
  - `src/tools/memory_store.zig`
  - `src/tools/shell.zig`
  - `src/tools/tool_sandbox_v1.zig`
- zaki-prod:
  - targeted sprint files:
    - `src/app/components/ChatArea.tsx`
    - `src/app/components/InputArea.tsx`
    - `src/app/components/InputArea.test.tsx`
  - plus pre-existing unrelated website/dist changes in branch.

## Validation Evidence

### Nullalis
- `zig build test --summary all`
  - result: pass
  - summary: `4651/4672 tests passed, 21 skipped`
- `zig build -Dengines=base,sqlite,postgres`
  - result: pass

### ZAKI prod
- backend:
  - `npm --prefix backend run lint` -> pass
  - `npm --prefix backend test` -> pass
- frontend/app:
  - `npm test -- --runInBand src/app/components/InputArea.test.tsx src/app/components/agent/ZakiBotControlPanel.test.tsx` -> pass
  - `npm run typecheck` -> pass
  - `npm run build` -> pass

## Notes
- Backend `build` script is not defined in zaki-prod backend package; active backend quality gates are lint + test.
- DO staging E2E gate remains required for GO/NO-GO (lock contention traces, SSE traces, channel/connect traces, diagnostics before/after contention).
