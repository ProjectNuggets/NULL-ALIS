---
tags: [prose, prose/docs]
---

# Deploy Blockers Baseline — 2026-03-15

## Snapshot
- Branch: `v0.7-t8-proactive-single-truth`
- Start SHA: `a13e08b`
- UTC captured: `2026-03-15T14:46:58Z`
- Local captured: `2026-03-15 15:46:58 CET`

## Worktree at baseline
```text
 M src/gateway.zig
 M src/tools/composio.zig
```

## Validation gates
### 1) `zig build test --summary all`
- Result: PASS
- Summary:
  - `4627 passed`
  - `21 skipped`
  - no test failures

### 2) `zig build -Dengines=base,sqlite,postgres`
- Result: PASS

## Scope lock for this slice
Implemented now:
1. Composio connect hardening (`redirect_url` truth + callback URL validation + deterministic auth-config selection).
2. Telegram fallback safety (no second-send fallback for non-OK API responses).

Deferred:
1. Generic `API_KEY` fallback restriction.
2. `config_default` composio entity-scope hardening.

