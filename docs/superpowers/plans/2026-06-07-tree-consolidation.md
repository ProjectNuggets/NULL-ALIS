# Tree Consolidation Plan — DEFERRED (waiting on active agent)

> Captured 2026-06-07 from a read-only forensic audit of every branch + worktree
> in both repos. **Decision: HOLD.** Do NOT consolidate until the active agent
> finishes (the uncommitted WIP in `/Users/nova/Desktop/nullalis` is committed).
> Then: clean trees + land all code on local `main`, **no remote backup**, local only.

## Procedure when we resume (in order)
1. **Confirm the active agent is done** — `/Users/nova/Desktop/nullalis` (`spec/multi-tenant-mcp-hardening`) working tree is CLEAN (its 1,193-line WIP committed). Do not proceed while it's dirty.
2. **nullalis** — land MUST-CAPTURE onto `main`, then FF mine. These branches diverged 28–32 commits → expect merge conflicts; resolve with the user.
3. **zaki** — land MUST-CAPTURE onto `main`, then FF mine (`feature/browser-view-feed`, +4, clean). zaki branches diverged 65–141 → expect conflicts.
4. Leave SAFE-TO-IGNORE branches alone (already merged / on origin / duplicates).
5. No `git push` (user: local-only, no backup).

## nullalis — at-risk inventory (what a my-work-only FF would lose)
MUST-CAPTURE (unique, local-only, not stale):
- **Uncommitted WIP** in `/Users/nova/Desktop/nullalis` — tool-surface diagnostics (`src/agent/tool_surface.zig` + wiring across context_builder/engine/report, dispatcher, prompt, root, gateway, todo, OpenAPI) + `scripts/gateway-clean.sh` daemon/--status/--stop + `.gitignore` `.nullalis-runtime/`. **15 files, +1193/-88. No commit, no stash — most fragile. Its owner must commit it (that's the "agent is done" signal).**
- `spec/multi-tenant-mcp-hardening` (+12, 2026-06-06) — MCP-hardening spec/ADRs + provider/prompt-diagnostics agent feats. Superset of `codex/provider-truth-context-cache` (+4, redundant — dropping it is safe after this lands).
- `prod-readiness/s4-extension-browser-readiness` (+21) — extension_ws lifecycle, `/api/v1/diagnostics/extension/*`, auth-bypass fix, cross-user isolation + E2E mock-hub tests.
- `prod-readiness/s5-observability-slos` (+17) — metrics registry, cardinality cap, fail-loud-on-no-postgres, SLOs catalog.
- `prod-readiness/s6-verification-matrix` (+11) — verification harness, test-postgres CI, live-PG assertions, operator runbook.

SAFE-TO-IGNORE: `prod-readiness/s2` + `s3` (on origin), `s7` + `feat/brain-graph-activate-harden` (merged, ahead 0), `codex/v1-readiness-report` (origin, stale docs). `spec/agent-browser-k8s-backend` = MINE (+90, clean FF; agent-browser backend + Chrome extension v1.0.0).

## zaki — at-risk inventory
MUST-CAPTURE (unique, local-only, not in main, not in my branch):
- `codex/zaki-hire` (32, 2026-05-27) — ZAKI Hire V2 surface, hire BFF bridge, quota boundary, central-meter integration.
- `codex/zaki-commercialization` (39, 2026-05-22) — central metering/grants, entitlement matrix, product catalog, weighted meters, workspace-memory control plane.
- `codex/v2-settings-control-plane` (15, 2026-05-30) — /settings MECE 11-domain nav, GatedRow, capture-policy + device-pairing, legacy modal retire (44/44 tests).
- `codex/v2-agent-closeout` (2, 2026-06-05) — activate launch Agent channels + a context-pressure fix DISTINCT from the provider-truth one already on my branch.

SAFE-TO-IGNORE (already in zaki `main`): `brain-activation` + `codex/v2-brain-closeout` (Brain/Galaxy V2 merged), `codex/v2-release-e2e`, `codex/s-tier-ui-activation`, and the `68e4859` cluster (`agent-artifact-workspace`, `agent-inspector-closeout`, `agent-release-e2e-audit`, `agent-trust-control-plane`, `zaki-prod-finalization` — 5 duplicate names on one already-merged commit). `feature/browser-view-feed` = MINE (+4, clean FF; subsumes `codex/provider-truth-context-cache`).

## Standing risk (flagged, user opted not to back up)
Local `main` is +26 (nullalis) / +159 (zaki) ahead of `origin/main`; ALL at-risk branches are local-only. ~150 commits + the 1,193-line WIP live on one disk with no remote copy. User chose no backup — recoverable from reflog after a bad merge, but NOT from disk loss.
